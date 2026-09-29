----------------------------------------------------------------------------------
-- Company: Computer science and Engineering Department
-- Engineer: Aruna Jayasena (aruna.15@cse.mrt.ac.lk)
--
-- Design Name: DepthMap
-- Module Name: disparity_generator - Behavioral
-- Project Name: Obstacle avoidance using stereo vision
-- Description: Brute-force SSD (sum of squared differences) block matching
-- disparity engine. Fixed ~8-tap (near-3x3) window, sequential search over
-- disparity offsets [minoffset, maxoffset] per pixel, row-band caching
-- (`fetchBlock` rows at a time) into LUTRAM because the source board
-- (Basys3) can't hold a full frame there.
--
-- Ported from Archfx/FPGA-DepthMap-Basys3 (branch 320x240) with two changes
-- on top of the proven original -- the cacheManager sequencing and SSD math
-- are otherwise untouched:
--  1. `frame_done` output pulse (purely observational, doesn't feed back
--     into anything else here) -- pulses for one CLK_MAIN cycle whenever
--     `cacheManager` wraps from "1111" back to "0000", i.e. once per full
--     240-row frame (16 row-bands of `fetchBlock`=15 rows each), so the PS
--     side knows when a new disparity frame is ready to read.
--  2. `dOUT_addr`'s `row*WIDTH+col-best_offset` term is now clamped at
--     zero (via `out_addr_base` below) instead of being allowed to go
--     negative. That subtraction routinely goes negative near the left
--     edge of a row (best_offset > col is common, not a rare corner case),
--     and to_unsigned() of a negative value is undefined by the
--     numeric_std spec. The original got away with it by sizing its
--     target RAM to the full address-bus range so wraparound always
--     landed somewhere harmless; this port uses a right-sized RAM instead
--     (see stereo_depth_top.vhd's DEPTH generics) to fit XC7Z010's smaller
--     BRAM budget, so that implicit safety net no longer applies and the
--     clamp is needed for correctness.
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.numeric_std.all;

entity disparity_generator is
generic (window:positive:=5;
         WIDTH:positive:=320;
         HEIGHT:positive:=240;
         maxoffset:positive:=60; --Maximum extent where to look for the same pixel
         minoffset:positive:=1;  ----minimum extent where to look for the same pixel
         fetchBlock:positive:=15);
  Port (
    HCLK         : in  STD_LOGIC;
    CLK_MAIN         : in  STD_LOGIC;
	left_in      : in  STD_LOGIC_vector(3 downto 0);
	right_in     : in  STD_LOGIC_vector(3 downto 0);
	avg_out     : out  STD_LOGIC_vector(3 downto 0);
	dOUT         : out  STD_LOGIC_vector(7 downto 0);
    dOUT_addr    : out  STD_LOGIC_vector(16 downto 0);
    left_right_addr: out  STD_LOGIC_vector(16 downto 0);
    avg_reg_en    : out  STD_LOGIC;
    wr_en  : out  STD_LOGIC;
    frame_done : out STD_LOGIC
    		 );
end disparity_generator;

architecture Behavioral of disparity_generator is

-- BUGFIX vs. the reference design: this was declared
-- `array(0 to WIDTH*fetchBlock+1)`, which is too small for the way the rest
-- of this file actually uses it, in BOTH directions:
--   * caching_process fills indices 0 .. WIDTH*fetchBlock+2*WIDTH-1 (it
--     deliberately fetches two extra rows beyond the band so the 3x3 window
--     has a row of context above and below) -- i.e. it wrote past the end.
--   * SSD_calc_process reads up to (row+1)*WIDTH+col+1, which for the last
--     row of a band is also WIDTH*fetchBlock+2*WIDTH.
-- Out-of-range access on a VHDL array is an error in simulation and reads
-- back undefined bits in synthesis, so the bottom rows of every band were
-- matching against garbage. Sizing to WIDTH*fetchBlock+2*WIDTH covers
-- exactly the range both processes address.
type CacheArray is array(0 to WIDTH*fetchBlock + 2*WIDTH) of std_logic_vector(3 downto 0);
signal org_L : CacheArray; --temporary storage for Left image
signal org_R : CacheArray; --temporary storage for Right image

signal row,row_fetch :std_logic_vector(8 downto 0); --row index of the image
signal col,col_fetch :std_logic_vector(8 downto 0); --column index of the Left image

signal offset,best_offset :std_logic_vector(7 downto 0);
signal offsetping,offsetfound  : std_logic ;

signal ssd,prev_ssd :std_logic_vector(20 downto 0); --sum of squared difference

signal data_count,readreg :std_logic_vector(16 downto 0); --data counting for entire pixels of the image
signal doneFetch: std_logic;

signal cacheManager  :std_logic_vector(3 downto 0);
signal SSD_calc : std_logic;
signal frame_done_r : std_logic := '0';
signal window_valid : std_logic;

-- Number of row-bands per frame. The reference design never spelled this
-- out: it just let the 4-bit cacheManager free-run 0..15, which happened to
-- be exactly right for its own geometry (15 rows/band * 16 bands = 240 =
-- its HEIGHT). That coincidence does NOT hold at this port's 160x120 with
-- fetchBlock=8 (8*16 = 128 rows, but HEIGHT is 120), so a free-running
-- counter would process 8 phantom rows past the bottom of every frame --
-- writing disparity output past the end of the image and delaying
-- frame_done. Derived from the generics instead so it stays correct if the
-- resolution is retuned. Must be <= 16 (cacheManager is 4 bits) and should
-- divide HEIGHT exactly.
constant NBANDS : positive := HEIGHT / fetchBlock;

-- row*WIDTH+col-best_offset as a native VHDL integer can go negative near
-- the left edge of a row whenever best_offset > col (very common -- offset
-- search starts at minoffset=1 upward every pixel, so this isn't a rare
-- corner case, it happens routinely at low `col`). to_unsigned() of a
-- negative value is undefined by the IEEE numeric_std spec for synthesis
-- purposes; the original design got away with it by sizing its target RAM
-- to the full address-bus range so any wraparound landed somewhere
-- "harmless". This port uses a right-sized RAM instead (to fit XC7Z010's
-- smaller BRAM budget), so the subtraction is clamped to zero here instead
-- of relying on wraparound-into-padding.
signal out_addr_base : unsigned(16 downto 0);

begin

-- Elaboration-time guards on the generic combination, so a future
-- resolution retune fails loudly at build time instead of silently
-- producing a frame with the wrong number of rows.
assert HEIGHT = NBANDS * fetchBlock
  report "disparity_generator: fetchBlock must divide HEIGHT exactly"
  severity failure;
assert NBANDS <= 16
  report "disparity_generator: HEIGHT/fetchBlock must be <= 16 (cacheManager is 4 bits)"
  severity failure;

frame_done <= frame_done_r;

process(row, col, best_offset)
  variable row_col : integer;
begin
  row_col := to_integer(unsigned(row)) * WIDTH + to_integer(unsigned(col));
  if row_col < to_integer(unsigned(best_offset)) then
    out_addr_base <= (others => '0');
  else
    out_addr_base <= to_unsigned(row_col - to_integer(unsigned(best_offset)), 17);
  end if;
end process;


with cacheManager select
    left_right_addr <= readreg when "0000",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock-WIDTH, readreg'length)) when "0001",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*2-WIDTH, readreg'length))   when "0010",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*3-WIDTH, readreg'length))   when "0011",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*4-WIDTH, readreg'length)) when "0100",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*5-WIDTH, readreg'length))   when "0101",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*6-WIDTH, readreg'length))   when "0110",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*7-WIDTH, readreg'length)) when "0111",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*8-WIDTH, readreg'length))   when "1000",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*9-WIDTH, readreg'length))   when "1001",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*10-WIDTH, readreg'length)) when "1010",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*11-WIDTH, readreg'length))   when "1011",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*12-WIDTH, readreg'length))   when "1100",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*13-WIDTH, readreg'length))   when "1101",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*14-WIDTH, readreg'length)) when "1110",
                readreg + std_logic_vector(to_unsigned(WIDTH*fetchBlock*15-WIDTH, readreg'length))   when "1111";

with cacheManager select
    dOUT_addr <=std_logic_vector(out_addr_base) when "0000",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock, dOUT_addr'length))  when "0001",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*2, dOUT_addr'length))   when "0010",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*3, dOUT_addr'length))   when "0011",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*4, dOUT_addr'length)) when "0100",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*5, dOUT_addr'length))   when "0101",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*6, dOUT_addr'length))   when "0110",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*7, dOUT_addr'length)) when "0111",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*8, dOUT_addr'length))   when "1000",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*9, dOUT_addr'length))   when "1001",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*10, dOUT_addr'length)) when "1010",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*11, dOUT_addr'length))   when "1011",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*12, dOUT_addr'length))   when "1100",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*13, dOUT_addr'length))   when "1101",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*14, dOUT_addr'length))   when "1110",
                std_logic_vector(out_addr_base) + std_logic_vector(to_unsigned(WIDTH*fetchBlock*15, dOUT_addr'length))   when "1111";

avg_reg_en <= not doneFetch;




caching_process: process (HCLK) begin
    if rising_edge(HCLK) then
        if doneFetch='0' then
            if unsigned(readreg)<WIDTH*fetchBlock+2*WIDTH then -- replace fetchBlock with height if fetchBlock concept is removed
               org_L(to_integer(unsigned(readreg)))<= left_in;
               org_R(to_integer(unsigned(readreg)))<= right_in;
               avg_out<=std_logic_vector(unsigned(left_in)/2) + std_logic_vector(unsigned(right_in)/2);
               readreg<=readreg+"1";
            else
               readreg <= (others => '0');
            end if;
        end if;
    end if;
end process;


Image_process: process (CLK_MAIN) begin
    if rising_edge(CLK_MAIN) then
        frame_done_r <= '0';
        if unsigned(readreg)=WIDTH*fetchBlock then -- replace fetchBlock with height if fetchBlock concept is removed
            doneFetch <='1';
        end if;
        if doneFetch='1' then
            if unsigned(data_count)<WIDTH*fetchBlock+WIDTH then -- replace fetchBlock with height if fetchBlock concept is removed
                if (offsetfound='1') then
                    if(col = WIDTH - 1) then
                        col <= (others => '0');
                        row <= row + 1;
                    else
                        col <= col + 1;
                    end if;
                    data_count<=data_count+"1";
                    offsetfound <= '0';
                    best_offset <= (others => '0');
                    prev_ssd <= (others => '1');
                    offset <= std_logic_vector(to_unsigned(minoffset,offset'length));
                else
                    if(offset=maxoffset) then
                        offsetfound <= '1';
                    else
                        offset<=offset+1;
                    end if;
                    offsetping<='1';
                end if;

                if (ssd < prev_ssd and SSD_calc='1') then
                  prev_ssd <= ssd;
                  best_offset <= offset;
                end if;
                if SSD_calc='1' then
                    offsetping<='0';
                end if;
            else
                if cacheManager = std_logic_vector(to_unsigned(NBANDS-1, cacheManager'length)) then
                    frame_done_r <= '1'; -- last row-band of the frame just finished
                    cacheManager <= (others => '0');
                else
                    cacheManager<=cacheManager+"1"; --Comment this if remove fetchBlock concept
                end if;
                data_count <= std_logic_vector(to_unsigned(WIDTH,data_count'length));
                doneFetch <='0';
                row<=std_logic_vector(to_unsigned(1,row'length));
            end if;

        end if;

    end if;
end process;

-- BUGFIX vs. the reference design: the window is only well-defined when
-- every index below stays inside the cache array. The lowest index used is
-- (row-1)*WIDTH + col-1 - offset, which goes NEGATIVE whenever
-- offset >= col (routine, not a corner case: offset sweeps minoffset..
-- maxoffset for every pixel, so all of the leftmost `maxoffset` columns hit
-- it) or when row = 0. A negative VHDL array index is an error in
-- simulation and undefined bits in synthesis, and because the resulting
-- garbage still took part in the `ssd < prev_ssd` comparison it could win
-- and be emitted as a real disparity value. window_valid gates that off,
-- and invalid windows are forced to the maximum SSD so they can never win.
window_valid <= '1' when (to_integer(unsigned(col)) > to_integer(unsigned(offset)))
                     and (to_integer(unsigned(row)) >= 1)
                else '0';

SSD_calc_process: process (CLK_MAIN) begin
    if rising_edge(CLK_MAIN) then
        SSD_calc<='0';
        if (offsetping='1') then
          if window_valid = '0' then
            ssd <= (others => '1'); -- max: never beats prev_ssd
          else
            ssd <=  std_logic_vector(to_unsigned(
                        (to_integer(unsigned(org_L((to_integer(unsigned(row))  -1 ) * WIDTH + to_integer(unsigned(col))  -1   )))-to_integer(unsigned(org_R((to_integer(unsigned(row))  -1 ) * WIDTH + to_integer(unsigned(col))  -1 - to_integer(unsigned(offset))))))*(to_integer(unsigned(org_L((to_integer(unsigned(row))   -1 ) * WIDTH + to_integer(unsigned(col))  -1   )))-to_integer(unsigned(org_R((to_integer(unsigned(row))   -1 ) * WIDTH + to_integer(unsigned(col))  -1 - to_integer(unsigned(offset))))))
                        +(to_integer(unsigned(org_L((to_integer(unsigned(row))  -1 ) * WIDTH + to_integer(unsigned(col)) + 0   )))-to_integer(unsigned(org_R((to_integer(unsigned(row))  -1 ) * WIDTH + to_integer(unsigned(col)) + 0 - to_integer(unsigned(offset))))))*(to_integer(unsigned(org_L((to_integer(unsigned(row))   -1 ) * WIDTH + to_integer(unsigned(col)) + 0   )))-to_integer(unsigned(org_R((to_integer(unsigned(row))   -1 ) * WIDTH + to_integer(unsigned(col)) + 0 - to_integer(unsigned(offset))))))
                        +(to_integer(unsigned(org_L((to_integer(unsigned(row))  -1 ) * WIDTH + to_integer(unsigned(col)) + 1   )))-to_integer(unsigned(org_R((to_integer(unsigned(row))  -1 ) * WIDTH + to_integer(unsigned(col)) + 1 - to_integer(unsigned(offset))))))*(to_integer(unsigned(org_L((to_integer(unsigned(row))   -1 ) * WIDTH + to_integer(unsigned(col)) + 1   )))-to_integer(unsigned(org_R((to_integer(unsigned(row))   -1 ) * WIDTH + to_integer(unsigned(col)) + 1 - to_integer(unsigned(offset))))))
                        +(to_integer(unsigned(org_L((to_integer(unsigned(row)) + 0 ) * WIDTH + to_integer(unsigned(col))  -1   )))-to_integer(unsigned(org_R((to_integer(unsigned(row)) + 0 ) * WIDTH + to_integer(unsigned(col))  -1 - to_integer(unsigned(offset))))))*(to_integer(unsigned(org_L((to_integer(unsigned(row)) +  0 ) * WIDTH + to_integer(unsigned(col))  -1   )))-to_integer(unsigned(org_R((to_integer(unsigned(row)) +  0 ) * WIDTH + to_integer(unsigned(col))  -1 - to_integer(unsigned(offset))))))
                        +(to_integer(unsigned(org_L((to_integer(unsigned(row)) + 0 ) * WIDTH + to_integer(unsigned(col)) + 0   )))-to_integer(unsigned(org_R((to_integer(unsigned(row)) + 0 ) * WIDTH + to_integer(unsigned(col)) + 0 - to_integer(unsigned(offset))))))*(to_integer(unsigned(org_L((to_integer(unsigned(row)) +  0 ) * WIDTH + to_integer(unsigned(col)) + 0   )))-to_integer(unsigned(org_R((to_integer(unsigned(row)) +  0 ) * WIDTH + to_integer(unsigned(col)) + 0 - to_integer(unsigned(offset))))))
                        +(to_integer(unsigned(org_L((to_integer(unsigned(row)) + 0 ) * WIDTH + to_integer(unsigned(col)) + 1   )))-to_integer(unsigned(org_R((to_integer(unsigned(row)) + 0 ) * WIDTH + to_integer(unsigned(col)) + 1 - to_integer(unsigned(offset))))))*(to_integer(unsigned(org_L((to_integer(unsigned(row)) +  0 ) * WIDTH + to_integer(unsigned(col)) + 1   )))-to_integer(unsigned(org_R((to_integer(unsigned(row)) +  0 ) * WIDTH + to_integer(unsigned(col)) + 1 - to_integer(unsigned(offset))))))
                        +(to_integer(unsigned(org_L((to_integer(unsigned(row)) + 1 ) * WIDTH + to_integer(unsigned(col))  -1   )))-to_integer(unsigned(org_R((to_integer(unsigned(row)) + 1 ) * WIDTH + to_integer(unsigned(col))  -1 - to_integer(unsigned(offset))))))*(to_integer(unsigned(org_L((to_integer(unsigned(row)) +  1 ) * WIDTH + to_integer(unsigned(col))  -1   )))-to_integer(unsigned(org_R((to_integer(unsigned(row)) +  1 ) * WIDTH + to_integer(unsigned(col))  -1 - to_integer(unsigned(offset))))))
                        +(to_integer(unsigned(org_L((to_integer(unsigned(row)) + 1 ) * WIDTH + to_integer(unsigned(col)) + 0   )))-to_integer(unsigned(org_R((to_integer(unsigned(row)) + 1 ) * WIDTH + to_integer(unsigned(col)) + 0 - to_integer(unsigned(offset))))))*(to_integer(unsigned(org_L((to_integer(unsigned(row)) +  1 ) * WIDTH + to_integer(unsigned(col)) + 0   )))-to_integer(unsigned(org_R((to_integer(unsigned(row)) +  1 ) * WIDTH + to_integer(unsigned(col)) + 0 - to_integer(unsigned(offset))))))
                        ,ssd'length));
          end if;
          SSD_calc<='1';

        else
            ssd<=(others => '0');
        end if;
    end if;
end process;

-- BUGFIX vs. the reference design, two issues in this process:
--   * The sensitivity/edge condition was `process (offsetfound,HCLK)` with
--     `if rising_edge(offsetfound) or rising_edge(HCLK)`. rising_edge() on
--     a non-clock data signal isn't synthesizable as written -- Vivado
--     resolves it by treating HCLK as the only clock and dropping the
--     offsetfound edge, so the hardware never matched the source. Made that
--     explicit instead of relying on the tool to silently reinterpret it;
--     this is what the built design was already doing.
--   * `(best_offset - minoffset)*4` underflows when best_offset <
--     minoffset. best_offset is reset to 0 for every pixel and only updated
--     when some offset wins, so 0 is reachable whenever no valid window
--     won (which is now the normal case for the leftmost columns, see
--     window_valid above) -- to_unsigned() of a negative value is
--     undefined. Clamped to 0, i.e. "no disparity found here".
Image_write_process: process (HCLK) begin
    if rising_edge(HCLK) then
        if (offsetfound='1') then
            wr_en<='1';
            if to_integer(unsigned(best_offset)) >= minoffset then
                dOUT <= std_logic_vector(to_unsigned(
                          (to_integer(unsigned(best_offset)) - minoffset) * 4,
                          dOUT'length));
            else
                dOUT <= (others => '0');
            end if;
        else
            wr_en<='0';
        end if;
    end if;
end process;

end Behavioral;

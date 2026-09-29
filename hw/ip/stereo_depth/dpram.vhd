----------------------------------------------------------------------------------
-- Generic true dual-port RAM, independent clocks, symmetric read/write on
-- both ports, with per-lane write enables (WE_WIDTH lanes, each
-- DATA_WIDTH/WE_WIDTH bits wide -- WE_WIDTH=1 for a plain single-enable
-- word, e.g. WE_WIDTH=4 for byte-enables on a 32-bit word). Standard
-- inferred-BRAM description (Vivado maps this to block RAM automatically)
-- -- replaces the reference project's Block Memory Generator IP instances
-- ("frame_buffer", "disparity_ram") with something that doesn't require
-- replicating GUI-configured IP parameters blindly in Tcl, and that plugs
-- directly into an AXI BRAM Controller's native port on side B without any
-- missing pins (AXI BRAM Controller drives byte-lane we bits directly).
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity dpram is
  generic (
    DATA_WIDTH : positive := 8;
    WE_WIDTH   : positive := 1; -- DATA_WIDTH must be a multiple of this
    ADDR_WIDTH : positive := 17;
    DEPTH      : positive := 131072 -- 2**ADDR_WIDTH; kept a plain power of
                                     -- two (not trimmed to the pixels
                                     -- actually used) so port address
                                     -- never needs a bounds check below --
                                     -- that check risks falling out of
                                     -- BRAM inference into distributed
                                     -- LUTRAM
  );
  Port (
    clka  : in  STD_LOGIC;
    wea   : in  STD_LOGIC_VECTOR (WE_WIDTH-1 downto 0);
    addra : in  STD_LOGIC_VECTOR (ADDR_WIDTH-1 downto 0);
    dina  : in  STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0);
    douta : out STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0);

    clkb  : in  STD_LOGIC;
    web   : in  STD_LOGIC_VECTOR (WE_WIDTH-1 downto 0);
    addrb : in  STD_LOGIC_VECTOR (ADDR_WIDTH-1 downto 0);
    dinb  : in  STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0);
    doutb : out STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0)
  );
end dpram;

architecture rtl of dpram is
  constant LANE_WIDTH : positive := DATA_WIDTH / WE_WIDTH;
  type ram_t is array (0 to DEPTH-1) of STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0);
  shared variable ram : ram_t := (others => (others => '0'));
begin

  process(clka)
  begin
    if rising_edge(clka) then
      for lane in 0 to WE_WIDTH-1 loop
        if wea(lane) = '1' then
          ram(to_integer(unsigned(addra)))((lane+1)*LANE_WIDTH-1 downto lane*LANE_WIDTH)
            := dina((lane+1)*LANE_WIDTH-1 downto lane*LANE_WIDTH);
        end if;
      end loop;
      douta <= ram(to_integer(unsigned(addra)));
    end if;
  end process;

  process(clkb)
  begin
    if rising_edge(clkb) then
      for lane in 0 to WE_WIDTH-1 loop
        if web(lane) = '1' then
          ram(to_integer(unsigned(addrb)))((lane+1)*LANE_WIDTH-1 downto lane*LANE_WIDTH)
            := dinb((lane+1)*LANE_WIDTH-1 downto lane*LANE_WIDTH);
        end if;
      end loop;
      doutb <= ram(to_integer(unsigned(addrb)));
    end if;
  end process;

end rtl;

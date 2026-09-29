----------------------------------------------------------------------------------
-- preview_buffer: a PS-readable copy of one camera's captured frame.
--
-- The real frame buffers cannot serve this: both ports are already spoken
-- for (camera writes on A, disparity engine reads on B), and a dual-port
-- BRAM has no third port. Time-sharing port B with AXI would stall the
-- disparity engine at unpredictable moments, so this takes a separate tap
-- off the same capture stream instead.
--
-- Storage is deliberately packed 8 pixels per 32-bit word. Captured pixels
-- are only 4 bits, so storing one per byte would waste 4x the BRAM -- and
-- at 40/60 blocks already used by the rest of the design, two byte-per-pixel
-- preview buffers would not have fit. Packed, each buffer is 4096 words
-- (32 Kbit) and both together cost ~8 blocks.
--
-- Host-side unpacking: pixel i lives in word i/8, nibble i%8, least
-- significant nibble first.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity preview_buffer is
  generic (
    ADDR_WIDTH : positive := 12;          -- 4096 words = 32768 pixels
    DEPTH      : positive := 4096
  );
  Port (
    -- capture side (camera PCLK domain)
    pclk   : in STD_LOGIC;
    vsync  : in STD_LOGIC;                -- frame restart
    we     : in STD_LOGIC;
    wdata  : in STD_LOGIC_VECTOR(3 downto 0);

    -- Snapshot handshake. Without this the PS reads a buffer the camera is
    -- still overwriting, so a readout splices together strips from several
    -- different frames -- visible as horizontal banding/tearing.
    --   arm   : hold high to request one fresh frame
    --   ready : goes high once exactly one complete frame has been captured;
    --           writes are frozen from then until arm is dropped.
    -- Deliberately not double-buffered: that would double the BRAM cost of
    -- every preview, and this design is already using most of the device's
    -- block RAM. Freezing is free and a preview does not need full rate.
    arm    : in  STD_LOGIC;
    ready  : out STD_LOGIC;

    -- AXI side
    axi_clk   : in  STD_LOGIC;
    axi_web   : in  STD_LOGIC_VECTOR(3 downto 0);
    axi_addrb : in  STD_LOGIC_VECTOR(ADDR_WIDTH-1 downto 0);
    axi_dinb  : in  STD_LOGIC_VECTOR(31 downto 0);
    axi_doutb : out STD_LOGIC_VECTOR(31 downto 0)
  );
end preview_buffer;

architecture rtl of preview_buffer is

  component dpram
    generic ( DATA_WIDTH : positive; WE_WIDTH : positive;
              ADDR_WIDTH : positive; DEPTH : positive );
    Port ( clka  : in  STD_LOGIC;
           wea   : in  STD_LOGIC_VECTOR (WE_WIDTH-1 downto 0);
           addra : in  STD_LOGIC_VECTOR (ADDR_WIDTH-1 downto 0);
           dina  : in  STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0);
           douta : out STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0);
           clkb  : in  STD_LOGIC;
           web   : in  STD_LOGIC_VECTOR (WE_WIDTH-1 downto 0);
           addrb : in  STD_LOGIC_VECTOR (ADDR_WIDTH-1 downto 0);
           dinb  : in  STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0);
           doutb : out STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0));
  end component;

  type snap_state_t is (SNAP_IDLE, SNAP_WAIT_START, SNAP_CAPTURING, SNAP_DONE);
  signal snap     : snap_state_t := SNAP_IDLE;
  signal capturing : STD_LOGIC := '0';

  signal shreg    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
  signal nib_cnt  : unsigned(2 downto 0) := (others => '0');
  signal word_adr : unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
  signal word_we  : STD_LOGIC := '0';
  signal vsync_d  : STD_LOGIC := '0';

  signal wea_vec : STD_LOGIC_VECTOR(3 downto 0);
begin

  capturing <= '1' when snap = SNAP_CAPTURING else '0';
  ready     <= '1' when snap = SNAP_DONE      else '0';

  -- Arm -> wait for a frame boundary -> capture exactly one frame -> freeze.
  -- Starting mid-frame is what produces a spliced image, so capture only
  -- ever begins on a VSYNC edge.
  snap_fsm: process(pclk)
  begin
    if rising_edge(pclk) then
      case snap is
        when SNAP_IDLE =>
          if arm = '1' then
            snap <= SNAP_WAIT_START;
          end if;

        when SNAP_WAIT_START =>
          if arm = '0' then
            snap <= SNAP_IDLE;
          elsif vsync = '1' and vsync_d = '0' then
            snap <= SNAP_CAPTURING;
          end if;

        when SNAP_CAPTURING =>
          if arm = '0' then
            snap <= SNAP_IDLE;
          elsif vsync = '1' and vsync_d = '0' then
            snap <= SNAP_DONE;       -- next frame started: this one is whole
          end if;

        when SNAP_DONE =>
          if arm = '0' then
            snap <= SNAP_IDLE;       -- PS finished reading
          end if;
      end case;
    end if;
  end process;

  process(pclk)
  begin
    if rising_edge(pclk) then
      word_we <= '0';
      vsync_d <= vsync;

      -- Restart on the rising edge of VSYNC so a torn frame can't shift
      -- every subsequent pixel for the rest of the capture.
      if vsync = '1' and vsync_d = '0' then
        nib_cnt  <= (others => '0');
        word_adr <= (others => '0');
      elsif we = '1' and capturing = '1' then
        -- Shift in from the top: pixel i ends up in nibble i mod 8, least
        -- significant nibble first once the word is complete.
        shreg <= wdata & shreg(31 downto 4);
        if nib_cnt = 7 then
          nib_cnt <= (others => '0');
          word_we <= '1';
        else
          nib_cnt <= nib_cnt + 1;
        end if;
      end if;

      if word_we = '1' and word_adr /= to_unsigned(DEPTH-1, word_adr'length) then
        word_adr <= word_adr + 1;
      end if;
    end if;
  end process;

  wea_vec <= (others => word_we);

  Inst_ram: dpram
    generic map (DATA_WIDTH => 32, WE_WIDTH => 4,
                 ADDR_WIDTH => ADDR_WIDTH, DEPTH => DEPTH)
    port map (
      clka => pclk, wea => wea_vec,
      addra => std_logic_vector(word_adr), dina => shreg, douta => open,
      clkb => axi_clk, web => axi_web, addrb => axi_addrb,
      dinb => axi_dinb, doutb => axi_doutb
    );

end rtl;

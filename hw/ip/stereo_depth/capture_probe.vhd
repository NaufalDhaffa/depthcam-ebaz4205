----------------------------------------------------------------------------------
-- capture_probe: diagnostic counters one level deeper than cam_activity.
--
-- cam_activity answers "do the camera signals reach the FPGA pins". This
-- answers the next question: "does ov7670_capture actually latch them into
-- the frame buffers". Those are very different failures with identical
-- symptoms downstream -- a frame buffer that is never written reads back as
-- all zeros, which makes every SSD comparison tie, which makes the
-- disparity engine emit one constant value for the whole image. That is
-- indistinguishable, from the output alone, from a camera that is dead.
--
-- Lives in each camera's PCLK domain (that is where ov7670_capture runs).
-- As with cam_activity, the outputs are read without CDC synchronisation:
-- the only question asked of them is "did these numbers change between two
-- reads", for which a torn word is harmless.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity capture_probe is
  Port (
    pclk_l  : in STD_LOGIC;
    we_l    : in STD_LOGIC;
    wdata_l : in STD_LOGIC_VECTOR(3 downto 0);
    vsync_l : in STD_LOGIC;
    href_l  : in STD_LOGIC;

    pclk_r  : in STD_LOGIC;
    we_r    : in STD_LOGIC;
    wdata_r : in STD_LOGIC_VECTOR(3 downto 0);
    vsync_r : in STD_LOGIC;
    href_r  : in STD_LOGIC;

    -- [15:0]  cam1 write-enable pulse count
    -- [31:16] cam2 write-enable pulse count
    we_counts : out STD_LOGIC_VECTOR(31 downto 0);

    -- [3:0]  sticky OR of every nibble written for cam1
    -- [7:4]  sticky OR of every nibble written for cam2
    -- [11:8] sticky AND of every nibble written for cam1 (stuck-high check)
    -- [15:12] sticky AND for cam2
    -- [16]   cam1 vsync live level   [17] cam1 href live level
    -- [18]   cam2 vsync live level   [19] cam2 href live level
    wdata_info : out STD_LOGIC_VECTOR(31 downto 0)
  );
end capture_probe;

architecture rtl of capture_probe is
  signal cnt_l, cnt_r : unsigned(15 downto 0) := (others => '0');
  signal or_l,  or_r  : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');
  signal and_l, and_r : STD_LOGIC_VECTOR(3 downto 0) := (others => '1');
begin

  process(pclk_l)
  begin
    if rising_edge(pclk_l) then
      if we_l = '1' then
        cnt_l <= cnt_l + 1;
        -- OR and AND together bracket the data: all-zero OR means nothing
        -- but zeros were ever written, all-one AND means the bus is stuck
        -- high. A real image sets OR to 1111 and leaves AND at 0000.
        or_l  <= or_l  or  wdata_l;
        and_l <= and_l and wdata_l;
      end if;
    end if;
  end process;

  process(pclk_r)
  begin
    if rising_edge(pclk_r) then
      if we_r = '1' then
        cnt_r <= cnt_r + 1;
        or_r  <= or_r  or  wdata_r;
        and_r <= and_r and wdata_r;
      end if;
    end if;
  end process;

  we_counts <= std_logic_vector(cnt_r) & std_logic_vector(cnt_l);

  -- 8 + 4 + 4 + 16 = 32 bits exactly.
  wdata_info <= x"00" &
                "0000" &
                (href_r & vsync_r & href_l & vsync_l) &
                and_r & and_l & or_r & or_l;

end rtl;

----------------------------------------------------------------------------------
-- cam_activity: diagnostic activity counters for one OV7670's pixel-data
-- path, so "is this signal actually arriving?" can be answered without an
-- ILA (system_ila is license-blocked on this setup -- see the
-- zynq-fpga-bringup notes; this is the documented GPIO-counter workaround).
--
-- Everything here lives in the camera's own PCLK domain. If PCLK itself is
-- dead, nothing counts and every field reads zero -- which is exactly the
-- signal we want: it distinguishes "no clock at all" from "clock runs but
-- sync/data lines are stuck".
--
-- The 32-bit `status` output is sampled by the PS through an AXI GPIO with
-- no CDC synchroniser. That is deliberate and safe for this purpose: the
-- PS only ever asks "did these numbers change between two reads", so a
-- torn intermediate value costs nothing. Do not reuse this output for
-- anything that needs a coherent snapshot.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity cam_activity is
  Port (
    pclk   : in  STD_LOGIC;
    vsync  : in  STD_LOGIC;
    href   : in  STD_LOGIC;
    pdata  : in  STD_LOGIC_VECTOR(7 downto 0);
    -- [11:0]  free-running PCLK cycle counter   -> PCLK alive?
    -- [17:12] VSYNC rising-edge counter         -> frames arriving?
    -- [23:18] HREF  rising-edge counter         -> lines arriving?
    -- [31:24] sticky OR of each data bit        -> any line stuck low?
    status : out STD_LOGIC_VECTOR(31 downto 0)
  );
end cam_activity;

architecture rtl of cam_activity is
  signal pclk_cnt  : unsigned(11 downto 0) := (others => '0');
  signal vsync_cnt : unsigned(5 downto 0)  := (others => '0');
  signal href_cnt  : unsigned(5 downto 0)  := (others => '0');
  signal data_or   : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
  signal vsync_d, href_d : STD_LOGIC := '0';
begin

  process(pclk)
  begin
    if rising_edge(pclk) then
      pclk_cnt <= pclk_cnt + 1;

      vsync_d <= vsync;
      href_d  <= href;
      if vsync = '1' and vsync_d = '0' then
        vsync_cnt <= vsync_cnt + 1;
      end if;
      if href = '1' and href_d = '0' then
        href_cnt <= href_cnt + 1;
      end if;

      -- Sticky: a bit that never sets means that data line never went high
      -- (broken wire / stuck at 0). All eight setting quickly is the
      -- healthy case for a real image.
      data_or <= data_or or pdata;
    end if;
  end process;

  status <= data_or
            & std_logic_vector(href_cnt)
            & std_logic_vector(vsync_cnt)
            & std_logic_vector(pclk_cnt);

end rtl;

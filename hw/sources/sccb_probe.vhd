----------------------------------------------------------------------------------
-- sccb_probe: standalone OV7670 SCCB liveness check.
--
-- Reads the PID register (0x0A, expected 0x76) over SCCB (OV7670's I2C-like
-- control bus) and drives probe_ok high only when all three ACKs (device ID
-- write, register address write, device ID read) come back asserted AND the
-- read-back byte matches the expected PID. Retries forever on a ~0.5s cycle
-- so probe_ok reflects live status.
--
-- Deliberately NOT reusing the reference project's i2c_sender.vhd (it never
-- samples ACK, so it can't tell a live camera from a dead one) or i3c2.vhd
-- (undocumented microcode ISA, no known-good program to seed it with). This
-- is a plain, explicit bit-bang FSM so every step is traceable without ILA.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sccb_probe is
  generic (
    CLK_FREQ_HZ  : integer := 50_000_000;
    SCCB_FREQ_HZ : integer := 100_000;
    DEV_ID_W     : std_logic_vector(7 downto 0) := x"42";
    DEV_ID_R     : std_logic_vector(7 downto 0) := x"43";
    REG_ADDR     : std_logic_vector(7 downto 0) := x"0A"; -- PID
    EXPECT_VAL   : std_logic_vector(7 downto 0) := x"76";
    HOLD_SECONDS : integer := 1 -- retry period, in whole seconds (approx)
  );
  port (
    clk      : in    std_logic;
    xclk     : out   std_logic;
    sioc     : out   std_logic;
    siod     : inout std_logic;
    pwdn     : out   std_logic;
    reset_n  : out   std_logic;
    probe_ok : out   std_logic
  );
end sccb_probe;

architecture rtl of sccb_probe is

  constant QUARTER_TICKS : integer := CLK_FREQ_HZ / SCCB_FREQ_HZ / 4; -- clk cycles per SCCB quarter-bit
  constant GAP_QUARTERS  : integer := 4;                              -- bus-free gap between the two SCCB transactions
  constant HOLD_QUARTERS : integer := (CLK_FREQ_HZ / QUARTER_TICKS) * HOLD_SECONDS; -- quarter-ticks per retry period

  type phase_t is (
    PH_START1, PH_TX_IDW, PH_TX_REG, PH_STOP1, PH_GAP,
    PH_START2, PH_TX_IDR, PH_RX_BYTE, PH_STOP2, PH_EVAL, PH_HOLD
  );
  signal phase      : phase_t := PH_START1;
  signal bit_state  : integer range 0 to 8 := 0;
  signal quarter    : integer range 0 to 3 := 0;
  signal tick_cnt   : integer range 0 to QUARTER_TICKS-1 := 0;
  signal hold_cnt   : integer range 0 to HOLD_QUARTERS-1 := 0;

  signal tx_byte      : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_shift      : std_logic_vector(7 downto 0) := (others => '0');
  signal ack1, ack2, ack3 : std_logic := '1'; -- '0' = ACK seen

  signal sioc_r        : std_logic := '1';
  signal sda_drive_low  : std_logic := '0'; -- '1' = actively pull SDA low, '0' = release (Z)
  signal xclk_i         : std_logic := '0';
  signal probe_ok_r     : std_logic := '0';

begin

  reset_n <= '1'; -- normal operating mode (active-low reset held high)
  pwdn    <= '0'; -- powered up (not in power-down)

  -- XCLK: required before the sensor's internal logic (incl. SCCB) runs at
  -- all. Simple divide-by-2 of the system clock, same approach as the
  -- reference project (50MHz in -> 25MHz out, within OV7670's valid range).
  process(clk)
  begin
    if rising_edge(clk) then
      xclk_i <= not xclk_i;
    end if;
  end process;
  xclk <= xclk_i;

  sioc <= sioc_r;
  siod <= '0' when sda_drive_low = '1' else 'Z';
  probe_ok <= probe_ok_r;

  process(clk)
  begin
    if rising_edge(clk) then
      if tick_cnt = QUARTER_TICKS-1 then
        tick_cnt <= 0;

        case phase is

          when PH_START1 | PH_START2 =>
            case quarter is
              when 0 => sioc_r <= '1'; sda_drive_low <= '0'; quarter <= 1;
              when 1 => sioc_r <= '1'; sda_drive_low <= '0'; quarter <= 2;
              when 2 => sioc_r <= '1'; sda_drive_low <= '1'; quarter <= 3; -- SDA falls while SCL high = START
              when others =>
                sioc_r <= '0'; sda_drive_low <= '1'; quarter <= 0; bit_state <= 0;
                if phase = PH_START1 then
                  tx_byte <= DEV_ID_W; phase <= PH_TX_IDW;
                else
                  tx_byte <= DEV_ID_R; phase <= PH_TX_IDR;
                end if;
            end case;

          when PH_TX_IDW | PH_TX_REG | PH_TX_IDR =>
            if bit_state < 8 then
              case quarter is
                when 0 =>
                  sioc_r <= '0';
                  if tx_byte(7 - bit_state) = '0' then
                    sda_drive_low <= '1';
                  else
                    sda_drive_low <= '0';
                  end if;
                  quarter <= 1;
                when 1 => sioc_r <= '0'; quarter <= 2;
                when 2 => sioc_r <= '1'; quarter <= 3; -- data sampled by slave on this rising edge
                when others => sioc_r <= '1'; quarter <= 0; bit_state <= bit_state + 1;
              end case;
            else -- bit_state = 8: ACK slot, release SDA and sample it
              case quarter is
                when 0 => sioc_r <= '0'; sda_drive_low <= '0'; quarter <= 1;
                when 1 => sioc_r <= '0'; quarter <= 2;
                when 2 =>
                  sioc_r <= '1'; quarter <= 3;
                  case phase is
                    when PH_TX_IDW => ack1 <= siod;
                    when PH_TX_REG => ack2 <= siod;
                    when PH_TX_IDR => ack3 <= siod;
                    when others    => null;
                  end case;
                when others =>
                  sioc_r <= '1'; quarter <= 0; bit_state <= 0;
                  case phase is
                    when PH_TX_IDW => tx_byte <= REG_ADDR; phase <= PH_TX_REG;
                    when PH_TX_REG => phase <= PH_STOP1;
                    when PH_TX_IDR => sda_drive_low <= '0'; phase <= PH_RX_BYTE;
                    when others    => null;
                  end case;
              end case;
            end if;

          when PH_STOP1 | PH_STOP2 =>
            case quarter is
              when 0 => sioc_r <= '0'; sda_drive_low <= '1'; quarter <= 1;
              when 1 => sioc_r <= '1'; sda_drive_low <= '1'; quarter <= 2;
              when 2 => sioc_r <= '1'; sda_drive_low <= '0'; quarter <= 3; -- SDA rises while SCL high = STOP
              when others =>
                sioc_r <= '1'; sda_drive_low <= '0'; quarter <= 0;
                if phase = PH_STOP1 then
                  hold_cnt <= 0; phase <= PH_GAP;
                else
                  phase <= PH_EVAL;
                end if;
            end case;

          when PH_GAP =>
            if hold_cnt = GAP_QUARTERS-1 then
              hold_cnt <= 0; quarter <= 0; phase <= PH_START2;
            else
              hold_cnt <= hold_cnt + 1;
            end if;

          when PH_RX_BYTE =>
            if bit_state < 8 then
              case quarter is
                when 0 => sioc_r <= '0'; sda_drive_low <= '0'; quarter <= 1; -- released, slave drives
                when 1 => sioc_r <= '0'; quarter <= 2;
                when 2 =>
                  sioc_r <= '1'; quarter <= 3;
                  rx_shift <= rx_shift(6 downto 0) & siod;
                when others => sioc_r <= '1'; quarter <= 0; bit_state <= bit_state + 1;
              end case;
            else -- bit_state = 8: send NACK (release SDA, single-byte read)
              case quarter is
                when 0 => sioc_r <= '0'; sda_drive_low <= '0'; quarter <= 1;
                when 1 => sioc_r <= '0'; quarter <= 2;
                when 2 => sioc_r <= '1'; quarter <= 3;
                when others => sioc_r <= '1'; quarter <= 0; bit_state <= 0; phase <= PH_STOP2;
              end case;
            end if;

          when PH_EVAL =>
            if ack1 = '0' and ack2 = '0' and ack3 = '0' and rx_shift = EXPECT_VAL then
              probe_ok_r <= '1';
            else
              probe_ok_r <= '0';
            end if;
            hold_cnt <= 0; phase <= PH_HOLD;

          when PH_HOLD =>
            if hold_cnt = HOLD_QUARTERS-1 then
              hold_cnt <= 0; quarter <= 0; bit_state <= 0; phase <= PH_START1;
            else
              hold_cnt <= hold_cnt + 1;
            end if;

        end case;

      else
        tick_cnt <= tick_cnt + 1;
      end if;
    end if;
  end process;

end rtl;

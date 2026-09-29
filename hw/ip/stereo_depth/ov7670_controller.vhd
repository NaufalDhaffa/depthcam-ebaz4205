----------------------------------------------------------------------------------
-- Engineer: Mike Field <hamster@snap.net.nz>
--
-- Description: Controller for the OV7670 camera -- transfers registers to
-- the camera over an I2C-like bus. Shared between both cameras (the
-- reference project's left/right variants only differed by an unused
-- `exposure` port, see ov7670_registers.vhd).
--
-- `reset_n`/`pwdn` are named for their actual polarity here (the reference
-- project just called the first one `reset`): reset_n='1' is normal
-- operating mode (active-low reset held high), pwdn='0' is powered up.
--
-- Ported from Archfx/FPGA-DepthMap-Basys3 (branch 320x240)'s
-- ov7670_controller_left.vhd, itself borrowed from
-- https://github.com/laurivosandi/hdl (MIT licensed).
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ov7670_controller is
    Port ( clk             : in    STD_LOGIC;
           resend          : in    STD_LOGIC;
           config_finished : out   STD_LOGIC;
           sioc            : out   STD_LOGIC;
           siod            : inout STD_LOGIC;
           reset_n         : out   STD_LOGIC;
           pwdn            : out   STD_LOGIC;
           xclk            : out   STD_LOGIC
);
end ov7670_controller;

architecture Behavioral of ov7670_controller is
	component ov7670_registers
	Port ( clk      : in  STD_LOGIC;
	       resend   : in  STD_LOGIC;
	       advance  : in  STD_LOGIC;
	       command  : out std_logic_vector(15 downto 0);
	       finished : out STD_LOGIC);
	end component;

	component i2c_sender
	Port ( clk   : in  STD_LOGIC;
	       siod  : inout STD_LOGIC;
	       sioc  : out STD_LOGIC;
	       taken : out STD_LOGIC;
	       send  : in  STD_LOGIC;
	       id    : in  STD_LOGIC_VECTOR (7 downto 0);
	       reg   : in  STD_LOGIC_VECTOR (7 downto 0);
	       value : in  STD_LOGIC_VECTOR (7 downto 0));
	end component;

	signal sys_clk  : std_logic := '0';
	signal command  : std_logic_vector(15 downto 0);
	signal finished : std_logic := '0';
	signal taken    : std_logic := '0';
	signal send     : std_logic;

	constant camera_address : std_logic_vector(7 downto 0) := x"42"; -- SCCB device write ID
begin
	config_finished <= finished;

	send <= not finished;
	Inst_i2c_sender: i2c_sender port map (
		clk   => clk,
		taken => taken,
		siod  => siod,
		sioc  => sioc,
		send  => send,
		id    => camera_address,
		reg   => command(15 downto 8),
		value => command(7 downto 0)
	);

	reset_n <= '1'; -- normal operating mode
	pwdn    <= '0'; -- powered up
	xclk    <= sys_clk;

	Inst_ov7670_registers: ov7670_registers port map (
		clk      => clk,
		advance  => taken,
		command  => command,
		finished => finished,
		resend   => resend
	);

	process(clk)
	begin
		if rising_edge(clk) then
			sys_clk <= not sys_clk;
		end if;
	end process;
end Behavioral;

----------------------------------------------------------------------------------
-- Adapted from Archfx/FPGA-DepthMap-Basys3 (branch 320x240)'s
-- Image_Rectification.vhd.
--
-- Original mechanism: 4 pushbuttons (plus/minus/plus_col/minus_col) nudge
-- two internal counters up/down while held, at a fixed rate gated by a free
-- running 16-bit counter. EBAZ4205 has no user pushbuttons, so this board
-- has row_offset/col_offset written directly by software over AXI instead
-- -- strictly simpler than porting the nudge-while-held mechanism to a
-- register interface, since software can already just write the target
-- value in one shot. Defaults match the reference project's initial
-- values (adjust=8 i.e. 8*320, adjust_vert=20).
--
-- The original `exposure` output was dead code (driven by nothing --
-- `exposure<=adjust_exposure` was commented out in the source, and the
-- only consumer, ov7670_controller_right's `exposure` input, was itself
-- unused -- see ov7670_registers.vhd's port-list comment) -- dropped here.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.numeric_std.all;

entity image_rectification is
  generic ( WIDTH : positive := 160 ); -- must match disparity_generator's WIDTH
  Port ( address_in    : in  STD_LOGIC_VECTOR (16 downto 0);
         row_offset    : in  STD_LOGIC_VECTOR (3 downto 0) := "1000"; -- multiples of WIDTH
         col_offset    : in  STD_LOGIC_VECTOR (7 downto 0) := "00010100"; -- flat pixel offset
         address_left  : out STD_LOGIC_VECTOR (16 downto 0);
         address_right : out STD_LOGIC_VECTOR (16 downto 0));
end image_rectification;

architecture Behavioral of image_rectification is
begin
  address_left  <= address_in;
  address_right <= std_logic_vector(unsigned(address_in)
                      + (to_integer(unsigned(row_offset)) * WIDTH)
                      + to_integer(unsigned(col_offset)));
end Behavioral;

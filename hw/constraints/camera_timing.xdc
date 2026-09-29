# Implementation-only timing constraints for the camera clock domains.
#
# Kept separate from camera.xdc and marked USED_IN_SYNTHESIS false (see
# hw/scripts/build_bd.tcl) because it names clk_fpga_0, which is created
# inside the PS7 IP's own generated .xdc. That clock does not exist while
# constraints are read during synthesis, so naming it there makes Vivado
# discard the constraint with only a critical warning.
#
# The two camera PCLKs free-run against each other and against the PS clock;
# there is no phase relationship to honour. The design crosses between these
# domains only through the dual-port frame buffers (independent clock per
# port) and the deliberately-unsynchronised diagnostic activity counters, so
# these paths are genuinely asynchronous and must be declared as such rather
# than left for the timing engine to try -- and accidentally appear -- to
# close.
set_clock_groups -asynchronous \
  -group [get_clocks cam_pclk] \
  -group [get_clocks cam2_pclk] \
  -group [get_clocks clk_fpga_0]

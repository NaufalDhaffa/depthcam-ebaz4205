# Standalone SCCB liveness probe for both OV7670 cameras, built as its own
# project separate from build_bd.tcl (the real stereo_cam design). Purpose:
# after both cameras were briefly powered with reversed polarity, check
# whether they still respond on SCCB (read PID reg 0x0A, expect 0x76) before
# committing to the full capture+disparity port. No software/ELF involved —
# result is shown directly on the two board LEDs.
#
# led[0] (green, W13) = camera 1 (DATA1 header) SCCB probe OK
# led[1] (red,   W14) = camera 2 (DATA3 header) SCCB probe OK
#
# Pin assignments and rationale: ../constraints/i2c_probe.xdc

set proj_dir  [file normalize [file join [file dirname [info script]] .. build_i2c_probe]]
set repo_root [file normalize [file join [file dirname [info script]] .. ..]]

create_project i2c_probe_hw $proj_dir -part xc7z010clg400-1 -force
set_property target_language Verilog [current_project]

create_bd_design "system"

# --- PS7: only used here as the FCLK0 clock source for the probe logic.
# UART1/SD0/ENET0/GPIO are left disabled (defaults) since this build needs
# none of them -- keeps the design minimal and decoupled from the main
# project's PS7 config.
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7_0]

apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable"} \
  $ps7

set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0                 {0} \
  CONFIG.PCW_UIPARAM_DDR_PARTNO            {MT41K128M16 JT-125} \
  CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH         {16 Bit} \
  CONFIG.PCW_UIPARAM_DDR_ECC               {Disabled} \
  CONFIG.PCW_UIPARAM_ACT_DDR_FREQ_MHZ      {533.333374} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ      {50} \
] $ps7

# --- sccb_probe module references (plain RTL, not packaged IP) ---
add_files -norecurse [file join $repo_root hw sources sccb_probe.vhd]
update_compile_order -fileset sources_1

set cam1 [create_bd_cell -type module -reference sccb_probe cam1_probe]
set cam2 [create_bd_cell -type module -reference sccb_probe cam2_probe]

connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins cam1_probe/clk]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins cam2_probe/clk]

foreach {inst prefix} {cam1_probe cam cam2_probe cam2} {
  foreach {pin dir} {xclk O sioc O siod IO pwdn O reset_n O} {
    set portname "${prefix}_${pin}"
    create_bd_port -dir $dir $portname
    connect_bd_net [get_bd_pins ${inst}/${pin}] [get_bd_ports $portname]
  }
}

create_bd_port -dir O -from 1 -to 0 led
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat xlconcat_led
set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {1} CONFIG.IN1_WIDTH {1}] [get_bd_cells xlconcat_led]
connect_bd_net [get_bd_pins cam1_probe/probe_ok] [get_bd_pins xlconcat_led/In0]
connect_bd_net [get_bd_pins cam2_probe/probe_ok] [get_bd_pins xlconcat_led/In1]
connect_bd_net [get_bd_pins xlconcat_led/dout] [get_bd_ports led]

validate_bd_design
save_bd_design

make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file join $proj_dir i2c_probe_hw.gen sources_1 bd system hdl system_wrapper.v]
set_property top system_wrapper [current_fileset]

add_files -fileset constrs_1 -norecurse [file join $repo_root hw constraints i2c_probe.xdc]

update_compile_order -fileset sources_1

launch_runs synth_1 -jobs [expr {[exec nproc] < 4 ? [exec nproc] : 4}]
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  error "synth_1 did not complete successfully"
}

launch_runs impl_1 -to_step write_bitstream -jobs [expr {[exec nproc] < 4 ? [exec nproc] : 4}]
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  error "impl_1 did not complete successfully"
}

puts "BUILD_OK: bitstream written to $proj_dir/i2c_probe_hw.runs/impl_1/system_wrapper.bit"

# Build the stereo_cam PS7 block design for EBAZ4205 (XC7Z010CLG400) from
# scratch in Vivado 2026.1 batch mode.
#
# Recreated (not imported) from nightseas/ebit_z7010's 2018.3 project, since
# that repo can't be cloned from this environment and cross-version .xpr
# import carries its own risk. PS7 CONFIG.PCW_* values below were extracted
# from that repo's block-design Tcl; pin/direction/width facts for the raw
# EMIO Ethernet signals were queried directly from the installed 2026.1 PS7
# IP (xilinx.com:ip:processing_system7:5.5) rather than assumed. See
# ../../docs/BOARD_CONFIG.md for the full derivation and sources.

set proj_dir  [file normalize [file join [file dirname [info script]] .. build]]
set repo_root [file normalize [file join [file dirname [info script]] .. ..]]

create_project stereo_cam_hw $proj_dir -part xc7z010clg400-1 -force
set_property target_language Verilog [current_project]

create_bd_design "system"

# --- PS7 ---
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7_0]

apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable"} \
  $ps7

set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0                 {1} \
  CONFIG.PCW_UART1_PERIPHERAL_ENABLE       {1} \
  CONFIG.PCW_UART1_UART1_IO                {MIO 24 .. 25} \
  CONFIG.PCW_SD0_PERIPHERAL_ENABLE         {1} \
  CONFIG.PCW_SD0_SD0_IO                    {MIO 40 .. 45} \
  CONFIG.PCW_SD0_GRP_CD_ENABLE             {0} \
  CONFIG.PCW_SD0_GRP_POW_ENABLE            {0} \
  CONFIG.PCW_SD0_GRP_WP_ENABLE             {0} \
  CONFIG.PCW_SDIO_PERIPHERAL_FREQMHZ       {100} \
  CONFIG.PCW_ENET0_PERIPHERAL_ENABLE       {1} \
  CONFIG.PCW_ENET0_ENET0_IO                {EMIO} \
  CONFIG.PCW_ENET0_GRP_MDIO_ENABLE         {1} \
  CONFIG.PCW_ENET0_GRP_MDIO_IO             {EMIO} \
  CONFIG.PCW_ENET0_PERIPHERAL_FREQMHZ      {100 Mbps} \
  CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE         {1} \
  CONFIG.PCW_GPIO_EMIO_GPIO_IO             {EMIO} \
  CONFIG.PCW_GPIO_EMIO_GPIO_WIDTH          {2} \
  CONFIG.PCW_UIPARAM_DDR_PARTNO            {MT41K128M16 JT-125} \
  CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH         {16 Bit} \
  CONFIG.PCW_UIPARAM_DDR_ECC               {Disabled} \
  CONFIG.PCW_UIPARAM_ACT_DDR_FREQ_MHZ      {533.333374} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ      {40} \
  CONFIG.PCW_TTC0_PERIPHERAL_ENABLE        {1} \
] $ps7

# --- Ethernet: raw MII pins (not the bundled 8-bit GMII interface) ---
# Board only wires 4-bit MII (10/100). get_bd_pins does not support bit-range
# addressing on a bus pin (confirmed by trial: "No pins matched ...[3:0]"),
# so bit splitting/joining goes through xlslice/xlconcat cells instead,
# connected via whole-pin nets.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant xlconst_rxd_hi
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] [get_bd_cells xlconst_rxd_hi]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat xlconcat_rxd
set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {4} CONFIG.IN1_WIDTH {4}] [get_bd_cells xlconcat_rxd]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice xlslice_txd
set_property -dict [list CONFIG.DIN_WIDTH {8} CONFIG.DIN_FROM {3} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {4}] [get_bd_cells xlslice_txd]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant xlconst_eth_misc
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells xlconst_eth_misc]

create_bd_port -dir I eth_rx_clk
create_bd_port -dir I -from 3 -to 0 eth_rxd
create_bd_port -dir I eth_rx_dv
create_bd_port -dir I eth_tx_clk
create_bd_port -dir O eth_tx_en
create_bd_port -dir O -from 3 -to 0 eth_txd

connect_bd_net [get_bd_ports eth_rx_clk]              [get_bd_pins ps7_0/ENET0_GMII_RX_CLK]
connect_bd_net [get_bd_ports eth_rxd]                 [get_bd_pins xlconcat_rxd/In0]
connect_bd_net [get_bd_pins xlconst_rxd_hi/dout]      [get_bd_pins xlconcat_rxd/In1]
connect_bd_net [get_bd_pins xlconcat_rxd/dout]        [get_bd_pins ps7_0/ENET0_GMII_RXD]
connect_bd_net [get_bd_ports eth_rx_dv]               [get_bd_pins ps7_0/ENET0_GMII_RX_DV]
connect_bd_net [get_bd_ports eth_tx_clk]              [get_bd_pins ps7_0/ENET0_GMII_TX_CLK]
connect_bd_net [get_bd_ports eth_tx_en]               [get_bd_pins ps7_0/ENET0_GMII_TX_EN]
connect_bd_net [get_bd_pins ps7_0/ENET0_GMII_TXD]     [get_bd_pins xlslice_txd/Din]
connect_bd_net [get_bd_pins xlslice_txd/Dout]         [get_bd_ports eth_txd]
connect_bd_net [get_bd_pins xlconst_eth_misc/dout] [list \
  [get_bd_pins ps7_0/ENET0_GMII_COL] \
  [get_bd_pins ps7_0/ENET0_GMII_CRS] \
  [get_bd_pins ps7_0/ENET0_GMII_RX_ER] \
]
# ENET0_GMII_TX_ER is a PS7 output with nothing to drive on this board —
# left unconnected, which is valid for BD outputs.

# MDIO is a proper tri-state interface pin on the PS7 IP (I/O/T bundle) —
# use the bundled interface so Vivado inserts the IOBUF, instead of wiring
# ENET0_MDIO_I/O/T by hand.
# Match on the pin's own string form (confirmed by direct probe to be
# "/ps7_0/MDIO_ETHERNET_0") rather than get_property/return-value chaining,
# both of which produced "Invalid option value ''" when tried.
set mdio_pin {}
foreach ip [get_bd_intf_pins -of_objects [get_bd_cells ps7_0]] {
  if {[string match "*MDIO_ETHERNET_0" $ip]} { set mdio_pin $ip }
}
if {$mdio_pin eq {}} { error "MDIO_ETHERNET_0 interface pin not found on ps7_0" }
make_bd_intf_pins_external $mdio_pin

set mdio_port {}
foreach p [get_bd_intf_ports] {
  if {[string match "*MDIO_ETHERNET_0*" $p]} { set mdio_port $p }
}
if {$mdio_port eq {}} { error "externalized MDIO port not found" }
set_property name eth_mdio $mdio_port

# --- Board LEDs on EMIO GPIO[1:0] (output only) ---
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice xlslice_led_o
set_property -dict [list CONFIG.DIN_WIDTH {64} CONFIG.DIN_FROM {1} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {2}] [get_bd_cells xlslice_led_o]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant xlconst_gpio_i
set_property -dict [list CONFIG.CONST_WIDTH {64} CONFIG.CONST_VAL {0}] [get_bd_cells xlconst_gpio_i]
create_bd_port -dir O -from 1 -to 0 led
connect_bd_net [get_bd_pins ps7_0/GPIO_O]         [get_bd_pins xlslice_led_o/Din]
connect_bd_net [get_bd_pins xlslice_led_o/Dout]   [get_bd_ports led]
connect_bd_net [get_bd_pins xlconst_gpio_i/dout]  [get_bd_pins ps7_0/GPIO_I]
# GPIO_T (tri-state control PS7 would drive to an IOBUF) is left
# unconnected — LEDs here are wired as plain push-pull outputs, no IOBUF.

# --- stereo_depth_top: dual-OV7670 capture + SSD disparity engine ---
# See hw/ip/stereo_depth/stereo_depth_top.vhd for the full design and its
# deviations from the Basys3 reference it was ported from.
foreach f {i2c_sender.vhd ov7670_registers.vhd ov7670_controller.vhd \
           ov7670_capture.vhd dpram.vhd image_rectification.vhd \
           cam_activity.vhd capture_probe.vhd preview_buffer.vhd disparity_generator.vhd stereo_depth_top.vhd} {
  add_files -norecurse [file join $repo_root hw ip stereo_depth $f]
}
update_compile_order -fileset sources_1

set depth [create_bd_cell -type module -reference stereo_depth_top depth_0]

connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins depth_0/clk50]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins depth_0/axi_clk]

foreach {pin dir} {
  cam_pclk I cam_xclk O cam_vsync I cam_href I cam_sioc O cam_siod IO cam_pwdn O cam_reset_n O
  cam2_pclk I cam2_xclk O cam2_vsync I cam2_href I cam2_sioc O cam2_siod IO cam2_pwdn O cam2_reset_n O
} {
  create_bd_port -dir $dir $pin
  connect_bd_net [get_bd_pins depth_0/$pin] [get_bd_ports $pin]
}
create_bd_port -dir I -from 7 -to 0 cam_pdata
create_bd_port -dir I -from 7 -to 0 cam2_pdata
connect_bd_net [get_bd_ports cam_pdata]  [get_bd_pins depth_0/cam_pdata]
connect_bd_net [get_bd_ports cam2_pdata] [get_bd_pins depth_0/cam2_pdata]

# --- AXI reset network (shared by the interconnect and both AXI peripherals) ---
set rst_gen [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ps7_0_50M]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0]     [get_bd_pins rst_ps7_0_50M/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_ps7_0_50M/ext_reset_in]

# --- AXI interconnect: M_AXI_GP0 fans out to the GPIO control block and the
# disparity-frame BRAM controller ---
set axi_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_interconnect_0]
set_property -dict [list CONFIG.NUM_MI {6}] $axi_ic
# M_AXI_GP0_ACLK is an INPUT on ps7_0 (Zynq's AXI GP ports are
# software-clock-configurable -- you tell the PS what clock to use, it's
# not a clock source of its own) -- drive it from FCLK_CLK0, same as
# everything else, then fan that out to the interconnect/peripherals.
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins ps7_0/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/S00_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/M00_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/M01_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/M02_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/M03_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/M04_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/M05_ACLK]
connect_bd_net [get_bd_pins rst_ps7_0_50M/interconnect_aresetn] [get_bd_pins axi_interconnect_0/ARESETN]
connect_bd_net [get_bd_pins rst_ps7_0_50M/peripheral_aresetn] [list \
  [get_bd_pins axi_interconnect_0/S00_ARESETN] \
  [get_bd_pins axi_interconnect_0/M00_ARESETN] \
  [get_bd_pins axi_interconnect_0/M01_ARESETN] \
  [get_bd_pins axi_interconnect_0/M02_ARESETN] \
  [get_bd_pins axi_interconnect_0/M03_ARESETN] \
  [get_bd_pins axi_interconnect_0/M04_ARESETN] \
  [get_bd_pins axi_interconnect_0/M05_ARESETN] \
]
connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0] [get_bd_intf_pins axi_interconnect_0/S00_AXI]

# --- AXI GPIO: control (PS writes, PL reads) + status (PL writes, PS reads) ---
set axi_gpio_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_ctrl]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH    {20} \
  CONFIG.C_ALL_OUTPUTS    {1} \
  CONFIG.C_IS_DUAL        {1} \
  CONFIG.C_GPIO2_WIDTH    {5} \
  CONFIG.C_ALL_INPUTS_2   {1} \
] $axi_gpio_ctrl
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_gpio_ctrl/s_axi_aclk]
connect_bd_net [get_bd_pins rst_ps7_0_50M/peripheral_aresetn] [get_bd_pins axi_gpio_ctrl/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] [get_bd_intf_pins axi_gpio_ctrl/S_AXI]

# control channel bit layout:
#   [0]=resend [4:1]=row_offset [12:5]=col_offset
#   [13]=ps_sccb_en [15:14]=ps_sioc [17:16]=ps_siod_o [19:18]=ps_siod_oe
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice xlslice_resend
set_property -dict [list CONFIG.DIN_WIDTH {20} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {1}] [get_bd_cells xlslice_resend]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice xlslice_row_offset
set_property -dict [list CONFIG.DIN_WIDTH {20} CONFIG.DIN_FROM {4} CONFIG.DIN_TO {1} CONFIG.DOUT_WIDTH {4}] [get_bd_cells xlslice_row_offset]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice xlslice_col_offset
set_property -dict [list CONFIG.DIN_WIDTH {20} CONFIG.DIN_FROM {12} CONFIG.DIN_TO {5} CONFIG.DOUT_WIDTH {8}] [get_bd_cells xlslice_col_offset]
foreach s {xlslice_resend xlslice_row_offset xlslice_col_offset} {
  connect_bd_net [get_bd_pins axi_gpio_ctrl/gpio_io_o] [get_bd_pins $s/Din]
}
connect_bd_net [get_bd_pins xlslice_resend/Dout]     [get_bd_pins depth_0/resend]
connect_bd_net [get_bd_pins xlslice_row_offset/Dout] [get_bd_pins depth_0/row_offset]
connect_bd_net [get_bd_pins xlslice_col_offset/Dout] [get_bd_pins depth_0/col_offset]

# PS-driven SCCB override lines
foreach {nm frm to w tgt} {
  sccb_en   13 13 1 ps_sccb_en
  sccb_sioc 15 14 2 ps_sioc
  sccb_sdo  17 16 2 ps_siod_o
  sccb_sdoe 19 18 2 ps_siod_oe
} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice xlslice_$nm
  set_property -dict [list CONFIG.DIN_WIDTH {20} CONFIG.DIN_FROM $frm CONFIG.DIN_TO $to CONFIG.DOUT_WIDTH $w] [get_bd_cells xlslice_$nm]
  connect_bd_net [get_bd_pins axi_gpio_ctrl/gpio_io_o] [get_bd_pins xlslice_$nm/Din]
  connect_bd_net [get_bd_pins xlslice_$nm/Dout] [get_bd_pins depth_0/$tgt]
}

# status channel bit layout: [0]=cam1_config_ok [1]=cam2_config_ok [2]=frame_done
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat xlconcat_status
set_property -dict [list CONFIG.NUM_PORTS {4} CONFIG.IN0_WIDTH {1} CONFIG.IN1_WIDTH {1} CONFIG.IN2_WIDTH {1} CONFIG.IN3_WIDTH {2}] [get_bd_cells xlconcat_status]
connect_bd_net [get_bd_pins depth_0/cam1_config_ok] [get_bd_pins xlconcat_status/In0]
connect_bd_net [get_bd_pins depth_0/cam2_config_ok] [get_bd_pins xlconcat_status/In1]
connect_bd_net [get_bd_pins depth_0/frame_done_toggle] [get_bd_pins xlconcat_status/In2]
connect_bd_net [get_bd_pins depth_0/ps_siod_i]      [get_bd_pins xlconcat_status/In3]
connect_bd_net [get_bd_pins xlconcat_status/dout]   [get_bd_pins axi_gpio_ctrl/gpio2_io_i]

# --- AXI GPIO: per-camera pixel-path activity counters (diagnostic) ---
# Answers "is PCLK/VSYNC/HREF/data actually arriving from each camera"
# without an ILA (license-blocked here). See hw/ip/stereo_depth/cam_activity.vhd
# for the bit layout. Read-only from the PS; nothing depends on it.
set axi_gpio_diag [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_diag]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH    {32} \
  CONFIG.C_ALL_INPUTS     {1} \
  CONFIG.C_IS_DUAL        {1} \
  CONFIG.C_GPIO2_WIDTH   {32} \
  CONFIG.C_ALL_INPUTS_2   {1} \
] $axi_gpio_diag
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_gpio_diag/s_axi_aclk]
connect_bd_net [get_bd_pins rst_ps7_0_50M/peripheral_aresetn] [get_bd_pins axi_gpio_diag/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M02_AXI] [get_bd_intf_pins axi_gpio_diag/S_AXI]
connect_bd_net [get_bd_pins depth_0/cam1_activity] [get_bd_pins axi_gpio_diag/gpio_io_i]
connect_bd_net [get_bd_pins depth_0/cam2_activity] [get_bd_pins axi_gpio_diag/gpio2_io_i]

# --- AXI GPIO: capture-stage probes (see capture_probe.vhd) ---
# One level deeper than axi_gpio_diag: tells whether ov7670_capture actually
# latches data into the frame buffers, which the disparity output alone
# cannot distinguish from a dead camera.
set axi_gpio_cap [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_cap]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH    {32} \
  CONFIG.C_ALL_INPUTS     {1} \
  CONFIG.C_IS_DUAL        {1} \
  CONFIG.C_GPIO2_WIDTH   {32} \
  CONFIG.C_ALL_INPUTS_2   {1} \
] $axi_gpio_cap
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_gpio_cap/s_axi_aclk]
connect_bd_net [get_bd_pins rst_ps7_0_50M/peripheral_aresetn] [get_bd_pins axi_gpio_cap/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M03_AXI] [get_bd_intf_pins axi_gpio_cap/S_AXI]
connect_bd_net [get_bd_pins depth_0/cap_we_counts]  [get_bd_pins axi_gpio_cap/gpio_io_i]
connect_bd_net [get_bd_pins depth_0/cap_wdata_info] [get_bd_pins axi_gpio_cap/gpio2_io_i]

# --- AXI BRAM Controller: PS-side random-access window onto the finished
# disparity frame, wired to stereo_depth_top's native BRAM port directly
# (no Block Memory Generator involved -- see dpram.vhd). DATA_WIDTH=32 is
# this IP's minimum -- it doesn't accept 8 (empirically confirmed: "Value
# '8' is out of range... Valid values are - 32, 64, 128, 256, 512, 1024") --
# so the disparity frame is packed 4 pixels/word on the PL side (see
# stereo_depth_top.vhd's disp_byte_we/disp_word_addr).
set axi_bram_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl axi_bram_ctrl_disp]
set_property -dict [list \
  CONFIG.SINGLE_PORT_BRAM {1} \
  CONFIG.DATA_WIDTH       {32} \
  CONFIG.ECC_TYPE         {0} \
] $axi_bram_ctrl
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_bram_ctrl_disp/s_axi_aclk]
connect_bd_net [get_bd_pins rst_ps7_0_50M/peripheral_aresetn] [get_bd_pins axi_bram_ctrl_disp/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M01_AXI] [get_bd_intf_pins axi_bram_ctrl_disp/S_AXI]

# bram_addr_a is a 17-bit BYTE address (matches the 128K range assigned
# below); word-select is bits [16:2] (2 LSBs always zero for 4-byte-aligned
# AXI transactions) -- confirmed empirically (get_property LEFT/RIGHT on a
# standalone instance of this IP), not assumed.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice xlslice_disp_addr
set_property -dict [list CONFIG.DIN_WIDTH {17} CONFIG.DIN_FROM {16} CONFIG.DIN_TO {2} CONFIG.DOUT_WIDTH {15}] [get_bd_cells xlslice_disp_addr]
connect_bd_net [get_bd_pins axi_bram_ctrl_disp/bram_addr_a] [get_bd_pins xlslice_disp_addr/Din]
connect_bd_net [get_bd_pins xlslice_disp_addr/Dout]         [get_bd_pins depth_0/axi_addrb]

connect_bd_net [get_bd_pins axi_bram_ctrl_disp/bram_we_a]     [get_bd_pins depth_0/axi_web]
connect_bd_net [get_bd_pins axi_bram_ctrl_disp/bram_wrdata_a] [get_bd_pins depth_0/axi_dinb]
connect_bd_net [get_bd_pins axi_bram_ctrl_disp/bram_rddata_a] [get_bd_pins depth_0/axi_doutb]

# --- Raw-camera preview windows ---
# Same 32-bit-minimum constraint as the disparity controller; each window is
# 16KB (4096 words), enough for 32768 packed 4-bit pixels.
foreach {idx mi} {1 M04 2 M05} {
  set c [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl axi_bram_ctrl_prev$idx]
  set_property -dict [list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.DATA_WIDTH {32} CONFIG.ECC_TYPE {0}] $c
  connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_bram_ctrl_prev$idx/s_axi_aclk]
  connect_bd_net [get_bd_pins rst_ps7_0_50M/peripheral_aresetn] [get_bd_pins axi_bram_ctrl_prev$idx/s_axi_aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/${mi}_AXI] [get_bd_intf_pins axi_bram_ctrl_prev$idx/S_AXI]

  # bram_addr_a is a byte address; the buffer is word-addressed, so drop the
  # two always-zero LSBs (same slice trick as the disparity window).
  create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice xlslice_prev${idx}_addr
  set_property -dict [list CONFIG.DIN_WIDTH {14} CONFIG.DIN_FROM {13} CONFIG.DIN_TO {2} CONFIG.DOUT_WIDTH {12}] [get_bd_cells xlslice_prev${idx}_addr]
  connect_bd_net [get_bd_pins axi_bram_ctrl_prev$idx/bram_addr_a] [get_bd_pins xlslice_prev${idx}_addr/Din]
  connect_bd_net [get_bd_pins xlslice_prev${idx}_addr/Dout] [get_bd_pins depth_0/prev${idx}_addrb]

  connect_bd_net [get_bd_pins axi_bram_ctrl_prev$idx/bram_we_a]     [get_bd_pins depth_0/prev${idx}_web]
  connect_bd_net [get_bd_pins axi_bram_ctrl_prev$idx/bram_wrdata_a] [get_bd_pins depth_0/prev${idx}_dinb]
  connect_bd_net [get_bd_pins axi_bram_ctrl_prev$idx/bram_rddata_a] [get_bd_pins depth_0/prev${idx}_doutb]
}

# --- Address map: both AXI peripherals need an explicit assigned range,
# not just an interface connection, or the PS can't reach them ---
assign_bd_address -offset 0x41200000 -range 4K   [get_bd_addr_segs {axi_gpio_ctrl/S_AXI/Reg}]
assign_bd_address -offset 0x41210000 -range 4K   [get_bd_addr_segs {axi_gpio_diag/S_AXI/Reg}]
assign_bd_address -offset 0x41220000 -range 4K   [get_bd_addr_segs {axi_gpio_cap/S_AXI/Reg}]
assign_bd_address -offset 0x40100000 -range 16K  [get_bd_addr_segs {axi_bram_ctrl_prev1/S_AXI/Mem0}]
assign_bd_address -offset 0x40110000 -range 16K  [get_bd_addr_segs {axi_bram_ctrl_prev2/S_AXI/Mem0}]
assign_bd_address -offset 0x40000000 -range 128K [get_bd_addr_segs {axi_bram_ctrl_disp/S_AXI/Mem0}]

validate_bd_design
save_bd_design

make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file join $proj_dir stereo_cam_hw.gen sources_1 bd system hdl system_wrapper.v]
set_property top system_wrapper [current_fileset]

add_files -fileset constrs_1 -norecurse [file join $repo_root hw constraints ethernet.xdc]
add_files -fileset constrs_1 -norecurse [file join $repo_root hw constraints camera.xdc]

# Implementation-only: names clk_fpga_0, which the PS7 IP creates in its own
# generated .xdc and which is not in scope during synthesis. See that file's
# header for why it cannot simply live in camera.xdc.
set camera_timing_xdc [file join $repo_root hw constraints camera_timing.xdc]
add_files -fileset constrs_1 -norecurse $camera_timing_xdc
set_property USED_IN_SYNTHESIS false [get_files $camera_timing_xdc]

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

open_run impl_1
write_hw_platform -fixed -include_bit -force [file join $proj_dir stereo_cam.xsa]

puts "BUILD_OK: bitstream + xsa written to $proj_dir"

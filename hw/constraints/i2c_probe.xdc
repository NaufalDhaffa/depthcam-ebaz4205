# Pin constraints for hw/scripts/build_bd_i2c_probe.tcl (standalone SCCB
# liveness probe, not part of the main stereo_cam build). Only the 5 control
# signals per camera needed for an SCCB-only test (XCLK, SIOC, SIOD, PWDN,
# RESET#) -- PCLK/HREF/VSYNC/D[7:0] are not wired since image capture isn't
# exercised by this probe. Pin numbers per the camera header table already
# derived for the full stereo_cam project (cam1 = DATA1/DATA2, Bank 35;
# cam2 = DATA3/DATA2, Bank 34).

## Camera 1 (DATA1 header, + DATA2 for reset/pwdn)
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS33} [get_ports {cam_sioc}]
set_property -dict {PACKAGE_PIN B19 IOSTANDARD LVCMOS33} [get_ports {cam_siod}]
set_property PULLUP TRUE [get_ports {cam_siod}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {cam_xclk}]
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33} [get_ports {cam_reset_n}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports {cam_pwdn}]

## Camera 2 (DATA3 header, + DATA2 for reset/pwdn)
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} [get_ports {cam2_sioc}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {cam2_siod}]
set_property PULLUP TRUE [get_ports {cam2_siod}]
set_property -dict {PACKAGE_PIN P20 IOSTANDARD LVCMOS33} [get_ports {cam2_xclk}]
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33} [get_ports {cam2_reset_n}]
set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33} [get_ports {cam2_pwdn}]

## Board LEDs -- led[0]=green(W13)=cam1 result, led[1]=red(W14)=cam2 result
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]

#!/usr/bin/env bash
# Program the PL and start the depth-stream application over JTAG.
#
# Requires hw_server to already be running. Start it in a real interactive
# terminal, not from a script -- backgrounded instances have repeatedly died
# seconds after startup on this setup:
#     source /home/naufal/Xilinx/2026.1/Vivado/settings64.sh && hw_server
set -euo pipefail

XILINX=${XILINX:-/home/naufal/Xilinx/2026.1}
XSDB="$XILINX/Vivado/bin/xsdb"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

BIT="$REPO/hw/build/stereo_cam_hw.runs/impl_1/system_wrapper.bit"
ELF="$REPO/sw/workspace/build/depth_stream_app.elf"
PS7="$REPO/sw/dts/ps7_init.tcl"

for f in "$BIT" "$ELF" "$PS7"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

if ! ss -ltn 2>/dev/null | grep -q 3121; then
    echo "hw_server is not listening on 3121 -- start it first (see header)" >&2
    exit 1
fi

echo "== 1/2 programming PL =="
# The core is halted BEFORE reprogramming on purpose. If the application is
# still running and touching AXI peripherals in the PL, pulling the PL out
# from under it leaves the interconnect hung, which shows up as
# "DAP (APB AP transaction error)" on the next ps7_init and needs a physical
# power cycle to clear.
"$XSDB" -eval "
connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ \"ARM*#0\"}
stop
fpga -file $BIT
puts PROGRAMMED
"

sleep 2

# Separate xsdb invocation on purpose: combining bitstream programming and
# ps7_init in one session has broken Ethernet on this board before.
echo "== 2/2 init PS + run application =="
"$XSDB" -eval "
connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ \"ARM*#0\"}
rst -processor
source $PS7
ps7_init
ps7_post_config
dow $ELF
con
puts APP_RUNNING
"

echo "== waiting for the board to come up on the network =="
for i in $(seq 1 15); do
    if ping -c1 -W1 192.168.2.10 >/dev/null 2>&1; then
        echo "board is up at 192.168.2.10"
        echo
        echo "now run:  .venv-litex/bin/python sw/tools/depth_tuner.py"
        exit 0
    fi
    sleep 1
done

echo "board did not answer ping. Check the UART console:" >&2
echo "  stty -F /dev/ttyUSB0 115200 raw -echo && cat /dev/ttyUSB0" >&2
exit 1

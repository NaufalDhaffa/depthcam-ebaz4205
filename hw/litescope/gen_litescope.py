#!/usr/bin/env python3
"""Generate a standalone LiteScope logic-analyzer core for the EBAZ4205
stereo camera design.

Why LiteScope and not Vivado's ILA: system_ila is license-blocked on this
install (Chipscope 16-620 "not covered by license"), so the vendor logic
analyzer simply cannot be built here. LiteScope is the open-source
equivalent and has no such restriction.

Transport is JTAGBone: the core talks to the host over the FPGA's own
BSCANE2 user-JTAG primitive, so it needs no extra pins, no AXI plumbing,
and no software on the ARM. The tradeoff is that it drives the JTAG cable
through openocd, which cannot share the cable with Xilinx's hw_server --
stop hw_server before running litex_server (see hw/litescope/README.md).

Output is plain Verilog plus an analyzer.csv describing the probe layout;
both are consumed by the normal Vivado flow (added as a source in
hw/scripts/build_bd.tcl) and by litescope_cli respectively.

Run with the project venv:
    .venv-litex/bin/python hw/litescope/gen_litescope.py
"""
from migen import *

from litex.build.generic_platform import Pins, IOStandard
from litex.build.xilinx import XilinxPlatform
from litex.soc.integration.soc_core import SoCMini
from litex.soc.integration.builder import Builder
from litescope import LiteScopeAnalyzer

# Capture depth, in samples per probe group. 4096 at PCLK (~20MHz) is about
# 200us -- comfortably longer than one OV7670 line (~800 PCLKs) so a
# triggered capture can show several HREF pulses in context, while staying
# small enough to leave the disparity engine's BRAM budget alone.
CAPTURE_DEPTH = 4096

# Placeholder pin assignments: this core is instantiated inside the Vivado
# block design (its ports are wired to internal signals there), so it never
# owns real package pins of its own. LiteX still wants an io list, so these
# are dummies and no constraint file from here is used.
_io = [
    ("sys_clk",    0, Pins(1)),
    ("sys_rst",    0, Pins(1)),

    ("cam_pclk",   0, Pins(1)),
    ("cam_vsync",  0, Pins(1)),
    ("cam_href",   0, Pins(1)),
    ("cam_pdata",  0, Pins(8)),

    ("cam2_pclk",  0, Pins(1)),
    ("cam2_vsync", 0, Pins(1)),
    ("cam2_href",  0, Pins(1)),
    ("cam2_pdata", 0, Pins(8)),
]


class Platform(XilinxPlatform):
    default_clk_name   = "sys_clk"
    default_clk_period = 1e9 / 40e6  # FCLK0 = 40MHz, see build_bd.tcl

    def __init__(self):
        XilinxPlatform.__init__(self, "xc7z010-clg400-1", _io, toolchain="vivado")


class LiteScopeCore(SoCMini):
    def __init__(self, platform, sys_clk_freq=40e6):
        # No CPU, no ROM/RAM, no CSR UART: this SoC exists only to carry the
        # analyzer and the JTAG bridge that configures it.
        SoCMini.__init__(self, platform, sys_clk_freq,
            ident         = "EBAZ4205 stereo-camera LiteScope",
            with_uart     = False,
            with_timer    = False,
            with_ctrl     = False,
        )

        # sys domain, driven from the block design's FCLK0.
        self.cd_sys = ClockDomain("sys")
        self.comb += [
            self.cd_sys.clk.eq(platform.request("sys_clk")),
            self.cd_sys.rst.eq(platform.request("sys_rst")),
        ]

        # Camera 1 pixel clock is its own domain -- the camera supplies it,
        # free-running against everything else on the board.
        cam_pclk = platform.request("cam_pclk")
        self.cd_pclk = ClockDomain("pclk")
        self.comb += self.cd_pclk.clk.eq(cam_pclk)

        # Bridge: host <-> CSR over user-JTAG (BSCANE2). No pins needed.
        self.add_jtagbone()

        cam_vsync  = platform.request("cam_vsync")
        cam_href   = platform.request("cam_href")
        cam_pdata  = platform.request("cam_pdata")
        cam2_pclk  = platform.request("cam2_pclk")
        cam2_vsync = platform.request("cam2_vsync")
        cam2_href  = platform.request("cam2_href")
        cam2_pdata = platform.request("cam2_pdata")

        # Camera 2's signals are sampled in camera 1's PCLK domain. That is
        # deliberate: the point of capturing both together is to compare
        # their framing (is cam2 producing HREF/VSYNC at all, do the two
        # agree), which needs one common timebase. The two PCLKs are
        # genuinely asynchronous, so cam2's samples are only trustworthy at
        # the framing level (VSYNC/HREF envelopes), not bit-exact per pixel.
        analyzer_signals = [
            cam_vsync, cam_href, cam_pdata,
            cam2_pclk, cam2_vsync, cam2_href, cam2_pdata,
        ]

        self.analyzer = LiteScopeAnalyzer(
            analyzer_signals,
            depth        = CAPTURE_DEPTH,
            clock_domain = "pclk",
            samplerate   = 20e6,   # PCLK, see camera.xdc
            # Probe layout descriptor -- litescope_cli reads this to know
            # what the captured bits mean. Must be kept in sync with the
            # bitstream actually loaded on the board.
            csr_csv      = "hw/litescope/build/analyzer.csv",
        )


def main():
    platform = Platform()
    soc      = LiteScopeCore(platform)
    builder  = Builder(soc,
        output_dir       = "hw/litescope/build",
        compile_gateware = False,   # emit Verilog only; Vivado builds it
        compile_software = False,
        csr_csv          = "hw/litescope/build/csr.csv",
    )
    builder.build(build_name="litescope_core", run=False)


if __name__ == "__main__":
    main()

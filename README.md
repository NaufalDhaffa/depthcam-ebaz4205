# depthcam-ebaz4205

Real-time stereo depth camera on a **$20 EBAZ4205** (Zynq-7010) mining board:
two OV7670 cameras, SSD block-matching disparity computed in the FPGA fabric,
streamed to a PC over Ethernet with a live tuning GUI.

Ported from [Archfx/FPGA-DepthMap-Basys3](https://github.com/Archfx/FPGA-DepthMap-Basys3)
(Aruna Jayasena's RTL disparity generator), which targets a Basys3 with VGA
output and five tuning pushbuttons. The EBAZ4205 has neither, and has a very
different resource balance — so this is a port with real redesign in it, not a
recompile.

---

## Why this board

The EBAZ4205 is a discarded Bitcoin-miner control board. It costs ~$20 and
carries a Zynq **XC7Z010-1CLG400**: dual Cortex-A9 @ 667 MHz plus ~28K logic
cells of Artix-7-class fabric, with 256 MB DDR3, 100 Mbps Ethernet and microSD
already on board.

That combination is what makes it a better fit for this project than the
Basys3 it was ported from, despite the Basys3 being ~5× the price:

| | EBAZ4205 (XC7Z010) | Basys3 (XC7A35T) |
|---|---|---|
| Logic cells | ~28K | 33K |
| Block RAM | 60 blocks (~2.1 Mb) | 50 blocks (1.8 Mb) |
| **Distributed RAM** | **6000 cells** | **9600 cells** |
| Hard CPU | **dual Cortex-A9** | none |
| DRAM | **256 MB DDR3** | none |
| Ethernet | **100 Mbps PHY** | none |
| Ready-made I/O | JTAG/UART pads only | USB-JTAG, VGA, switches, LEDs |

The CPU and Ethernet are why the depth map can be streamed and tuned live at
all. The **distributed-RAM deficit is why the resolution had to drop** — see
below.

---

## Method

### Signal path

```
OV7670 #1 ──┐  8-bit DVP          ┌─ preview_buffer 1 ──┐
            ├─ ov7670_capture ────┤                     │  AXI
OV7670 #2 ──┘  (decimate + 4-bit) ├─ frame_buffer L/R ──┤  BRAM
                                  └─ preview_buffer 2 ──┘  controllers
                                          │                     │
                                  disparity_generator           │
                                  (SSD block matching)          │
                                          │                     │
                                   disparity_ram ───────────────┤
                                                                │
                                        ┌───────────────────────┴──┐
                                        │  Cortex-A9 (bare metal)  │
                                        │  lwIP raw API            │
                                        └───────────┬──────────────┘
                                                    │ UDP
                                        ┌───────────┴──────────────┐
                                        │  PC: depth_tuner.py GUI  │
                                        └──────────────────────────┘
```

### Capture

Each OV7670 is clocked from the FPGA (XCLK = FCLK0/2 = 20 MHz) and free-runs,
returning its own PCLK with 8-bit YUV422 data. `ov7670_capture` samples in the
camera's own PCLK domain — a genuinely separate clock domain per camera,
declared asynchronous in `camera_timing.xdc` — and decimates VGA down to
**160×120** by subsampling every 4th pixel and every 4th line, keeping only
the **top 4 bits of luma**.

4 bits per pixel is not a corner cut for its own sake: the disparity engine's
working set is the binding constraint, and 4-bit luma is what the original
design matched on too.

### Disparity: SSD block matching

For every pixel, the engine slides an ~8-tap (near-3×3) window across the
right image over disparities **1…60** and picks the offset minimising the sum
of squared differences:

<p align="center"><code>D(x,y) = argmin<sub>d</sub> Σ |I<sub>L</sub>(x+i, y+j) − I<sub>R</sub>(x−d+i, y+j)|²</code></p>

The search is sequential (one offset per clock), so a pixel costs ~60 cycles.
Rows are processed in **bands of 8**, cached in distributed RAM, because a
whole frame pair does not fit.

### The resolution decision

The reference runs 320×240. This port runs **160×120**, and the reason is
specific: `org_L`/`org_R`, the row-band caches, live in **distributed RAM**,
and XC7Z010 has 6000 cells where the Basys3's XC7A35T has 9600. At the
original sizing the design needs 6840 — confirmed by `place_design` DRC
(`UTLZ-1`), not estimated:

```
ERROR: [DRC UTLZ-1] LUT as Distributed RAM over-utilized ...
requires 6840 of such cell types but only 6000 ... are available
```

Having *more* block RAM than the Basys3 does not help, because this array is
LUTRAM-bound. Dropping to 160×120 with 8-row bands keeps the band counter
within its existing 4-bit width — a parameter change, not a redesign.

### Clocking

`FCLK0` is **40 MHz**, not the 50 MHz the reference used. At 50 MHz the 8-tap
combinational SSD path missed timing by ~1.7 ns (`route_design`, measured).
40 MHz closes with **WNS +0.746 ns / WHS +0.025 ns**.

One clock drives the disparity engine, the AXI interconnect and (divided by 2)
the camera XCLK. The two camera PCLKs are separate asynchronous domains.

### Getting the data out

The Basys3 design scanned the disparity RAM out to VGA. This board has no VGA,
so the same port is handed to an **AXI BRAM controller** and read by the ARM
core, which packetises it over **UDP**.

Raw camera previews needed their own buffers: the real frame buffers have both
ports occupied (camera writes on A, disparity engine reads on B), and a
dual-port BRAM has no third port. Time-sharing port B would stall the engine
unpredictably, so `preview_buffer` taps the same capture stream into separate
RAM, **packed 8 pixels per 32-bit word** to fit the remaining BRAM budget.

### Replacing the pushbuttons

The reference used five buttons: one to re-send the camera register table, and
four to nudge stereo rectification offsets while watching the output. This
board has no user buttons, so both became registers reachable over UDP — and
the PS additionally gained a **bit-banged SCCB override**, so *any* camera
register can be read or written at run time without rebuilding the bitstream.

---

## Resource usage

Measured on the built design (`system_wrapper_utilization_placed.rpt`):

| Resource | Used | Available | % |
|---|---|---|---|
| Slice LUTs | 6710 | 17600 | 38% |
| — LUT as logic | 4105 | 17600 | 23% |
| — **LUT as memory** | **2605** | **6000** | **43%** |
| Slice registers | 5205 | 35200 | 15% |
| **Block RAM tile** | **48.5** | **60** | **81%** |
| DSP | 1 | 80 | 1% |

Timing: **WNS +0.746 ns**, WHS +0.025 ns, no violations.

---

## Repository layout

```
hw/
  ip/stereo_depth/     ported + new RTL (capture, SSD engine, buffers, probes)
  sources/             standalone SCCB liveness probe
  constraints/         pin and timing constraints
  scripts/             Vivado build scripts, deploy.sh
  litescope/           LiteScope core generator (ILA is licence-blocked here)
sw/
  apps/depth_stream/   bare-metal ARM app: UDP streaming + tuning server
  stm32_camtest/       standalone OV7670 tester for a Nucleo-F446RE
  tools/               host-side GUIs and capture scripts
docs/BOARD_CONFIG.md   board facts, derivations, and every gotcha hit
```

---

## Build and run

Requires Vivado/Vitis 2026.1 and a JTAG probe.

```bash
# 1. hardware (~6 min)
vivado -mode batch -source hw/scripts/build_bd.tcl

# 2. BSP + application
sdtgen -xsa hw/build/stereo_cam.xsa -dir sw/dts
empyro create_bsp -w sw/workspace -s sw/dts/system-top.dts -p ps7_cortexa9_0
empyro config_bsp -d sw/workspace -al lwip220
empyro create_app -w sw/workspace -n depth_stream_app -d sw/workspace -t lwip_echo_server
empyro build_app -w sw/workspace

# 3. deploy — hw_server must already be running in its own terminal
bash hw/scripts/deploy.sh

# 4. host GUI
.venv-litex/bin/python sw/tools/depth_tuner.py
```

Board is at `192.168.2.10`; the PC side of the point-to-point link is
`192.168.2.1/24`. Frames arrive on UDP **5001**, control is UDP **5002**.

See `docs/BOARD_CONFIG.md` for BSP configuration details — in particular the
lwIP settings this board needs, which differ from the template defaults.

---

## Host tools

| Tool | Purpose |
|---|---|
| `sw/tools/depth_tuner.py` | main GUI: both raw cameras + depth map, per-plane measurements, rectification, orientation, exposure, test pattern, save/load config |
| `sw/tools/depth_receiver.py` | headless receiver: `--stats`, `--save DIR` |
| `sw/tools/ov7670_capture.py` | drives the STM32 camera tester |
| `sw/tools/ov7670_gui.py` | live view for the STM32 tester |

### Distance from disparity

With a measured baseline **B = 36 mm**:

<p align="center"><code>Z = f · B / d</code></p>

`f` is the focal length **in pixels** and depends on the lens actually fitted,
so it must be calibrated — the GUI does this from one known distance.

---

## The STM32 side-quest

`sw/stm32_camtest/` is a standalone OV7670 tester for a Nucleo-F446RE, written
because *"is the camera working?"* and *"is the FPGA reading it correctly?"*
are different questions that look identical from a bad depth map.

It bit-bangs SCCB, reads the sensor ID, counts PCLK/HREF/VSYNC edges, and
streams live frames over the ST-LINK VCP — giving a **known-good reference**
for what the cameras actually produce.

One design note worth repeating: all camera inputs are **pulled down**. The
OV7670 drives them push-pull so a pull-down never fights a connected camera,
but a *disconnected* pin left floating picks up tens of kHz of ambient noise
and reports as "signal present". That false positive is exactly what a
diagnostic tool must never produce.

---

## Bugs found in the ported engine

Three of these are inherited from upstream and are still present there.
Full analysis in `docs/BOARD_CONFIG.md`.

1. **Cache array smaller than the range addressed.** `org_L`/`org_R` were
   declared `WIDTH*fetchBlock+1`, but the fill loop writes
   `WIDTH*fetchBlock+2*WIDTH` entries (two extra rows of window context) and
   the SSD reads to the same bound. Out of range on both sides, so the bottom
   rows of every band matched against undefined data.
2. **SSD window index could go negative.** The lowest index is
   `(row-1)*WIDTH + col-1-offset`, which underflows whenever `offset ≥ col` —
   routine, not rare, since `offset` sweeps 1…60 for every pixel. The garbage
   read still competed in the `ssd < prev_ssd` comparison and could win, i.e.
   be emitted as a real disparity.
3. **`dOUT` underflowed** when no valid offset won.
4. **Band count stopped matching frame height** after the resolution change —
   introduced by this port, fixed with an elaboration-time assertion.

---

## Current state

Working and measured on hardware:

- Link up at 100 Mbps, ping 0% loss @ ~0.12 ms
- Both cameras confirmed reaching the frame buffers (hardware activity probes)
- All three planes streaming; depth alone reached **33.5 fps**, 100% delivery
- Full run-time tuning over UDP

Not finished:

- **Preview tearing.** The PS reads buffers the cameras are still writing, so
  a readout splices strips from several frames. `preview_buffer.vhd` and
  `stereo_depth_top.vhd` contain the arm/ready snapshot FSMs to fix this, but
  they are **not yet wired up in `build_bd.tcl`** — the tree does not build
  until that is completed.
- **Match quality is poor.** The depth map is still dominated by one value.
  Prime suspect is `MVFP = 0x37` in the register table, which enables mirror:
  mirroring both cameras reverses which side a correspondence lies on, while
  the SSD engine only ever searches one direction. This is now toggleable at
  run time from the GUI.

---

## Credits

- [Archfx/FPGA-DepthMap-Basys3](https://github.com/Archfx/FPGA-DepthMap-Basys3) —
  Aruna Jayasena, *Register Transfer Level Disparity generator with Stereo
  Vision*, Journal of Open Research Software 9(1), 2021.
  [doi:10.5334/jors.339](https://doi.org/10.5334/jors.339)
- OV7670 SCCB controller and register tables originate with Mike Field
  (hamsterworks) via [laurivosandi/hdl](https://github.com/laurivosandi/hdl), MIT.
- Image tuning tables (gamma, AEC windowing) from
  [erikandre/stm32-ov7670](https://github.com/erikandre/stm32-ov7670) (Petr Machala).
- EBAZ4205 board documentation: [xjtuecho/EBAZ4205](https://github.com/xjtuecho/EBAZ4205),
  [mwalle's pinout gist](https://gist.github.com/mwalle/d8291e241075d82d1d420afa9302bd91).
- Base PS7 bring-up: [NaufalDhaffa/EBAZ4205](https://github.com/NaufalDhaffa/EBAZ4205).

## Licence

MIT, matching the upstream projects this builds on. See `LICENSE`.

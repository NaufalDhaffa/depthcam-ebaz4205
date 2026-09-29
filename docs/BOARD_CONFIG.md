# EBAZ4205 (Zynq XC7Z010CLG400) board config — stereo_cam project

Sources used to derive this (kept here so this research is never redone):
- PS7 `CONFIG.PCW_*` values: `nightseas/ebit_z7010`,
  `ebit_z7010.srcs/sources_1/bd/ebit_z7010_top/ebit_z7010_top.bd` (Vivado
  2018.3 block-design Tcl). That repo's `constrs_1` is empty — no `.xdc`
  shipped.
- LED pins + DATA1/2/3 header pin table: `xjtuecho/EBAZ4205`,
  `Development/EBAZ4205.xdc` (a commented-out template; no Ethernet/SD pins
  in it either).
- IP101GA PHY signal names: board schematic PDF,
  `nightseas/ebit_z7010/documents/ebaz4205_sch.pdf`. Flat PDF-to-text
  extraction preserved signal names (TXD0-3, RXD0-3, TXCLK, RXCLK, MDC,
  MDIO, COL, CRS, RXER, TXER, RESET.N) but lost which FPGA package ball each
  wire lands on — **do not re-derive Ethernet pins from that PDF alone**.
- Ethernet PL pin numbers below: supplied directly by the board owner
  (verified against physical board / prior measurement), not re-derived
  independently. Cross-checked as schematically plausible: U14/U15 are
  MRCC-capable pins (fits being external MII clock inputs); the other pins
  fall in the same I/O bank block as other confirmed board signals.

## PS7 configuration

| Peripheral | IO | Config |
|---|---|---|
| UART1 | MIO 24 (TX) / 25 (RX) | no modem control lines |
| SD0 | MIO 40-45 (clk/cmd/data0-3) | no CD/WP/POW pins |
| ENET0 | EMIO (MDIO also EMIO) | 100 Mbps MII |
| GPIO | MIO (misc) + EMIO x2 | EMIO[0]/[1] -> board LEDs |
| DDR3 | dedicated PS_DDR package pins, no user XDC | part `MT41K128M16 JT-125`, 16-bit bus, ECC disabled, `PCW_DDR_RAM_HIGHADDR=0x0FFFFFFF` (256 MB) |
| FCLK0 | 40 MHz | see "Stereo depth camera" section below — 50MHz (the original reference-design default) failed timing closure once the disparity engine was added |

Only Ethernet and the two LEDs need a project `.xdc` (`hw/constraints/ethernet.xdc`) —
everything else (UART1, SD0, DDR3) is on dedicated/MIO pins configured
entirely inside the PS7 IP, no top-level port constraints needed.

## Ethernet (IP101GA MII, via EMIO) pin map

| Signal | Zynq package pin | Note |
|---|---|---|
| eth_rx_clk | U14 | MRCC-capable, PHY-supplied 25 MHz |
| eth_rxd[0] | Y16 | |
| eth_rxd[1] | V16 | |
| eth_rxd[2] | V17 | |
| eth_rxd[3] | Y17 | |
| eth_rx_dv | W16 | |
| eth_tx_clk | U15 | MRCC-capable, PHY-supplied 25 MHz |
| eth_tx_en | W19 | |
| eth_txd[0] | W18 | |
| eth_txd[1] | Y18 | |
| eth_txd[2] | V18 | |
| eth_txd[3] | Y19 | |
| eth_mdio_mdc (MDC) | W15 | supplied by board owner |
| eth_mdio_mdio_io (MDIO) | Y14 | supplied by board owner |

## Board LEDs

| Signal | Pin | Color |
|---|---|---|
| led_green | W13 | green |
| led_red | W14 | red |

## Ethernet bring-up: confirmed working config

Board IP `192.168.2.10` / `255.255.255.0` / gw `192.168.2.1`, matching the
laptop's dedicated wired link (`eno1` statically configured at
`192.168.2.1/24`, no DHCP server on that link, kept separate from the
laptop's normal `wlo1`/internet connection). Verified end-to-end: link up at
100 Mbps, `ping` 0% loss ~0.1ms RTT, TCP echo (port 7) round-trips data
correctly.

Two lwIP BSP config fixes were required beyond the template default
(`sw/apps/eth_test`, lib `lwip220`), both set via
`empyro config_bsp -d sw/workspace -st lwip220 "<key>:<value>"`:
- `lwip220_temac_phy_link_speed:CONFIG_LINKSPEED100` — template default is
  `CONFIG_LINKSPEED_AUTODETECT`, which negotiated down to 10 Mbps on this
  board's PHY instead of the expected 100. Forcing 100 fixed it.
- `lwip220_dhcp:false` + `lwip220_lwip_dhcp_does_acd_check:false` — template
  default is DHCP-on with a "fall back to static IP after timeout" path, but
  on this point-to-point link (no DHCP server) that fallback never actually
  triggered in practice (the app hung waiting on `dhcp_timoutcntr`, which
  depends on a periodic DHCP timer callback this simple polling app doesn't
  service). Disabling DHCP entirely takes the immediate static-IP code path
  instead. Note: `LWIP_DHCP_DOES_ACD_CHECK`/`LWIP_ACD` must be turned off
  together with `LWIP_DHCP` — lwIP's own `init.c` has a `#error` guard if
  ACD-check is left on while DHCP is off.
- Static IP itself is set in `sw/apps/eth_test/src/main.c` (`IP4_ADDR` calls),
  not a BSP property — edit that directly if the IP/subnet ever needs to
  change.

## SD card bring-up: resolved (was physical card seating, not software)

`f_mount()` intermittently failed with `FR_NOT_READY` (`XSdPs_CardInitialize`
status 1). A driver-timing fix was tried first (a controlled two-path test
seemed to show a bare monolithic call failing while the same steps with a
delay between each succeeded), but a *bare, unpatched, unmodified* retry
also failed 3/3 times right after — disproving the timing theory. What
actually correlated with success/failure was the physical SD card being
removed and reinserted: after firmly reseating the card, the bare vendor
driver (no modifications at all) passed `f_mount`/`f_write`/read-back
3 attempts in a row, every time, with zero timing changes.

**Root cause: marginal physical contact in the SD slot, not a logic or
timing bug.** No driver patch is needed or present — `sw/workspace/libsrc/sdps/`
is the unmodified vendor driver. If `FR_NOT_READY` recurs, reseat the card
first before suspecting software; UART1/DDR3/Ethernet were all confirmed
solid throughout this investigation, and the SD MIO pins need no custom
constraints per the PS7 config table above, so pin mapping was never in
question either.

`sw/apps/sd_diag` is kept as a standalone low-level diagnostic (calls
`XSdPs_CfgInitialize`/`XSdPs_CardInitialize` directly, bypassing FatFs) for
any future SD issue — it isolates "did the raw driver call succeed" from
whatever FatFs/`disk_initialize()` layers on top.

## OV7670 camera SCCB liveness probe (2026-09-29): both cameras survived reverse-polarity incident

Both stereo cameras were briefly powered with reversed polarity during initial
wiring. No visible/smell damage afterward, but functional status was unknown.
Rather than risk the full capture pipeline on possibly-damaged hardware, a
standalone diagnostic was built first: `hw/sources/sccb_probe.vhd` (explicit
bit-bang SCCB FSM, not reusing the reference project's `i2c_sender.vhd` since
that module never samples ACK) reads each camera's PID register (`0x0A`,
expected `0x76`) in a retry loop and drives the result straight to the board
LEDs — no PS software involved. Built via a separate, throwaway Vivado
project (`hw/scripts/build_bd_i2c_probe.tcl` / `hw/constraints/i2c_probe.xdc`),
decoupled from the main `stereo_cam` design.

**Result: both LEDs lit solid after `fpga -file` + `ps7_init` + `ps7_post_config`**
(no `dow`/`con` needed — this design runs no software at all, PS7 is only
present here to supply `FCLK_CLK0`). Both cameras ACKed all three SCCB phases
(device ID write, register address write, device ID read) and returned the
correct PID byte. Confirms the digital core + SCCB control interface on both
sensors survived the incident. **Not yet confirmed: the analog image sensor
array itself** — that's only exercised once actual pixel capture is wired up
as part of the full stereo_cam port.

Bring-up gotcha found along the way (now fixed in the `zynq-fpga-bringup`
skill): `xsdb -eval "...; targets"` in batch mode does **not** auto-print the
return value the way interactive mode does — a bare `targets` call looked
identical to a genuinely empty JTAG chain (exit 0, no output) and burned a
full debugging cycle on `ftdi_sio` unbind / `hw_server` restarts / JTAG
pogo-pin reseating before the real cause (missing `puts [targets]`) was
found. The chain was detected correctly the entire time.

## Stereo depth camera (dual OV7670 + SSD disparity engine)

Ported from [Archfx/FPGA-DepthMap-Basys3](https://github.com/Archfx/FPGA-DepthMap-Basys3)
(branch `320x240`) — see `hw/ip/stereo_depth/*.vhd` file headers for exactly
what was ported unchanged vs. adapted per-file. This section covers the
board/system-level facts that don't belong in any single source file.

### Camera header pin map

Cam1 data lives on DATA1 (Bank 35), Cam2 data lives on DATA3 (Bank 34); both
cameras' `reset_n`/`pwdn` (static-level, not timing-sensitive) are on DATA2.
`PCLK`/`XCLK` land on clock-capable (MRCC/SRCC) pins for each camera.

| Signal | Cam1 port | Cam1 pin | Cam2 port | Cam2 pin | Clock (Cam1/Cam2) |
|---|---|---|---|---|---|
| SIOC | `cam_sioc` | A20 | `cam2_sioc` | M19 | - / - |
| PCLK | `cam_pclk` | H16 | `cam2_pclk` | N20 | MRCC / SRCC |
| SIOD | `cam_siod` | B19 | `cam2_siod` | P18 | - / - |
| VSYNC | `cam_vsync` | B20 | `cam2_vsync` | M17 | - / - |
| HREF | `cam_href` | C20 | `cam2_href` | N17 | - / - |
| XCLK | `cam_xclk` | H17 | `cam2_xclk` | P20 | MRCC / SRCC |
| D7..D0 | `cam_pdata[7:0]` | D20,D18,H18,D19,F20,E19,F19,K17 | `cam2_pdata[7:0]` | R18,R19,P19,T20,U20,T19,V20,U19 | - |
| RESET# | `cam_reset_n` | G20 | `cam2_reset_n` | G19 | - / - |
| PWDN | `cam_pwdn` | J18 | `cam2_pwdn` | H20 | - / - |

Full constraint file: `hw/constraints/camera.xdc` (also
`hw/constraints/i2c_probe.xdc` for the smaller SCCB-only standalone probe
above, which uses the same pins minus PCLK/HREF/VSYNC/D[7:0]).

### Resolution: 160x120, not the reference project's 320x240

`disparity_generator`'s `org_L`/`org_R` LUTRAM caches (sized
`WIDTH*fetchBlock`) need 6840 distributed-RAM cells at the reference
project's original 320x240/`fetchBlock`=15 sizing — confirmed via
`place_design` DRC (`UTLZ-1`, not guessed), not a synthesis estimate.
XC7Z010 has **more BRAM than Basys3's XC7A35T but less LUTRAM** (6000 vs
9600 cells) — this array is LUTRAM-bound, so the extra BRAM headroom
doesn't help. Dropped to 160x120/`fetchBlock`=8 instead, which fits its
existing 4-bit/16-branch `with select` statements unchanged (no
restructuring of the core algorithm needed) while shrinking the cache
array. Both resolutions were already supported by the reference design's
`rez_160x120`/`rez_320x240` mode inputs — this is a parameter change, not
new logic.

**Band count is not free-running.** The reference let its 4-bit
`cacheManager` wrap 0..15, which was only correct because its own geometry
happened to match exactly (15 rows/band × 16 bands = 240 = its HEIGHT).
That coincidence does not survive the resolution change (8 × 16 = 128 ≠
120), so `disparity_generator` now derives `NBANDS = HEIGHT/fetchBlock`
(= 15 here) and resets the counter there, with elaboration-time `assert`s
that `fetchBlock` divides `HEIGHT` and that `NBANDS ≤ 16`. Without that it
would process 8 phantom rows past the bottom of every frame.

Final resource usage at this geometry: **40/60 BRAM, 2400/6000 LUTRAM**.

### Clocking

`stereo_depth_top`'s `clk50` port (named for its original intended 50MHz)
is fed by PS7 `FCLK0`, currently configured for **40MHz**, not 50 —
50MHz failed timing closure on `SSD_calc_process`'s 8-tap combinational
sum-of-squared-differences path (WNS ≈ -1.7ns at 50MHz, confirmed via
`route_design`, not estimated). At 40MHz it closes with **WNS = +0.199ns,
WHS = +0.027ns** — real but thin margin, so anything that lengthens the SSD
path should be re-checked against `route_design` rather than assumed safe.
This same `clk50` also drives camera
`XCLK` (divide-by-2, so 20MHz — still within OV7670's valid 10-48MHz
range) and the AXI side of the disparity-frame BRAM window (`M_AXI_GP0_ACLK`
and the AXI interconnect/peripherals are all driven from the same FCLK0,
not a second clock domain). The reference project used a separate
Clocking Wizard whose actual `CLK_MAIN` frequency wasn't recoverable from
the files pulled during porting; unifying everything onto one PS7-derived
clock was the simplest choice that could actually be verified empirically
against XC7Z010's timing, rather than guessing a number the way the
original project's exact clocking couldn't be reconstructed.

### AXI register map (PS-side access to the disparity engine)

| Peripheral | Base | Range | Purpose |
|---|---|---|---|
| `axi_gpio_ctrl` | `0x4120_0000` | 4K | control (ch.1, PS writes) + status (ch.2, PS reads) |
| `axi_bram_ctrl_disp` | `0x4000_0000` | 128K | disparity frame, 160x120x8-bit, packed 4 pixels/32-bit word |

Control register (channel 1, offset `0x0`), PS writes:

| Bits | Field |
|---|---|
| `[0]` | `resend` (pulse to reconfigure both cameras) |
| `[4:1]` | `row_offset` (stereo rectification, multiples of WIDTH=160 — this is a generic on `image_rectification`, fixed at instantiation time in `stereo_depth_top.vhd`, not resolution-independent; keep small, near the reference default of 8) |
| `[12:5]` | `col_offset` (stereo rectification fine offset, keep near the reference default of 20) |

Status register (channel 2, offset `0x8`), PS reads:

| Bits | Field |
|---|---|
| `[0]` | `cam1_config_ok` |
| `[1]` | `cam2_config_ok` |
| `[2]` | `frame_done_toggle` — flips once per finished frame. **Not a pulse** — `disparity_generator`'s own `frame_done` output is a single-`clk50`-cycle pulse, far too short for software polling a memory-mapped register to reliably catch, so `stereo_depth_top` wraps it in a toggle flip-flop; software watches for this bit to *change*, not for it to read as `1`. |

The disparity frame itself: AXI is byte-addressable and both the PL packing
and the ARM core are little-endian, so a PS-side `volatile u8*` pointed at
`axi_bram_ctrl_disp`'s base address reads individual pixel bytes directly —
no manual word-unpacking needed in software (see
`sw/apps/depth_stream/src/depth_stream.c`).

### UDP frame protocol

`sw/apps/depth_stream` streams each finished frame as a sequence of UDP
datagrams to port 5001 (destination configurable via
`depth_stream_set_dest()`, defaults to the board's usual point-to-point
laptop gateway, `192.168.2.1`). Each datagram is a 4-byte header followed
by up to 1400 pixel bytes:

| Field | Size | Meaning |
|---|---|---|
| `frame_id` | u16 | increments once per frame — lets the receiver detect a dropped/reordered chunk and discard the partial frame |
| `chunk_index` | u16 | pixel offset within the frame that this datagram's payload starts at |

Both header fields are **little-endian** (written natively by the ARM core,
no byte swapping). 19200 pixels (160x120) / 1400 per chunk = 14
datagrams/frame. The same UDP port also accepts a 2-byte command packet
`{row_offset, col_offset}` from the PC to update the calibration registers
above, at any time.

Receiver: `sw/tools/depth_receiver.py` (live view, `--save DIR` to dump PGM
frames, `--stats` for frame-rate/loss counters). Its reassembly was verified
against a synthetic sender replicating `send_frame()`'s exact chunking —
frames come back byte-identical — so the wire format is confirmed
independently of the board being present.

### Deployment: verified working on hardware (2026-09-29)

Full chain brought up over JTAG and confirmed end-to-end:

| Check | Result |
|---|---|
| PHY link | fixed 100 Mbps (`CONFIG_LINKSPEED100` confirmed active in UART log) |
| `ping 192.168.2.10` | 0% loss, ~0.14 ms RTT |
| AXI GPIO status (`0x4120_0008`) | `0x7` — both cameras `config_ok`, `frame_done_toggle` running |
| Disparity engine frame rate | **33.5 fps** at 160x120 |
| UDP delivery | 100% of frames, ~14 datagrams each, no loss observed over 10 s |
| BRAM window vs. UDP payload | cross-checked identical via `mrd` — confirms both the AXI window and the wire format |

Build/deploy sequence that produced this (the SDT flow, see
`vitis-2026-empyro` notes for the CLI details):

```
sdtgen -xsa hw/build/stereo_cam.xsa -dir sw/dts
empyro create_bsp -w sw/workspace -s sw/dts/system-top.dts -p ps7_cortexa9_0
empyro config_bsp -d sw/workspace -al lwip220
empyro create_app -w sw/workspace -n depth_stream_app -d sw/workspace -t lwip_echo_server
empyro build_app -w sw/workspace
```

Two gotchas worth keeping:

- **The `lwip_echo_server` template refuses to instantiate unless
  `lwip220_dhcp` and `lwip220_lwip_dhcp_does_acd_check` are `True`** — the
  exact opposite of what this board needs (see the Ethernet bring-up
  section above). Validation only runs at `create_app` time, so the working
  order is: set them `True` → `create_app` → set them back to `False`. The
  template also requires `lwip220_pbuf_pool_size: 2048` and
  `XILTIMER_en_interval_timer: True`; both are genuinely wanted here
  anyway (the pbuf pool covers the 14-datagram burst per frame).
- `create_app` puts sources in `sw/workspace/src/`, **not** in a
  subdirectory named after the app. Its generated
  `Lwip_echo_serverExample.cmake` carries the current platform's addresses,
  so it must not be replaced with a copy from an older platform — overlay
  only the app's own `.c`/`.h` files and edit the `collect
  (PROJECT_LIB_SOURCES ...)` list in place.

### Bugs found and fixed while porting

These were latent in the reference design (or introduced by the resolution
change) and are fixed in this port — worth knowing if comparing against
upstream, since upstream still has the first three:

1. **`org_L`/`org_R` cache array was too small.** Declared
   `array(0 to WIDTH*fetchBlock+1)`, but `caching_process` deliberately
   fills `WIDTH*fetchBlock+2*WIDTH` entries (two extra rows so the 3×3
   window has context above and below) and `SSD_calc_process` reads up to
   the same bound. Both overran the array, so the bottom rows of every band
   matched against undefined data. Resized to
   `WIDTH*fetchBlock + 2*WIDTH`.
2. **SSD window index could go negative.** The lowest index used is
   `(row-1)*WIDTH + col-1 - offset`, which underflows whenever
   `offset >= col` — routine, not a corner case, since `offset` sweeps
   `minoffset..maxoffset` for *every* pixel, so all of the leftmost
   `maxoffset` columns hit it. The garbage read still took part in the
   `ssd < prev_ssd` comparison and could win, i.e. be emitted as a real
   disparity. Now gated by `window_valid`, with invalid windows forced to
   maximum SSD so they can never win.
3. **`dOUT` underflowed.** `(best_offset - minoffset)*4` with
   `best_offset` = 0 (its per-pixel reset value, and now the normal outcome
   for the leftmost columns) is negative; `to_unsigned()` of a negative
   value is undefined. Clamped to 0 = "no disparity found here".
   Relatedly, `Image_write_process`'s `rising_edge(offsetfound) or
   rising_edge(HCLK)` isn't synthesizable as written — Vivado silently
   dropped the non-clock edge, so the hardware never matched the source;
   that is now written explicitly as the `HCLK`-only process it always
   compiled to.
4. **Band count didn't match frame height** after the resolution change —
   see the `NBANDS` note above.
5. **Frame buffers were oversized.** `DEPTH` was left at 80000 from the
   320x240 sizing; worst-case address actually reachable at 160x120 is
   22014 (disparity engine's max `left_right_addr` plus the largest possible
   rectification correction), so they are now 2**15 deep. This alone
   returned ~12 BRAMs.

## Boot target

SD-card boot is baremetal/standalone: FSBL + bitstream + app ELF packaged
into `BOOT.bin` via `bootgen`. Not a full U-Boot+Linux image (that's a
separate, much larger undertaking — cross-building U-Boot, kernel, rootfs —
out of scope here unless requested later).

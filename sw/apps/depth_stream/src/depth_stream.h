/*
 * depth_stream: read the finished disparity frame out of the PL and
 * stream it to a PC over UDP. See hw/ip/stereo_depth/stereo_depth_top.vhd
 * and hw/scripts/build_bd.tcl for the hardware side of this interface.
 */
#ifndef DEPTH_STREAM_H
#define DEPTH_STREAM_H

#include "xil_types.h"
#include "xparameters.h"

/* Register addresses come from the BSP-generated xparameters.h, keyed off
 * the BD cell instance names in hw/scripts/build_bd.tcl ("axi_gpio_ctrl",
 * "axi_bram_ctrl_disp"). Taking them from there rather than hardcoding
 * means a change to the assign_bd_address offsets in the block design
 * can't silently desync from this app. The literals below are only a
 * fallback for building against a platform that predates those cells --
 * they match what build_bd.tcl currently assigns (0x41200000 / 4K and
 * 0x40000000 / 128K). */
#ifndef DEPTH_GPIO_BASEADDR
#ifdef XPAR_AXI_GPIO_CTRL_BASEADDR
#define DEPTH_GPIO_BASEADDR XPAR_AXI_GPIO_CTRL_BASEADDR
#else
#define DEPTH_GPIO_BASEADDR 0x41200000U
#endif
#endif

#ifndef DEPTH_BRAM_BASEADDR
#ifdef XPAR_AXI_BRAM_CTRL_DISP_BASEADDR
#define DEPTH_BRAM_BASEADDR XPAR_AXI_BRAM_CTRL_DISP_BASEADDR
#else
#define DEPTH_BRAM_BASEADDR 0x40000000U
#endif
#endif

/* Standard AXI GPIO (dual-channel) register offsets. */
#define DEPTH_GPIO_CTRL_OFFSET   0x0U /* channel 1 data: PS writes, PL reads */
#define DEPTH_GPIO_STATUS_OFFSET 0x8U /* channel 2 data: PL writes, PS reads */

/* Control register (channel 1) bit layout -- must match
 * stereo_depth_top's control-channel bit layout in build_bd.tcl. */
#define DEPTH_CTRL_RESEND_BIT      0
#define DEPTH_CTRL_ROW_OFFSET_SHIFT 1  /* 4 bits, [4:1] */
#define DEPTH_CTRL_COL_OFFSET_SHIFT 5  /* 8 bits, [12:5] */

/* Status register (channel 2) bit layout. */
#define DEPTH_STATUS_CAM1_OK_BIT      0
#define DEPTH_STATUS_CAM2_OK_BIT      1
#define DEPTH_STATUS_FRAME_TOGGLE_BIT 2

/* Frame geometry -- must match disparity_generator's WIDTH/HEIGHT generics
 * in stereo_depth_top.vhd (160x120, see that file's comments on why --
 * XC7Z010's LUTRAM budget, not a resolution choice made for its own sake). */
#define DEPTH_FRAME_WIDTH  160
#define DEPTH_FRAME_HEIGHT 120
#define DEPTH_FRAME_PIXELS (DEPTH_FRAME_WIDTH * DEPTH_FRAME_HEIGHT)

/* UDP destination -- point this at whatever PC is running the receiver.
 * No discovery/config protocol here; edit and rebuild, matching how the
 * static board IP itself is set (see main.c), or override at runtime via
 * depth_stream_set_dest() before start_application(). */
#define DEPTH_DEST_PORT 5001

/* Raw-camera preview windows (packed 8 pixels per 32-bit word in the PL,
 * see hw/ip/stereo_depth/preview_buffer.vhd). Separate from the frame
 * buffers the disparity engine uses -- those have no spare port. */
#ifndef DEPTH_PREV1_BASEADDR
#ifdef XPAR_AXI_BRAM_CTRL_PREV1_BASEADDR
#define DEPTH_PREV1_BASEADDR XPAR_AXI_BRAM_CTRL_PREV1_BASEADDR
#else
#define DEPTH_PREV1_BASEADDR 0x40100000U
#endif
#endif
#ifndef DEPTH_PREV2_BASEADDR
#ifdef XPAR_AXI_BRAM_CTRL_PREV2_BASEADDR
#define DEPTH_PREV2_BASEADDR XPAR_AXI_BRAM_CTRL_PREV2_BASEADDR
#else
#define DEPTH_PREV2_BASEADDR 0x40110000U
#endif
#endif

/* Which plane a datagram carries. Kept in the header so one stream can
 * interleave all three without the receiver having to guess. */
#define PLANE_DEPTH 0
#define PLANE_CAM1  1
#define PLANE_CAM2  2

/* Wire format: each UDP datagram is a small header followed by up to
 * DEPTH_CHUNK_PIXELS pixel bytes. frame_id increments once per frame (lets
 * the receiver detect a dropped/reordered chunk and discard the partial
 * frame rather than silently corrupting it); chunk_index is the pixel
 * offset within the frame that this datagram's payload starts at. */
/* EXACTLY 8 bytes, and that size is load-bearing, not cosmetic.
 *
 * The payload is memcpy'd straight out of the PL AXI windows, which the
 * Zynq standalone translation table maps as Strongly Ordered
 * (translation_table.S, 0x40000000-0xBFFFFFFF). Strongly Ordered memory
 * forbids unaligned access -- an unaligned load there is an alignment
 * fault, i.e. a data abort, not a slow-but-working access.
 *
 * memcpy's destination is (payload + sizeof(this header)), so a header
 * whose size is not a multiple of 4 pushes the copy out of phase and lets
 * memcpy issue unaligned word loads against the source window. A 6-byte
 * header did exactly that and crashed the board on the first frame, after
 * the 4-byte version had streamed for hours. Keep this a multiple of 4. */
typedef struct __attribute__((packed)) {
	u16 frame_id;
	u16 chunk_index;
	u8  plane;        /* PLANE_* above */
	u8  reserved;
	u16 reserved2;
} depth_chunk_hdr_t;

#define DEPTH_CHUNK_PIXELS 1400 /* keeps datagrams under a safe ~1472B MTU budget */

void depth_stream_set_dest(u8 a, u8 b, u8 c, u8 d);
void depth_stream_set_planes(u8 mask);  /* bit0=cam1, bit1=cam2 preview */
int  start_application(void);
int  transfer_data(void);

#endif /* DEPTH_STREAM_H */

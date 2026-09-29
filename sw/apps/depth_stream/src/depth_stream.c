/*
 * depth_stream: poll the PL's frame-done toggle bit, and when a new frame
 * has landed, stream the 160x120 disparity frame out over UDP in small
 * chunks.
 *
 * Tuning (rectification offsets, camera registers, resend) lives in
 * cam_ctrl.c on its own UDP port. Nothing in this file may write the
 * control GPIO: cam_ctrl keeps a shadow of it, and a blind whole-register
 * write here would silently clobber the SCCB bus-ownership bits.
 */
#include <string.h>

#include "xil_io.h"
#include "xil_printf.h"
#include "lwip/udp.h"
#include "lwip/pbuf.h"

#include "depth_stream.h"
#include "cam_ctrl.h"

/* The disparity frame is packed 4 pixels/32-bit word in the PL (see
 * stereo_depth_top.vhd's disp_byte_we/disp_word_addr), but AXI is
 * byte-addressable and both sides are little-endian, so a straight
 * byte-indexed read through this window recovers the individual pixel
 * bytes directly -- no manual unpacking needed in software.
 *
 * No cache maintenance is done around these reads, and that is a real
 * dependency rather than an oversight: the Zynq-7000 standalone BSP's
 * default MMU translation table maps the PL AXI aperture
 * (0x4000_0000-0x7FFF_FFFF, which is where build_bd.tcl assigns this
 * window) as Device memory, i.e. non-cacheable, so every read here goes
 * straight to the PL. If that translation table is ever customized to make
 * this region cacheable, this code must gain an
 * Xil_DCacheInvalidateRange() before each frame read or it will happily
 * stream stale frames. */
static volatile u8 * const disp_frame = (volatile u8 *)DEPTH_BRAM_BASEADDR;

/* Preview windows hold 4-bit pixels packed 8 per 32-bit word. Read as
 * words, unpack to one byte per pixel, and scale 0-15 to 0-255 so the
 * receiver can treat every plane identically as 8-bit grayscale. */
static volatile u32 * const prev_win[2] = {
	(volatile u32 *)DEPTH_PREV1_BASEADDR,
	(volatile u32 *)DEPTH_PREV2_BASEADDR,
};
static u8 prev_line[DEPTH_CHUNK_PIXELS];

static struct udp_pcb *tx_pcb;
static ip_addr_t dest_ip;
static u8 dest_set;
static u16 frame_id;
static u8 last_frame_toggle;
static u8 have_last_toggle;

static inline u32 gpio_read_status(void)
{
	return Xil_In32(DEPTH_GPIO_BASEADDR + DEPTH_GPIO_STATUS_OFFSET);
}

void depth_stream_set_dest(u8 a, u8 b, u8 c, u8 d)
{
	IP4_ADDR(&dest_ip, a, b, c, d);
	dest_set = 1;
}

int start_application(void)
{
	err_t err;

	if (!dest_set) {
		/* No destination configured -- default to the laptop end of
		 * the board's dedicated point-to-point link (matches
		 * eth_test's proven static-IP setup, see docs/BOARD_CONFIG.md). */
		depth_stream_set_dest(192, 168, 2, 1);
	}

	tx_pcb = udp_new();
	if (!tx_pcb) {
		xil_printf("depth_stream: udp_new (tx) failed\r\n");
		return -1;
	}
	err = udp_connect(tx_pcb, &dest_ip, DEPTH_DEST_PORT);
	if (err != ERR_OK) {
		xil_printf("depth_stream: udp_connect failed: %d\r\n", err);
		return -2;
	}

	if (cam_ctrl_start() != 0) {
		xil_printf("depth_stream: tuning server failed to start\r\n");
		return -5;
	}

	xil_printf("depth_stream: streaming %dx%d disparity frames, UDP port %d\r\n",
	           DEPTH_FRAME_WIDTH, DEPTH_FRAME_HEIGHT, DEPTH_DEST_PORT);
	return 0;
}

/* Fill buf with `n` pixels of `plane` starting at pixel `offset`. */
static const u8 *plane_chunk(u8 plane, u16 offset, u16 n)
{
	if (plane == PLANE_DEPTH) {
		return (const u8 *)disp_frame + offset;   /* already byte-per-pixel */
	}

	volatile const u32 *win = prev_win[plane == PLANE_CAM1 ? 0 : 1];
	for (u16 i = 0; i < n; i++) {
		u32 pix = offset + i;
		u32 w   = win[pix >> 3];
		u8  nib = (u8)((w >> ((pix & 7) * 4)) & 0xF);
		prev_line[i] = (u8)(nib * 17);            /* 0-15 -> 0-255 */
	}
	return prev_line;
}

static void send_plane(u8 plane)
{
	u16 offset = 0;

	while (offset < DEPTH_FRAME_PIXELS) {
		u16 n = DEPTH_FRAME_PIXELS - offset;
		if (n > DEPTH_CHUNK_PIXELS) {
			n = DEPTH_CHUNK_PIXELS;
		}

		struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT,
		                            sizeof(depth_chunk_hdr_t) + n, PBUF_RAM);
		if (!p) {
			xil_printf("depth_stream: pbuf_alloc failed, dropping rest of frame\r\n");
			return;
		}

		depth_chunk_hdr_t hdr;
		hdr.frame_id    = frame_id;
		hdr.chunk_index = offset;
		hdr.plane       = plane;
		hdr.reserved    = 0;
		hdr.reserved2   = 0;
		memcpy(p->payload, &hdr, sizeof(hdr));
		memcpy((u8 *)p->payload + sizeof(hdr), plane_chunk(plane, offset, n), n);

		if (udp_send(tx_pcb, p) != ERR_OK) {
			xil_printf("depth_stream: udp_send failed\r\n");
		}
		pbuf_free(p);

		offset += n;
	}
}

/* Which preview planes to interleave with the depth plane.
 * Bit 0 = camera 1, bit 1 = camera 2. Set over UDP (CMD_SET_PLANES). */
static u8 preview_mask = 0x3;
static u8 preview_turn;

void depth_stream_set_planes(u8 mask)
{
	preview_mask = mask & 0x3;
}

static void send_frame(void)
{
	/* Exactly ONE plane per frame, round-robin.
	 *
	 * This is a hard constraint, not a preference: sending all three planes
	 * back-to-back tripled the per-frame burst to 42 datagrams and reliably
	 * crashed the board with a data abort -- the EmacPs driver has a fixed
	 * TX buffer-descriptor ring, and overrunning it corrupts memory rather
	 * than failing cleanly. One plane per frame keeps the burst at the 14
	 * datagrams that ran stably for hours.
	 *
	 * Cost: the depth plane now updates every other frame rather than every
	 * frame. For tuning that is a good trade -- being able to see the raw
	 * cameras at all matters more than depth frame rate. */
	static u8 send_depth_next = 1;

	if (send_depth_next || preview_mask == 0) {
		send_plane(PLANE_DEPTH);
		send_depth_next = 0;
	} else {
		/* Alternate between whichever previews are enabled. */
		u8 want = preview_turn;
		for (int i = 0; i < 2; i++) {
			if (preview_mask & (1U << want)) {
				break;
			}
			want ^= 1;
		}
		send_plane(want == 0 ? PLANE_CAM1 : PLANE_CAM2);
		preview_turn = want ^ 1;
		send_depth_next = 1;
	}

	frame_id++;
}

int transfer_data(void)
{
	u32 status = gpio_read_status();
	u8 toggle = (status >> DEPTH_STATUS_FRAME_TOGGLE_BIT) & 1;

	if (!have_last_toggle) {
		/* Don't send a frame on the very first poll -- we don't know
		 * yet whether the current frame in the BRAM window finished
		 * cleanly or is still being written. */
		last_frame_toggle = toggle;
		have_last_toggle = 1;
		return 0;
	}

	if (toggle != last_frame_toggle) {
		last_frame_toggle = toggle;
		send_frame();
	}

	return 0;
}

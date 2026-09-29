/*
 * SCCB bit-bang from the PS, plus the UDP control server.
 *
 * The SCCB sequencing here is the same one proven against real hardware in
 * sw/stm32_camtest/main.c -- notably that the OV7670 does NOT support a
 * repeated START, so a register read has to be split into write-then-STOP,
 * then a fresh START for the read. Hardware I2C blocks fight that; bit-bang
 * does not.
 *
 * Every line is driven through one shadow copy of the AXI GPIO output
 * register. The GPIO is configured all-outputs, so reading it back is not a
 * reliable way to learn what we last wrote -- the shadow is the source of
 * truth.
 */
#include <string.h>

#include "xil_io.h"
#include "xil_printf.h"
#include "lwip/pbuf.h"

#include "cam_ctrl.h"
#include "depth_stream.h"

#define GPIO_DATA   (DEPTH_GPIO_BASEADDR + 0x0U)
#define GPIO2_DATA  (DEPTH_GPIO_BASEADDR + 0x8U)

static u32 ctrl_shadow;
static struct udp_pcb *ctrl_pcb;

static void ctrl_write(void)
{
    Xil_Out32(GPIO_DATA, ctrl_shadow);
}

static void ctrl_set(u32 mask, u32 value)
{
    ctrl_shadow = (ctrl_shadow & ~mask) | (value & mask);
    ctrl_write();
}

static inline u32 status_read(void)
{
    return Xil_In32(GPIO2_DATA);
}

/* ~5 us at any plausible CPU clock. SCCB tops out around 400 kHz and is
 * entirely tolerant of a slow, jittery clock, so a crude spin is fine and
 * avoids depending on a timer that the streaming path also wants. */
static void sccb_delay(void)
{
    for (volatile int i = 0; i < 400; i++) { }
}

static void sioc(int cam, int high)
{
    u32 bit = 1U << (CTRL_SIOC_SHIFT + cam);
    ctrl_set(bit, high ? bit : 0);
}

/* Open-drain: "high" means release the line (oe=0) and let the pull-up or
 * the camera drive it. Never actively driven high. */
static void siod(int cam, int high)
{
    u32 oe = 1U << (CTRL_SIOD_OE_SHIFT + cam);
    u32 o  = 1U << (CTRL_SIOD_O_SHIFT + cam);
    if (high) {
        ctrl_set(oe | o, 0);
    } else {
        ctrl_set(oe | o, oe);
    }
}

static int siod_read(int cam)
{
    return (status_read() >> (STAT_SIOD_I_SHIFT + cam)) & 1U;
}

static void sccb_start(int cam)
{
    siod(cam, 1); sioc(cam, 1); sccb_delay();
    siod(cam, 0); sccb_delay();
    sioc(cam, 0); sccb_delay();
}

static void sccb_stop(int cam)
{
    siod(cam, 0); sccb_delay();
    sioc(cam, 1); sccb_delay();
    siod(cam, 1); sccb_delay();
}

/* Returns 1 if the camera pulled SDA low in the ACK slot. */
static int sccb_write_byte(int cam, u8 v)
{
    for (int i = 7; i >= 0; i--) {
        siod(cam, (v >> i) & 1);
        sccb_delay();
        sioc(cam, 1); sccb_delay(); sccb_delay();
        sioc(cam, 0); sccb_delay();
    }
    siod(cam, 1);                 /* release for ACK */
    sccb_delay();
    sioc(cam, 1); sccb_delay();
    int ack = !siod_read(cam);
    sccb_delay();
    sioc(cam, 0); sccb_delay();
    return ack;
}

static u8 sccb_read_byte(int cam)
{
    u8 v = 0;
    siod(cam, 1);                 /* released; camera drives */
    for (int i = 7; i >= 0; i--) {
        sccb_delay();
        sioc(cam, 1); sccb_delay();
        v = (u8)((v << 1) | siod_read(cam));
        sccb_delay();
        sioc(cam, 0); sccb_delay();
    }
    siod(cam, 1);                 /* NACK: single-byte read */
    sccb_delay();
    sioc(cam, 1); sccb_delay(); sccb_delay();
    sioc(cam, 0); sccb_delay();
    return v;
}

/* Hand the SCCB buses from the hardware controller to software for the
 * duration of one transaction, then give them back. Leaving software in
 * control permanently would stop the hardware controller's resend path from
 * ever working again. */
static void sccb_acquire(void)
{
    ctrl_set(1U << CTRL_SCCB_EN_BIT, 1U << CTRL_SCCB_EN_BIT);
}

static void sccb_release(void)
{
    ctrl_set(1U << CTRL_SCCB_EN_BIT, 0);
}

static int sccb_write_reg(int cam, u8 reg, u8 val)
{
    sccb_acquire();
    sccb_start(cam);
    int ok = sccb_write_byte(cam, 0x42);
    ok &= sccb_write_byte(cam, reg);
    ok &= sccb_write_byte(cam, val);
    sccb_stop(cam);
    sccb_release();
    return ok;
}

static int sccb_read_reg(int cam, u8 reg, u8 *val)
{
    sccb_acquire();
    sccb_start(cam);
    int ok = sccb_write_byte(cam, 0x42);
    ok &= sccb_write_byte(cam, reg);
    sccb_stop(cam);               /* OV7670: no repeated START */

    sccb_start(cam);
    ok &= sccb_write_byte(cam, 0x43);
    *val = sccb_read_byte(cam);
    sccb_stop(cam);
    sccb_release();
    return ok;
}

void cam_ctrl_apply_rect(u8 row_offset, u8 col_offset)
{
    ctrl_set(0xFU << CTRL_ROW_OFFSET_SHIFT,
             ((u32)(row_offset & 0xF)) << CTRL_ROW_OFFSET_SHIFT);
    ctrl_set(0xFFU << CTRL_COL_OFFSET_SHIFT,
             ((u32)col_offset) << CTRL_COL_OFFSET_SHIFT);
}

static void ctrl_recv(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                      const ip_addr_t *addr, u16_t port)
{
    (void)arg; (void)pcb;
    if (!p) return;
    if (p->len < sizeof(ctrl_req_t)) { pbuf_free(p); return; }

    ctrl_req_t req;
    memcpy(&req, p->payload, sizeof(req));
    pbuf_free(p);

    ctrl_rsp_t rsp;
    memset(&rsp, 0, sizeof(rsp));
    rsp.magic0 = CTRL_MAGIC0;
    rsp.magic1 = CTRL_MAGIC1;
    rsp.cmd    = req.cmd;
    rsp.seq    = req.seq;

    if (req.magic0 != CTRL_MAGIC0 || req.magic1 != CTRL_MAGIC1) {
        rsp.status = ST_BAD_MAGIC;
    } else {
        int cam = (req.cam == 1) ? 1 : 0;
        switch (req.cmd) {
        case CMD_PING:
            rsp.status = ST_OK;
            break;

        case CMD_SCCB_WRITE:
            rsp.status = sccb_write_reg(cam, req.arg0, req.arg1)
                             ? ST_OK : ST_NO_ACK;
            rsp.value  = req.arg1;
            break;

        case CMD_SCCB_READ: {
            u8 v = 0;
            int ok = sccb_read_reg(cam, req.arg0, &v);
            rsp.status = ok ? ST_OK : ST_NO_ACK;
            rsp.value  = v;
            break;
        }

        case CMD_SET_RECT:
            cam_ctrl_apply_rect(req.arg0, req.arg1);
            rsp.status = ST_OK;
            break;

        case CMD_RESEND:
            /* The hardware controller restarts its register walk on a
             * rising edge of this bit, so pulse rather than level it. */
            ctrl_set(1U << CTRL_RESEND_BIT, 1U << CTRL_RESEND_BIT);
            for (volatile int i = 0; i < 20000; i++) { }
            ctrl_set(1U << CTRL_RESEND_BIT, 0);
            rsp.status = ST_OK;
            break;

        case CMD_SET_PLANES:
            depth_stream_set_planes(req.arg0);
            rsp.status = ST_OK;
            rsp.value  = req.arg0 & 0x3;
            break;

        case CMD_GET_STATUS:
            rsp.status = ST_OK;
            rsp.value  = (u8)(status_read() & 0x1FU);
            break;

        default:
            rsp.status = ST_BAD_CMD;
            break;
        }
    }

    struct pbuf *out = pbuf_alloc(PBUF_TRANSPORT, sizeof(rsp), PBUF_RAM);
    if (!out) return;
    memcpy(out->payload, &rsp, sizeof(rsp));
    udp_sendto(ctrl_pcb, out, addr, port);
    pbuf_free(out);
}

int cam_ctrl_start(void)
{
    /* Start from a defined state: hardware owns SCCB, rectification at the
     * reference design's defaults (row 8, col 20). */
    ctrl_shadow = 0;
    cam_ctrl_apply_rect(8, 20);
    sccb_release();

    ctrl_pcb = udp_new();
    if (!ctrl_pcb) {
        xil_printf("cam_ctrl: udp_new failed\r\n");
        return -1;
    }
    if (udp_bind(ctrl_pcb, IP_ANY_TYPE, CTRL_PORT) != ERR_OK) {
        xil_printf("cam_ctrl: bind %d failed\r\n", CTRL_PORT);
        return -2;
    }
    udp_recv(ctrl_pcb, ctrl_recv, NULL);
    xil_printf("cam_ctrl: tuning server on UDP %d\r\n", CTRL_PORT);
    return 0;
}

/*
 * OV7670 sanity/functional tester for STM32F446RE Nucleo-64.
 *
 * Purpose: verify an OV7670 module completely independently of the FPGA, so
 * "is the camera itself alive and producing a sensible image" can be
 * answered with a known-good reference before blaming the FPGA design.
 *
 * Everything is register-level and CMSIS-free (builds with plain
 * arm-none-eabi-gcc), and every wait loop is bounded -- the firmware reports
 * a timeout over UART rather than hanging, which is the whole point of a
 * diagnostic tool.
 *
 * ---------------------------------------------------------------------
 * WIRING (Nucleo-64 F446RE morpho/Arduino headers)
 * ---------------------------------------------------------------------
 *   OV7670        Nucleo pin   Notes
 *   3V3           3V3          do NOT use 5V
 *   GND           GND
 *   PWDN          GND          tied low in hardware -- always awake
 *   RESET#        3V3          tied high in hardware -- never reset
 *   XCLK          PA8          16 MHz, driven by MCU (MCO1 = HSI)
 *   PCLK          PA9          input
 *   VSYNC         PA10         input
 *   HREF          PA11         input
 *   D0..D7        PC0..PC7     contiguous -- one register read per pixel byte
 *   SIOC (SCL)    PB8          bit-banged SCCB, open-drain
 *   SIOD (SDA)    PB9          bit-banged SCCB, open-drain
 *
 * PWDN/RESET# are strapped in hardware, so the firmware never drives them.
 * That also means a camera wedged into a bad state cannot be recovered by
 * toggling RESET# -- only by power-cycling the board.
 *
 * Console: USART2 on PA2/PA3 -> ST-LINK virtual COM port (/dev/ttyACM0),
 * 921600 8N1.
 *
 * Commands (single characters sent to the console):
 *   p  probe SCCB identity registers
 *   a  measure PCLK/HREF/VSYNC edge activity
 *   r  dump a block of camera registers
 *   c  capture one frame and stream it out
 *   h  help
 */
#include <stdint.h>

/* ------------------------------------------------------------------ */
/* Minimal register map                                                */
/* ------------------------------------------------------------------ */
#define REG(a)          (*(volatile uint32_t *)(a))

#define RCC_BASE        0x40023800U
#define RCC_CR          REG(RCC_BASE + 0x00)
#define RCC_PLLCFGR     REG(RCC_BASE + 0x04)
#define RCC_CFGR        REG(RCC_BASE + 0x08)
#define RCC_AHB1ENR     REG(RCC_BASE + 0x30)
#define RCC_APB1ENR     REG(RCC_BASE + 0x40)

#define FLASH_ACR       REG(0x40023C00U)

#define GPIOA_BASE      0x40020000U
#define GPIOB_BASE      0x40020400U
#define GPIOC_BASE      0x40020800U
#define GPIO_MODER(p)   REG((p) + 0x00)
#define GPIO_OTYPER(p)  REG((p) + 0x04)
#define GPIO_OSPEEDR(p) REG((p) + 0x08)
#define GPIO_PUPDR(p)   REG((p) + 0x0C)
#define GPIO_IDR(p)     REG((p) + 0x10)
#define GPIO_BSRR(p)    REG((p) + 0x18)
#define GPIO_AFRH(p)    REG((p) + 0x24)

#define USART2_BASE     0x40004400U
#define USART_SR        REG(USART2_BASE + 0x00)
#define USART_DR        REG(USART2_BASE + 0x04)
#define USART_BRR       REG(USART2_BASE + 0x08)
#define USART_CR1       REG(USART2_BASE + 0x0C)

#define SYSCLK_HZ       84000000U
#define PCLK1_HZ        42000000U

/* Camera signal bit positions. PWDN/RESET# are strapped in hardware (to GND
 * and 3V3 respectively), so there are no MCU pins for them. */
#define PIN_PCLK        9       /* PA9  */
#define PIN_VSYNC       10      /* PA10 */
#define PIN_HREF        11      /* PA11 */
#define PIN_SIOC        8       /* PB8  */
#define PIN_SIOD        9       /* PB9  */

#define FRAME_W         160
#define FRAME_H         120
#define BYTES_PER_PIX   2                       /* YUV422 */
#define FRAME_BYTES     (FRAME_W * FRAME_H * BYTES_PER_PIX)

static uint8_t framebuf[FRAME_BYTES];

/* ------------------------------------------------------------------ */
/* Timing helpers                                                      */
/* ------------------------------------------------------------------ */
/* DWT cycle counter: gives real microsecond timing and, more importantly,
 * lets every wait loop below have a hard cycle budget instead of a guessed
 * iteration count. */
#define DWT_CTRL        REG(0xE0001000U)
#define DWT_CYCCNT      REG(0xE0001004U)
#define DEMCR           REG(0xE000EDFCU)

static void cyccnt_init(void)
{
    DEMCR    |= (1U << 24);   /* TRCENA */
    DWT_CYCCNT = 0;
    DWT_CTRL |= 1U;           /* CYCCNTENA */
}

static inline uint32_t cycles(void) { return DWT_CYCCNT; }

static void delay_us(uint32_t us)
{
    uint32_t start = cycles();
    uint32_t want  = us * (SYSCLK_HZ / 1000000U);
    while ((cycles() - start) < want) { }
}

static void delay_ms(uint32_t ms) { while (ms--) delay_us(1000); }

/* ------------------------------------------------------------------ */
/* Clocks                                                              */
/* ------------------------------------------------------------------ */
static void clock_init(void)
{
    /* HSI is already on out of reset. Build 84 MHz:
     *   VCO in  = 16 MHz / PLLM(16) = 1 MHz
     *   VCO out = 1 MHz * PLLN(336) = 336 MHz
     *   SYSCLK  = 336 MHz / PLLP(4) = 84 MHz
     *   PLLQ(7) = 48 MHz (unused, but must stay legal) */
    FLASH_ACR = (1U << 10) | (1U << 9) | (1U << 8) | 2U; /* DC/IC/prefetch, 2WS */

    RCC_PLLCFGR = 16U | (336U << 6) | (1U << 16) | (7U << 24); /* PLLSRC=HSI */
    RCC_CR |= (1U << 24);                       /* PLLON */
    while (!(RCC_CR & (1U << 25))) { }          /* PLLRDY */

    /* AHB /1, APB1 /2 (=42 MHz, max 45), APB2 /1 */
    RCC_CFGR = (RCC_CFGR & ~0xFFFFU) | (4U << 10);

    RCC_CFGR = (RCC_CFGR & ~3U) | 2U;           /* SW = PLL */
    while (((RCC_CFGR >> 2) & 3U) != 2U) { }    /* SWS = PLL */

    /* MCO1 = HSI, prescaler /1 -> 16 MHz XCLK on PA8. Sourced from HSI
     * rather than the PLL so the camera clock is independent of the core
     * clock setup above. */
    RCC_CFGR &= ~((3U << 21) | (7U << 24));
}

/* ------------------------------------------------------------------ */
/* GPIO                                                                */
/* ------------------------------------------------------------------ */
static void gpio_mode(uint32_t port, uint32_t pin, uint32_t mode)
{
    GPIO_MODER(port) = (GPIO_MODER(port) & ~(3U << (pin * 2))) | (mode << (pin * 2));
}

static void gpio_init(void)
{
    RCC_AHB1ENR |= 0x7U;  /* GPIOA, GPIOB, GPIOC */

    /* PA8 = MCO1 (AF0), very-high speed so 16 MHz is a clean edge */
    gpio_mode(GPIOA_BASE, 8, 2);
    GPIO_AFRH(GPIOA_BASE) &= ~(0xFU << 0);
    GPIO_OSPEEDR(GPIOA_BASE) |= (3U << (8 * 2));

    /* PA2 = USART2_TX, PA3 = USART2_RX (AF7) */
    gpio_mode(GPIOA_BASE, 2, 2);
    gpio_mode(GPIOA_BASE, 3, 2);
    REG(GPIOA_BASE + 0x20) = (REG(GPIOA_BASE + 0x20) & ~0xFF00U) | (7U << 8) | (7U << 12);

    /* Camera sync inputs, with pull-downs. The pull-downs are important for
     * diagnosis, not for function: the OV7670 drives these push-pull, so a
     * pull-down never fights a connected camera -- but a DISCONNECTED pin
     * left floating picks up tens of kHz of ambient noise and reports as
     * "active", which is exactly the false positive this tool must not
     * produce. With pull-downs, absent means a clean, unambiguous zero. */
    gpio_mode(GPIOA_BASE, PIN_PCLK,  0);
    gpio_mode(GPIOA_BASE, PIN_VSYNC, 0);
    gpio_mode(GPIOA_BASE, PIN_HREF,  0);
    GPIO_PUPDR(GPIOA_BASE) &= ~((3U << (PIN_PCLK  * 2)) |
                                (3U << (PIN_VSYNC * 2)) |
                                (3U << (PIN_HREF  * 2)));
    GPIO_PUPDR(GPIOA_BASE) |=  ((2U << (PIN_PCLK  * 2)) |
                                (2U << (PIN_VSYNC * 2)) |
                                (2U << (PIN_HREF  * 2)));

    /* Data bus PC0..PC7, all inputs, pulled down for the same reason. */
    GPIO_MODER(GPIOC_BASE) &= ~0x0000FFFFU;
    GPIO_PUPDR(GPIOC_BASE) = (GPIO_PUPDR(GPIOC_BASE) & ~0x0000FFFFU) | 0x0000AAAAU;

    /* SCCB: open-drain outputs, internal pull-ups on (module usually has
     * its own, but this makes the firmware work on bare modules too) */
    gpio_mode(GPIOB_BASE, PIN_SIOC, 1);
    gpio_mode(GPIOB_BASE, PIN_SIOD, 1);
    GPIO_OTYPER(GPIOB_BASE) |= (1U << PIN_SIOC) | (1U << PIN_SIOD);
    GPIO_PUPDR(GPIOB_BASE)  |= (1U << (PIN_SIOC * 2)) | (1U << (PIN_SIOD * 2));
    GPIO_BSRR(GPIOB_BASE)    = (1U << PIN_SIOC) | (1U << PIN_SIOD); /* released */

    /* PWDN and RESET# are strapped in hardware on this wiring -- nothing to
     * drive here. */
}

/* ------------------------------------------------------------------ */
/* Console                                                             */
/* ------------------------------------------------------------------ */
static void uart_init(void)
{
    RCC_APB1ENR |= (1U << 17);
    /* 921600 @ 42 MHz: USARTDIV = 2.8483 -> mantissa 2, fraction 14 (0.875),
     * giving an actual 913043 baud, -0.93% off nominal -- well inside the
     * ~±2.5% an 8N1 receiver tolerates.
     *
     * Baud is the right thing to push for stream rate: a luma frame is
     * 19200 bytes, so the wire time dominates. Raising the camera's PCLK
     * instead would shorten the wait but squeeze the polled capture loop,
     * which at 84 MHz only has ~42 core cycles per PCLK half-period at
     * 1 MHz -- tightening that risks dropped pixels, and a reference
     * instrument must not trade correctness for frame rate. */
    USART_BRR = (2U << 4) | 14U;
    USART_CR1 = (1U << 13) | (1U << 3) | (1U << 2); /* UE | TE | RE */
}

static void putc_raw(uint8_t c)
{
    while (!(USART_SR & (1U << 7))) { }
    USART_DR = c;
}

static void print(const char *s) { while (*s) putc_raw((uint8_t)*s++); }

static void print_hex8(uint8_t v)
{
    const char *d = "0123456789ABCDEF";
    putc_raw((uint8_t)d[v >> 4]);
    putc_raw((uint8_t)d[v & 0xF]);
}

static void print_u32(uint32_t v)
{
    char buf[11];
    int i = 0;
    if (!v) { putc_raw('0'); return; }
    while (v) { buf[i++] = (char)('0' + (v % 10)); v /= 10; }
    while (i--) putc_raw((uint8_t)buf[i]);
}

static int uart_getc_timeout(uint32_t ms, uint8_t *out)
{
    uint32_t start = cycles();
    uint32_t want  = ms * (SYSCLK_HZ / 1000U);
    while ((cycles() - start) < want) {
        if (USART_SR & (1U << 5)) { *out = (uint8_t)USART_DR; return 1; }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* SCCB (OV7670's I2C-like control bus), bit-banged                    */
/* ------------------------------------------------------------------ */
/* Bit-banged rather than using the I2C peripheral on purpose: SCCB is not
 * quite I2C (notably the OV7670 does not support a repeated START, so a
 * register read must be split into write-then-STOP, then START-read), and
 * hardware I2C blocks tend to fight that. Bit-banging also keeps every edge
 * observable if this ever needs a scope on it. */
#define SCCB_ADDR_W  0x42
#define SCCB_ADDR_R  0x43
#define SCCB_HALF_US 5           /* ~100 kHz */

static inline void sioc(int hi)
{
    GPIO_BSRR(GPIOB_BASE) = hi ? (1U << PIN_SIOC) : (1U << (PIN_SIOC + 16));
}
static inline void siod(int hi)
{
    GPIO_BSRR(GPIOB_BASE) = hi ? (1U << PIN_SIOD) : (1U << (PIN_SIOD + 16));
}
static inline int siod_read(void)
{
    return (GPIO_IDR(GPIOB_BASE) >> PIN_SIOD) & 1U;
}

static void sccb_start(void)
{
    siod(1); sioc(1); delay_us(SCCB_HALF_US);
    siod(0); delay_us(SCCB_HALF_US);
    sioc(0); delay_us(SCCB_HALF_US);
}

static void sccb_stop(void)
{
    siod(0); delay_us(SCCB_HALF_US);
    sioc(1); delay_us(SCCB_HALF_US);
    siod(1); delay_us(SCCB_HALF_US);
}

/* Returns 1 if the slave pulled SDA low for the ACK slot. */
static int sccb_write_byte(uint8_t v)
{
    for (int i = 7; i >= 0; i--) {
        siod((v >> i) & 1);
        delay_us(SCCB_HALF_US);
        sioc(1); delay_us(SCCB_HALF_US * 2);
        sioc(0); delay_us(SCCB_HALF_US);
    }
    siod(1);                       /* release for ACK */
    delay_us(SCCB_HALF_US);
    sioc(1); delay_us(SCCB_HALF_US);
    int ack = !siod_read();        /* low = ACK */
    delay_us(SCCB_HALF_US);
    sioc(0); delay_us(SCCB_HALF_US);
    return ack;
}

static uint8_t sccb_read_byte(int nack)
{
    uint8_t v = 0;
    siod(1);                       /* release, slave drives */
    for (int i = 7; i >= 0; i--) {
        delay_us(SCCB_HALF_US);
        sioc(1); delay_us(SCCB_HALF_US);
        v = (uint8_t)((v << 1) | siod_read());
        delay_us(SCCB_HALF_US);
        sioc(0); delay_us(SCCB_HALF_US);
    }
    siod(nack ? 1 : 0);
    delay_us(SCCB_HALF_US);
    sioc(1); delay_us(SCCB_HALF_US * 2);
    sioc(0); delay_us(SCCB_HALF_US);
    siod(1);
    return v;
}

static int sccb_write(uint8_t reg, uint8_t val)
{
    sccb_start();
    int ok = sccb_write_byte(SCCB_ADDR_W);
    ok &= sccb_write_byte(reg);
    ok &= sccb_write_byte(val);
    sccb_stop();
    delay_us(100);
    return ok;
}

static int sccb_read(uint8_t reg, uint8_t *val)
{
    sccb_start();
    int ok = sccb_write_byte(SCCB_ADDR_W);
    ok &= sccb_write_byte(reg);
    sccb_stop();                   /* OV7670: no repeated start */
    delay_us(100);

    sccb_start();
    ok &= sccb_write_byte(SCCB_ADDR_R);
    *val = sccb_read_byte(1);
    sccb_stop();
    delay_us(100);
    return ok;
}

/* ------------------------------------------------------------------ */
/* Camera configuration                                                */
/* ------------------------------------------------------------------ */
/* QQVGA (160x120) YUV422. Derived from the well-known OV7670 QQVGA
 * sequence (Linux ov7670.c / hamsterworks): scale VGA down by 4 in both
 * axes via DCW, and divide PCLK to match so the data rate drops with it.
 * CLKRC additionally divides the pixel clock by 8 so a polled GPIO capture
 * can comfortably keep up at 84 MHz -- frame rate is irrelevant here, not
 * dropping samples is what matters. */
struct regval { uint8_t reg, val; };

static const struct regval ov7670_qqvga_yuv[] = {
    { 0x12, 0x80 },  /* COM7: reset (handled specially below) */

    /* CLKRC: internal prescale /4. Combined with SCALING_PCLK_DIV below
     * (/4) this gives PCLK = 16MHz/16 = 1 MHz, i.e. ~84 core cycles per
     * pixel byte -- comfortable for the polled capture loop. An earlier /8
     * here dropped the frame rate to ~1.3 fps, slow enough that a 200 ms
     * activity window often contained zero VSYNC pulses and looked like a
     * dead frame-sync line. */
    { 0x11, 0x03 },
    { 0x12, 0x00 },  /* COM7: YUV output, VGA base resolution */
    { 0x0C, 0x04 },  /* COM3: enable DCW/scaling */
    { 0x3E, 0x1A },  /* COM14: manual scaling, PCLK divided by 4 */
    { 0x70, 0x3A },  /* SCALING_XSC */
    { 0x71, 0x35 },  /* SCALING_YSC */
    { 0x72, 0x22 },  /* SCALING_DCWCTR: downsample by 4 horiz + vert */
    { 0x73, 0xF2 },  /* SCALING_PCLK_DIV: divide by 4 */
    { 0xA2, 0x02 },  /* SCALING_PCLK_DELAY */

    { 0x15, 0x00 },  /* COM10: HREF normal, PCLK free-running */
    { 0x3A, 0x04 },  /* TSLB: fixed UV ordering */
    { 0x3D, 0x88 },  /* COM13: gamma on, UV auto-adjust */
    { 0x40, 0xC0 },  /* COM15: full 0-255 output range */

    /* Windowing: standard VGA timing values. */
    { 0x17, 0x13 },  /* HSTART */
    { 0x18, 0x01 },  /* HSTOP  */
    { 0x32, 0xB6 },  /* HREF   */
    { 0x19, 0x02 },  /* VSTART */
    { 0x1A, 0x7A },  /* VSTOP  */
    { 0x03, 0x0A },  /* VREF   */

    /* Leave AGC/AWB/AEC enabled: for a functional check we want the sensor
     * to adapt to whatever light it is actually pointed at. */
    { 0x13, 0xE7 },  /* COM8: AGC + AWB + AEC enabled, fast AEC */

    /* --- image tuning ---------------------------------------------------
     * Gamma curve, AEC windowing and histogram limits, lifted from
     * erikandre/stm32-ov7670 (Petr Machala's tables), which is a working
     * OV7670 bring-up on this exact Nucleo board. Without these the Y
     * channel comes out flat and dim -- they matter for a usable preview
     * even though we only keep luma. The colour matrix entries are
     * included for completeness; they do not affect Y. */
    { 0x7A, 0x20 }, { 0x7B, 0x10 }, { 0x7C, 0x1E }, { 0x7D, 0x35 },
    { 0x7E, 0x5A }, { 0x7F, 0x69 }, { 0x80, 0x76 }, { 0x81, 0x80 },
    { 0x82, 0x88 }, { 0x83, 0x8F }, { 0x84, 0x96 }, { 0x85, 0xA3 },
    { 0x86, 0xAF }, { 0x87, 0xC4 }, { 0x88, 0xD7 }, { 0x89, 0xE8 },

    { 0x4F, 0x80 }, { 0x50, 0x80 }, { 0x51, 0x00 }, { 0x52, 0x22 },
    { 0x53, 0x5E }, { 0x54, 0x80 }, { 0x58, 0x9E },

    { 0xA5, 0x05 }, { 0xAB, 0x07 },
    { 0x24, 0x95 }, { 0x25, 0x33 }, { 0x26, 0xE3 },   /* AEW / AEB / VPT */
    { 0x9F, 0x78 }, { 0xA0, 0x68 }, { 0xA1, 0x03 },
    { 0xA6, 0xD8 }, { 0xA7, 0xD8 }, { 0xA8, 0xF0 },
    { 0xA9, 0x90 }, { 0xAA, 0x94 },
};

static int camera_configure(void)
{
    if (!sccb_write(0x12, 0x80)) return 0;   /* COM7 reset */
    delay_ms(100);

    int ok = 1;
    for (unsigned i = 1; i < sizeof(ov7670_qqvga_yuv) / sizeof(ov7670_qqvga_yuv[0]); i++) {
        ok &= sccb_write(ov7670_qqvga_yuv[i].reg, ov7670_qqvga_yuv[i].val);
    }
    delay_ms(300);   /* let AEC/AGC settle before the first capture */
    return ok;
}

/* ------------------------------------------------------------------ */
/* Diagnostics                                                         */
/* ------------------------------------------------------------------ */
static void cmd_probe(void)
{
    static const struct { uint8_t reg; const char *name; uint8_t expect; } ids[] = {
        { 0x0A, "PID ", 0x76 },
        { 0x0B, "VER ", 0x73 },
        { 0x1C, "MIDH", 0x7F },
        { 0x1D, "MIDL", 0xA2 },
    };

    print("\r\n-- SCCB probe --\r\n");
    int all_ok = 1;
    for (unsigned i = 0; i < 4; i++) {
        uint8_t v = 0;
        int ok = sccb_read(ids[i].reg, &v);
        print("  "); print(ids[i].name); print(" (0x"); print_hex8(ids[i].reg);
        print(") = 0x"); print_hex8(v);
        print("  expect 0x"); print_hex8(ids[i].expect);
        if (!ok)                    { print("   [NO ACK]");  all_ok = 0; }
        else if (v != ids[i].expect){ print("   [MISMATCH]"); all_ok = 0; }
        else                         print("   [ok]");
        print("\r\n");
    }
    print(all_ok ? "RESULT: camera responds correctly\r\n"
                 : "RESULT: FAIL -- check wiring/power/pull-ups\r\n");
}

/* Count edges on each sync signal over a fixed window. This is the same
 * question being asked of the FPGA design, answered here against a
 * known-good controller. */
static void cmd_activity(void)
{
    /* Long enough to contain several frames even at the low frame rate the
     * divided PCLK produces -- otherwise VSYNC can read as zero on a
     * perfectly healthy camera. */
    const uint32_t window_ms = 1500;
    uint32_t pclk_edges = 0, href_edges = 0, vsync_edges = 0;

    uint32_t a = GPIO_IDR(GPIOA_BASE);
    int p_prev = (a >> PIN_PCLK) & 1, h_prev = (a >> PIN_HREF) & 1,
        v_prev = (a >> PIN_VSYNC) & 1;

    uint32_t start = cycles();
    uint32_t want  = window_ms * (SYSCLK_HZ / 1000U);
    while ((cycles() - start) < want) {
        uint32_t s = GPIO_IDR(GPIOA_BASE);
        int p = (s >> PIN_PCLK) & 1, h = (s >> PIN_HREF) & 1, v = (s >> PIN_VSYNC) & 1;
        if (p && !p_prev) pclk_edges++;
        if (h && !h_prev) href_edges++;
        if (v && !v_prev) vsync_edges++;
        p_prev = p; h_prev = h; v_prev = v;
    }

    print("\r\n-- signal activity over "); print_u32(window_ms); print(" ms --\r\n");
    print("  PCLK  rising edges: "); print_u32(pclk_edges);
    print(pclk_edges ? "\r\n" : "   [DEAD -- no pixel clock]\r\n");
    print("  HREF  rising edges: "); print_u32(href_edges);
    print(href_edges ? "  (lines)\r\n" : "   [DEAD -- no line sync]\r\n");
    print("  VSYNC rising edges: "); print_u32(vsync_edges);
    print(vsync_edges ? "  (frames)\r\n" : "   [DEAD -- no frame sync]\r\n");
    print("  note: PCLK is sampled by polling, so its count is a lower\r\n"
          "        bound -- 0 vs non-zero is the meaningful result.\r\n");
}

static void cmd_regdump(void)
{
    print("\r\n-- register dump 0x00..0x3F --\r\n");
    for (uint8_t r = 0; r < 0x40; r++) {
        uint8_t v = 0;
        sccb_read(r, &v);
        if ((r & 0x0F) == 0) { print("  "); print_hex8(r); print(": "); }
        print_hex8(v); putc_raw(' ');
        if ((r & 0x0F) == 0x0F) print("\r\n");
    }
}

/* ------------------------------------------------------------------ */
/* Frame capture                                                       */
/* ------------------------------------------------------------------ */
/* Every loop is cycle-bounded. Returns 0 on success, or a small error code
 * naming the stage that timed out, so a failure says *where* it failed
 * rather than just hanging. */
#define ERR_VSYNC_HIGH  1
#define ERR_VSYNC_LOW   2
#define ERR_HREF        3
#define ERR_PCLK        4

/* Frame budget is deliberately generous: the divided-down PCLK above puts
 * the sensor at only a few frames per second, so a frame period is
 * hundreds of ms. Timing out faster than one frame period would report a
 * healthy camera as broken. */
#define TMO_FRAME_CY    (SYSCLK_HZ * 3)   /* 3 s    */
#define TMO_LINE_CY     (SYSCLK_HZ / 20)  /* 50 ms  */
#define TMO_PIX_CY      (SYSCLK_HZ / 1000)/* 1 ms   */

static inline int pin_pclk(void)  { return (GPIO_IDR(GPIOA_BASE) >> PIN_PCLK)  & 1U; }
static inline int pin_vsync(void) { return (GPIO_IDR(GPIOA_BASE) >> PIN_VSYNC) & 1U; }
static inline int pin_href(void)  { return (GPIO_IDR(GPIOA_BASE) >> PIN_HREF)  & 1U; }

#define WAIT_UNTIL(cond, budget, errcode)                 \
    do {                                                  \
        uint32_t _t0 = cycles();                          \
        while (!(cond)) {                                 \
            if ((cycles() - _t0) > (budget)) return (errcode); \
        }                                                 \
    } while (0)

static int capture_frame(uint32_t *out_bytes)
{
    /* Sync to a frame boundary: wait for VSYNC to go high (blanking) and
     * then fall, so capture starts at the very top of a frame rather than
     * mid-image. */
    WAIT_UNTIL(pin_vsync(),  TMO_FRAME_CY, ERR_VSYNC_HIGH);
    WAIT_UNTIL(!pin_vsync(), TMO_FRAME_CY, ERR_VSYNC_LOW);

    uint32_t idx = 0;
    for (uint32_t line = 0; line < FRAME_H; line++) {
        WAIT_UNTIL(pin_href(), TMO_LINE_CY, ERR_HREF);

        for (uint32_t b = 0; b < FRAME_W * BYTES_PER_PIX; b++) {
            /* Sample on the PCLK rising edge, as the sensor drives data on
             * the falling edge. */
            WAIT_UNTIL(pin_pclk(),  TMO_PIX_CY, ERR_PCLK);
            framebuf[idx++] = (uint8_t)(GPIO_IDR(GPIOC_BASE) & 0xFFU);
            WAIT_UNTIL(!pin_pclk(), TMO_PIX_CY, ERR_PCLK);
        }

        /* Let the rest of the line drain so the next HREF edge is clean. */
        uint32_t t0 = cycles();
        while (pin_href() && (cycles() - t0) < TMO_LINE_CY) { }
    }

    *out_bytes = idx;
    return 0;
}

static void cmd_capture(void)
{
    uint32_t n = 0;
    print("\r\n-- capture --\r\n");

    int err = capture_frame(&n);
    if (err) {
        print("CAPTURE FAILED at stage ");
        print_u32((uint32_t)err);
        print(err == ERR_VSYNC_HIGH || err == ERR_VSYNC_LOW
                  ? " (VSYNC never toggled)\r\n"
              : err == ERR_HREF ? " (HREF never asserted)\r\n"
                                : " (PCLK stalled mid-line)\r\n");
        print("Run 'a' to see which signals are moving at all.\r\n");
        return;
    }

    /* Framed binary payload. The magic line lets the host resynchronise
     * even if it connected mid-stream and saw partial text. */
    print("FRAME ");
    print_u32(FRAME_W); putc_raw('x'); print_u32(FRAME_H);
    putc_raw(' '); print_u32(n); print(" YUV422\r\n");

    uint32_t sum = 0;
    for (uint32_t i = 0; i < n; i++) { putc_raw(framebuf[i]); sum += framebuf[i]; }

    print("\r\nENDFRAME sum="); print_u32(sum); print("\r\n");
}

/* Continuous streaming. Sends only the luma byte of each YUV422 pair, which
 * halves the bytes on the wire (19200 instead of 38400) and so roughly
 * doubles the achievable frame rate -- and luma is all the grayscale
 * comparison against the FPGA pipeline needs anyway. Use 'c' when the raw
 * chroma-interleaved pairs are actually wanted.
 *
 * The luma phase is resolved once, here, rather than per frame: it is a
 * property of the sensor's TSLB/COM13 ordering and cannot change between
 * frames, and re-deciding it per frame would risk the phase flipping
 * mid-stream and producing a garbage frame. */
static void cmd_stream(void)
{
    uint32_t n = 0;

    print("\r\n-- streaming (send any character to stop) --\r\n");

    /* Grab one frame to decide the phase, scoring exactly the way the host
     * does: real luma is strongly correlated between horizontal neighbours,
     * chroma read as luma is not. */
    if (capture_frame(&n) != 0) {
        print("STREAM ABORT: first capture failed; run 'a' to check signals\r\n");
        return;
    }
    uint32_t diff[2] = { 0, 0 };
    for (uint32_t p = 0; p < 2; p++) {
        for (uint32_t i = p; i + 2 < n; i += 2) {
            int d = (int)framebuf[i + 2] - (int)framebuf[i];
            diff[p] += (uint32_t)(d < 0 ? -d : d);
        }
    }
    uint32_t phase = (diff[0] <= diff[1]) ? 0 : 1;

    print("phase="); print_u32(phase); print("\r\n");

    for (;;) {
        if (USART_SR & (1U << 5)) { (void)USART_DR; break; }   /* key pressed */

        int err = capture_frame(&n);
        if (err) {
            print("SKIP "); print_u32((uint32_t)err); print("\r\n");
            continue;
        }

        print("YFRAME ");
        print_u32(FRAME_W); putc_raw('x'); print_u32(FRAME_H);
        putc_raw(' '); print_u32(FRAME_W * FRAME_H); print("\r\n");

        for (uint32_t i = phase; i < n; i += 2) putc_raw(framebuf[i]);
    }

    print("\r\n-- stream stopped --\r\n");
}

/* Measure the frame geometry the sensor is ACTUALLY producing, rather than
 * the geometry the register table was supposed to select. A mismatch here
 * is the classic cause of an image that looks sheared or rotated: if the
 * consumer assumes N bytes per line and the sensor emits M, every line
 * starts at the wrong offset and the picture walks sideways.
 *
 * Counts PCLK cycles while HREF is asserted (bytes per line) and HREF
 * pulses between VSYNC edges (lines per frame). */
static void cmd_geometry(void)
{
    print("\r\n-- measured frame geometry --\r\n");

    /* Start of a frame. */
    uint32_t t0 = cycles();
    while (!pin_vsync())  { if (cycles() - t0 > TMO_FRAME_CY) { print("  VSYNC timeout\r\n"); return; } }
    t0 = cycles();
    while (pin_vsync())   { if (cycles() - t0 > TMO_FRAME_CY) { print("  VSYNC stuck high\r\n"); return; } }

    uint32_t lines = 0, first_line_bytes = 0, max_bytes = 0, min_bytes = 0xFFFFFFFFU;

    for (;;) {
        /* Wait for the next HREF, but stop if the frame ends first. */
        uint32_t t = cycles();
        while (!pin_href()) {
            if (pin_vsync()) goto done;
            if (cycles() - t > TMO_FRAME_CY) goto done;
        }

        uint32_t bytes = 0;
        while (pin_href()) {
            /* One count per PCLK rising edge inside HREF = one byte. */
            uint32_t tp = cycles();
            while (pin_pclk() && pin_href()) { if (cycles() - tp > TMO_PIX_CY) break; }
            tp = cycles();
            while (!pin_pclk() && pin_href()) { if (cycles() - tp > TMO_PIX_CY) break; }
            if (pin_href()) bytes++;
        }

        if (bytes) {
            if (!lines) first_line_bytes = bytes;
            if (bytes > max_bytes) max_bytes = bytes;
            if (bytes < min_bytes) min_bytes = bytes;
            lines++;
        }
        if (lines > 1000) break;   /* runaway guard */
    }

done:
    print("  lines per frame : "); print_u32(lines); print("\r\n");
    print("  bytes per line  : first="); print_u32(first_line_bytes);
    print(" min="); print_u32(min_bytes == 0xFFFFFFFFU ? 0 : min_bytes);
    print(" max="); print_u32(max_bytes); print("\r\n");
    print("  -> pixels/line (YUV422, 2 bytes each): ");
    print_u32(first_line_bytes / 2); print("\r\n");
    print("  firmware assumes "); print_u32(FRAME_W); print("x"); print_u32(FRAME_H);
    print(" i.e. "); print_u32(FRAME_W * BYTES_PER_PIX); print(" bytes/line\r\n");
}

/* ------------------------------------------------------------------ */
static void banner(void)
{
    print("\r\n============================================\r\n");
    print(" OV7670 tester -- STM32F446RE @ 84 MHz\r\n");
    print(" XCLK=PA8(16MHz) PCLK=PA9 VSYNC=PA10 HREF=PA11\r\n");
    print(" D0-D7=PC0-PC7  SIOC=PB8 SIOD=PB9\r\n");
    print(" PWDN->GND  RESET#->3V3 (strapped in hardware)\r\n");
    print("============================================\r\n");
    print("commands: p=probe  a=activity  r=regdump  c=capture  s=stream  g=geometry  h=help\r\n");
}

int main(void)
{
    clock_init();
    cyccnt_init();
    gpio_init();
    uart_init();

    delay_ms(100);
    banner();

    print("\r\nconfiguring camera... ");
    int cfg = camera_configure();
    print(cfg ? "ok\r\n" : "NO ACK (camera not responding)\r\n");

    cmd_probe();
    print("\r\nready> ");

    for (;;) {
        uint8_t c;
        if (!uart_getc_timeout(1000, &c)) continue;
        switch (c) {
        case 'p': cmd_probe();    break;
        case 'a': cmd_activity(); break;
        case 'r': cmd_regdump();  break;
        case 'c': cmd_capture();  break;
        case 's': cmd_stream();   break;
        case 'g': cmd_geometry(); break;
        case 'h': banner();       break;
        default:  continue;
        }
        print("\r\nready> ");
    }
}

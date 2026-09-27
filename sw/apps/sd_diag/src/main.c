/*
 * Test: does a fresh CfgInitialize+CardInitialize succeed on the SECOND
 * attempt in the same boot, even though the first attempt fails? If so,
 * the controller needs some kind of reset/settle after a failed attempt,
 * not just inter-command delay.
 */
#include "xil_cache.h"
#include "xil_printf.h"
#include "xsdps.h"
#include "xstatus.h"

static XSdPs Sd1, Sd2, Sd3;

int main(void)
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();

    xil_printf("\r\n=== sd_diag retry-from-scratch test: start ===\r\n");

    XSdPs_Config *cfg = XSdPs_LookupConfig(0xe0100000);
    if (cfg == NULL) {
        xil_printf("FAIL: no config\r\n");
        goto done;
    }

    s32 status;

    status = XSdPs_CfgInitialize(&Sd1, cfg, cfg->BaseAddress);
    xil_printf("Attempt 1: CfgInitialize status=%d\r\n", (int)status);
    status = XSdPs_CardInitialize(&Sd1);
    xil_printf("Attempt 1: CardInitialize status=%d\r\n", (int)status);

    status = XSdPs_CfgInitialize(&Sd2, cfg, cfg->BaseAddress);
    xil_printf("Attempt 2: CfgInitialize status=%d\r\n", (int)status);
    status = XSdPs_CardInitialize(&Sd2);
    xil_printf("Attempt 2: CardInitialize status=%d\r\n", (int)status);

    status = XSdPs_CfgInitialize(&Sd3, cfg, cfg->BaseAddress);
    xil_printf("Attempt 3: CfgInitialize status=%d\r\n", (int)status);
    status = XSdPs_CardInitialize(&Sd3);
    xil_printf("Attempt 3: CardInitialize status=%d\r\n", (int)status);

done:
    xil_printf("=== done ===\r\n");
    Xil_DCacheDisable();
    Xil_ICacheDisable();
    while (1) {
    }
    return 0;
}

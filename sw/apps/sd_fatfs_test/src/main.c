/*
 * SD card bring-up test: mount SD0, write a file, read it back, verify.
 * empty_application template does not generate platform.h, so cache
 * enable/disable is done here directly (per Vitis 2026.1 SDT flow note).
 */
#include <string.h>
#include "xil_cache.h"
#include "xil_printf.h"
#include "ff.h"

static const char test_string[] = "stereo_cam SD bring-up test payload 0123456789\r\n";

int main(void)
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();

    xil_printf("\r\n=== sd_fatfs_test: start ===\r\n");

    FATFS fatfs;
    FRESULT res = f_mount(&fatfs, "0:/", 1);
    if (res != FR_OK) {
        xil_printf("FAIL: f_mount error %d\r\n", res);
        goto done;
    }
    xil_printf("PASS: f_mount ok\r\n");

    FIL fil;
    res = f_open(&fil, "0:/scam_tst.txt", FA_CREATE_ALWAYS | FA_WRITE);
    if (res != FR_OK) {
        xil_printf("FAIL: f_open(write) error %d\r\n", res);
        goto unmount;
    }

    UINT bw = 0;
    res = f_write(&fil, test_string, sizeof(test_string) - 1, &bw);
    f_close(&fil);
    if (res != FR_OK || bw != sizeof(test_string) - 1) {
        xil_printf("FAIL: f_write error %d, wrote %u/%u bytes\r\n",
                   res, bw, (unsigned)(sizeof(test_string) - 1));
        goto unmount;
    }
    xil_printf("PASS: f_write ok (%u bytes)\r\n", bw);

    char readback[64];
    memset(readback, 0, sizeof(readback));
    res = f_open(&fil, "0:/scam_tst.txt", FA_READ);
    if (res != FR_OK) {
        xil_printf("FAIL: f_open(read) error %d\r\n", res);
        goto unmount;
    }

    UINT br = 0;
    res = f_read(&fil, readback, sizeof(readback) - 1, &br);
    f_close(&fil);
    if (res != FR_OK) {
        xil_printf("FAIL: f_read error %d\r\n", res);
        goto unmount;
    }

    if (br == sizeof(test_string) - 1 &&
        memcmp(readback, test_string, br) == 0) {
        xil_printf("PASS: read-back matches written data (%u bytes)\r\n", br);
        xil_printf("=== sd_fatfs_test: ALL TESTS PASSED ===\r\n");
    } else {
        xil_printf("FAIL: read-back mismatch (%u bytes): \"%s\"\r\n", br, readback);
    }

unmount:
    f_mount(NULL, "0:/", 0);
done:
    Xil_DCacheDisable();
    Xil_ICacheDisable();
    while (1) {
        /* park here so xsdb can distinguish clean completion from a hang */
    }
    return 0;
}

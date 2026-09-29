/* Minimal STM32F446RE startup: vector table, .data/.bss init, call main().
 * Deliberately CMSIS-free so this firmware builds with nothing but
 * arm-none-eabi-gcc -- no vendor headers to install or version-match. */
#include <stdint.h>

extern uint32_t _etext, _sdata, _edata, _sbss, _ebss, _estack;

int main(void);

void Reset_Handler(void)
{
    uint32_t *src = &_etext;
    for (uint32_t *dst = &_sdata; dst < &_edata; ) *dst++ = *src++;
    for (uint32_t *dst = &_sbss;  dst < &_ebss;  ) *dst++ = 0;
    main();
    for (;;) { }
}

/* Any unexpected exception parks here. If the debugger ever shows the core
 * stopped in this function, it means a fault fired -- not that the program
 * finished. */
void Default_Handler(void) { for (;;) { } }

#define ALIAS __attribute__((weak, alias("Default_Handler")))
ALIAS void NMI_Handler(void);
ALIAS void HardFault_Handler(void);
ALIAS void MemManage_Handler(void);
ALIAS void BusFault_Handler(void);
ALIAS void UsageFault_Handler(void);
ALIAS void SVC_Handler(void);
ALIAS void DebugMon_Handler(void);
ALIAS void PendSV_Handler(void);
ALIAS void SysTick_Handler(void);

__attribute__((section(".isr_vector"), used))
void (* const g_vectors[])(void) = {
    (void (*)(void))&_estack,
    Reset_Handler,
    NMI_Handler,
    HardFault_Handler,
    MemManage_Handler,
    BusFault_Handler,
    UsageFault_Handler,
    0, 0, 0, 0,
    SVC_Handler,
    DebugMon_Handler,
    0,
    PendSV_Handler,
    SysTick_Handler,
};

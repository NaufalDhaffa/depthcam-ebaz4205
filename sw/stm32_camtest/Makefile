# OV7670 tester for Nucleo-F446RE. No vendor SDK: plain arm-none-eabi-gcc.
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size

TARGET   = camtest
SRCS     = startup.c main.c

CPUFLAGS = -mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=hard
CFLAGS   = $(CPUFLAGS) -O2 -g3 -std=c11 -Wall -Wextra \
           -ffunction-sections -fdata-sections -fno-common
LDFLAGS  = $(CPUFLAGS) -T stm32f446.ld -nostartfiles \
           -Wl,--gc-sections -Wl,-Map=$(TARGET).map --specs=nosys.specs

all: $(TARGET).elf $(TARGET).bin

$(TARGET).elf: $(SRCS) stm32f446.ld
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRCS) -o $@
	$(SIZE) $@

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

# ST-LINK/V2-1 on the Nucleo, via openocd.
flash: $(TARGET).elf
	openocd -f interface/stlink.cfg -f target/stm32f4x.cfg \
	        -c "program $(TARGET).elf verify reset exit"

clean:
	rm -f $(TARGET).elf $(TARGET).bin $(TARGET).map

.PHONY: all flash clean

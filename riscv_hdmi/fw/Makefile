# Firmware for the AE350 hard RISC-V core.
#
#   make            -> firmware.elf/.bin + the boot_rom.vh the FPGA build reads
#   make CROSS=...  -> use a different toolchain prefix
#
# The output lands in ../eda_proj/src/boot_rom.vh, which boot_rom.v pulls in
# with $readmemh, so the program ends up inside the bitstream.

TOOLCHAIN ?= F:/riscv/xpack-riscv-none-elf-gcc-15.2.0-1/bin
CROSS     ?= $(TOOLCHAIN)/riscv-none-elf-

CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE    := $(CROSS)size

# AndesCore A25: RV32 with M (mul/div), A (atomics) and C (compressed).
ARCH  := -march=rv32imac_zicsr -mabi=ilp32
FLAGS := -Os -g -ffreestanding -fno-builtin -ffunction-sections -fdata-sections \
         -Wall -Wextra
LDFLAGS := -nostdlib -nostartfiles -T ae350.ld -Wl,--gc-sections -Wl,-Map=firmware.map

OBJS := start.o main.o
ROMVH := ../eda_proj/src/boot_rom.vh

all: firmware.bin $(ROMVH)

start.o: start.S
	$(CC) $(ARCH) $(FLAGS) -c $< -o $@

main.o: main.c ae350.h
	$(CC) $(ARCH) $(FLAGS) -c $< -o $@

firmware.elf: $(OBJS) ae350.ld
	$(CC) $(ARCH) $(FLAGS) $(LDFLAGS) $(OBJS) -o $@
	$(SIZE) $@

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@

firmware.lst: firmware.elf
	$(OBJDUMP) -d -S $< > $@

$(ROMVH): firmware.bin ../tools/bin2vh.py
	python ../tools/bin2vh.py $< $@ --words 4096

clean:
	rm -f *.o *.elf *.bin *.lst *.map $(ROMVH)

.PHONY: all clean

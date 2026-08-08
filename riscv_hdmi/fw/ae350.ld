/*
 * Link map for the AE350 stage-1 firmware.
 *
 *   IMEM - the fabric boot ROM on the core's instruction-memory port. The
 *          AE350 maps this region at 0x80000000 and starts fetching there,
 *          so .text.init (the reset entry) must come first.
 *   DRAM - fabric RAM (data_ram.v) on the core's ddr/sram port, which serves
 *          the data-memory region at 0x00000000. Holds .data/.bss/stack;
 *          .data is stored in the ROM image and copied there by start.S.
 *
 * The core-internal DLM at 0xA0200000 is deliberately NOT used: a hardware
 * store/readback test showed it is not present in this configuration.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
	IMEM (rx)  : ORIGIN = 0x80000000, LENGTH = 16K	/* must match boot_rom AW */
	DRAM (rw)  : ORIGIN = 0x00000000, LENGTH = 32K	/* must match data_ram AW */
}

SECTIONS
{
	.text : {
		KEEP(*(.text.init))		/* reset vector - keep at offset 0 */
		*(.text .text.*)
		*(.rodata .rodata.*)
		*(.srodata .srodata.*)
		. = ALIGN(4);
	} > IMEM

	__data_load = LOADADDR(.data);

	.data : {
		__data_start = .;
		*(.data .data.*)
		*(.sdata .sdata.*)
		. = ALIGN(4);
		__data_end = .;
	} > DRAM AT > IMEM

	.bss (NOLOAD) : {
		__bss_start = .;
		*(.sbss .sbss.*)
		*(.bss .bss.*)
		*(COMMON)
		. = ALIGN(4);
		__bss_end = .;
	} > DRAM

	/* gp covers .sdata/.sbss with signed 12-bit offsets */
	__global_pointer$ = MIN(__data_start + 0x800, __bss_end - 0x800);

	/* stack grows down from the top of the fabric data RAM */
	__stack_top = ORIGIN(DRAM) + LENGTH(DRAM);

	/DISCARD/ : { *(.eh_frame .eh_frame.*) *(.comment) }
}

/*
 * Reset entry for the AE350 hard core.
 *
 * The core starts executing at the base of its instruction-memory region
 * (0x80000000), which the fabric boot ROM answers - so this must be the very
 * first word of the linked image (see ae350.ld, section .text.init).
 *
 * Data lives in fabric RAM (data_ram.v) at 0x00000000, reached over the core's
 * ddr/sram AHB port. The core-internal DLM at 0xA0200000 is NOT used: a
 * hardware store/readback test showed that memory is absent in this
 * configuration, so the earlier version's CSR-enable + stack there could
 * never have worked.
 */

	.section .text.init, "ax"
	.global _start
	.type   _start, @function

_start:
	/* no interrupts during bring-up */
	csrw    mie, zero
	csrw    mip, zero

	/*
	 * Turn the instruction cache on. Both caches come out of reset DISABLED
	 * (mcache_ctl = 0x7CA, IC_EN bit 0 / DC_EN bit 1, initial value 0 - see
	 * the Cache chapter of MUG1029), so every instruction was being fetched
	 * from fabric BSRAM over AHB and the core ran ~65x slower than its clock.
	 *
	 * Only IC_EN for now: the data cache would also cover the peripheral
	 * region, and stale UART/GPIO accesses are not worth the risk yet.
	 */
	li      t0, 1
	csrw    0x7CA, t0

	/* stack at the top of the fabric data RAM, 16-byte aligned */
	la      sp, __stack_top

	/* global pointer, for gp-relative addressing */
.option push
.option norelax
	la      gp, __global_pointer$
.option pop

	/* .bss lives in the DLM and is not loaded by any bootloader - clear it */
	la      t0, __bss_start
	la      t1, __bss_end
1:
	bgeu    t0, t1, 2f
	sw      zero, 0(t0)
	addi    t0, t0, 4
	j       1b
2:

	/* .data is linked into the ROM image but must run from the DLM - copy it */
	la      t0, __data_load
	la      t1, __data_start
	la      t2, __data_end
3:
	bgeu    t1, t2, 4f
	lw      t3, 0(t0)
	sw      t3, 0(t1)
	addi    t0, t0, 4
	addi    t1, t1, 4
	j       3b
4:

	call    main

	/* main() should never return; park the core if it does */
hang:
	wfi
	j       hang

	.size   _start, . - _start

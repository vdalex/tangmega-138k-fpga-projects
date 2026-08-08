/*
 * Absolute-minimum bring-up program for the AE350 hard core.
 *
 * This exists to answer one question with no ambiguity: does the CPU execute
 * our instructions at all? It therefore avoids EVERYTHING that could fault
 * before reaching the visible part:
 *
 *   - no stack, no function calls          (no data memory needed)
 *   - no CSR writes                        (start.S pokes milmb/mdlmb, which
 *                                           trap if those local memories are
 *                                           not present in this configuration)
 *   - no .data / .bss setup, no UART
 *
 * The only memory it touches is the GPIO peripheral, and the only control
 * flow is two delay loops. If the LED blinks, the core is genuinely running
 * our code and the problem is in the C startup path; if it does not, the
 * fault is still upstream of the first instruction.
 */

	.equ GPIO_BASE,   0xF0700000
	.equ GPIO_DATAOUT, 0x24
	.equ GPIO_DIR,     0x28

	.section .text.init, "ax"
	.global _start
	.type   _start, @function

_start:
	li      t0, GPIO_BASE
	li      t1, 1
	sw      t1, GPIO_DIR(t0)		/* bit 0 = output */

loop:
	sw      t1, GPIO_DATAOUT(t0)	/* LED on  */
	li      t2, 0x1000000
1:	addi    t2, t2, -1
	bnez    t2, 1b

	sw      zero, GPIO_DATAOUT(t0)	/* LED off */
	li      t2, 0x1000000
2:	addi    t2, t2, -1
	bnez    t2, 2b

	j       loop

	.size   _start, . - _start

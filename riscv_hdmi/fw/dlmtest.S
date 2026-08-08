/*
 * Does this core actually have usable data memory (DLM)?
 *
 * The C firmware puts its stack in the DLM at 0xA0200000 and start.S enables
 * it through the AndeStar CSRs - but "DTCM Data Memory" is listed as disabled
 * by default in the AE350 configuration table, so that memory may simply not
 * exist here. Everything in the C path (stack, .bss, .data, function calls)
 * depends on the answer, so establish it directly.
 *
 * Still no stack and no function calls: only GPIO writes, one CSR write and
 * one store/load pair. The LED reports the result:
 *
 *   3 quick blinks, then FAST blinking  -> DLM works, C firmware can run
 *   3 quick blinks, then SLOW blinking  -> DLM readback failed
 *   LED frozen after fewer than 3 blinks -> the CSR write itself trapped
 *
 * Delays are calibrated to the measured speed of this system: 16.7M loop
 * iterations took ~11 s, i.e. roughly 1.5M iterations per second.
 */

	.equ GPIO_BASE,    0xF0700000
	.equ GPIO_DATAOUT, 0x24
	.equ GPIO_DIR,     0x28

	.equ DLM_BASE,     0xA0200000
	.equ CSR_MDLMB,    0x7C1

	.equ D_QUICK,      0x30000		/* ~0.13 s */
	.equ D_FAST,       0x60000		/* ~0.25 s */
	.equ D_SLOW,       0x400000		/* ~2.8 s  */

	.section .text.init, "ax"
	.global _start
	.type   _start, @function

/* s0 = GPIO base, s1 = 1 (kept live throughout; no stack anywhere) */
_start:
	li      s0, GPIO_BASE
	li      s1, 1
	sw      s1, GPIO_DIR(s0)

	/* --- 3 quick blinks: "I got this far" --- */
	li      s2, 3
blink3:
	sw      s1, GPIO_DATAOUT(s0)
	li      t2, D_QUICK
1:	addi    t2, t2, -1
	bnez    t2, 1b
	sw      zero, GPIO_DATAOUT(s0)
	li      t2, D_QUICK
2:	addi    t2, t2, -1
	bnez    t2, 2b
	addi    s2, s2, -1
	bnez    s2, blink3

	/* --- enable the DLM, then store and read back --- */
	li      t0, DLM_BASE | 1
	csrw    CSR_MDLMB, t0			/* traps here if the CSR is absent */

	li      t0, DLM_BASE
	li      t1, 0xDEADBEEF
	sw      t1, 0(t0)
	lw      t3, 0(t0)

	li      s3, D_FAST
	beq     t1, t3, report			/* match -> fast */
	li      s3, D_SLOW				/* mismatch -> slow */

	/* --- report forever at the chosen rate --- */
report:
	sw      s1, GPIO_DATAOUT(s0)
	mv      t2, s3
3:	addi    t2, t2, -1
	bnez    t2, 3b
	sw      zero, GPIO_DATAOUT(s0)
	mv      t2, s3
4:	addi    t2, t2, -1
	bnez    t2, 4b
	j       report

	.size   _start, . - _start

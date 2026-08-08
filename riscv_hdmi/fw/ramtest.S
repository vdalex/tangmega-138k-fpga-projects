/*
 * Does the fabric data RAM (data_ram.v, on the core's ddr/sram port) actually
 * store and return data?
 *
 * The C firmware needs it for its stack, and a stack exercises the awkward
 * case straight away: store, then load the same word back a cycle later. So
 * test exactly that, plus a byte write, without using a stack to do it.
 *
 * LED report:
 *   3 quick blinks, then FAST  -> word and byte accesses both good
 *   3 quick blinks, then SLOW  -> readback wrong; the RAM is at fault
 *   frozen before 3 blinks     -> the store itself hung the bus
 *
 * Calibrated to the measured speed of this system (~1.5M loop iterations/s).
 */

	.equ GPIO_BASE,    0xF0700000
	.equ GPIO_DATAOUT, 0x24
	.equ GPIO_DIR,     0x28

	.equ RAM_ADDR,     0x00001000

	.equ D_QUICK,      0x30000		/* ~0.13 s */
	.equ D_FAST,       0x60000		/* ~0.25 s */
	.equ D_SLOW,       0x400000		/* ~2.8 s  */

	.section .text.init, "ax"
	.global _start
	.type   _start, @function

_start:
	li      s0, GPIO_BASE
	li      s1, 1
	sw      s1, GPIO_DIR(s0)

	/* --- 3 quick blinks: reached the test --- */
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

	li      s3, D_SLOW				/* assume failure until proven otherwise */
	li      s4, RAM_ADDR

	/* --- word store then immediate load back (the stack pattern) --- */
	li      t1, 0xDEADBEEF
	sw      t1, 0(s4)
	lw      t3, 0(s4)
	bne     t1, t3, report

	/* --- a second word, to catch an address that is ignored --- */
	li      t1, 0x12345678
	sw      t1, 4(s4)
	lw      t3, 4(s4)
	bne     t1, t3, report

	/* --- the first word must still hold its own value --- */
	li      t1, 0xDEADBEEF
	lw      t3, 0(s4)
	bne     t1, t3, report

	/* --- byte write must touch one lane only --- */
	li      t1, 0xA5
	sb      t1, 0(s4)
	lw      t3, 0(s4)
	li      t1, 0xDEADBEA5
	bne     t1, t3, report

	li      s3, D_FAST				/* everything checked out */

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

/*
 * Stage 1 firmware for the AE350 hard RISC-V core on the Tang Mega 138K.
 *
 * Prints a greeting and a description of the scene to two places at once: the
 * serial console on UART2 (115200 8N1, over the board's BL616 bridge) and a
 * 120x33 text screen on HDMI that the fabric scans out at 1920x1080. Then it
 * blinks the LED forever. The blink matters: it is proof that the core is
 * running our code even if neither output is configured correctly.
 */
#include "ae350.h"

/* ---------------- UART ---------------- */

static void uart_init(void)
{
	/* set the baud divisor behind DLAB, then latch 8N1 */
	REG32(UART2_BASE + UART_OFF_LCR) = UART_LCR_DLAB;
	REG32(UART2_BASE + UART_OFF_RBR) = UART_DIVISOR & 0xFF;
	REG32(UART2_BASE + UART_OFF_IER) = (UART_DIVISOR >> 8) & 0xFF;
	REG32(UART2_BASE + UART_OFF_LCR) = UART_LCR_8N1;

	/* no interrupts, FIFOs on and flushed */
	REG32(UART2_BASE + UART_OFF_IER) = 0;
	REG32(UART2_BASE + UART_OFF_FCR) =
		UART_FCR_FIFOEN | UART_FCR_RXRST | UART_FCR_TXRST;
}

/*
 * Bounded wait for THRE. During bring-up an unresponsive UART must never be
 * able to wedge the CPU: the original unbounded spin sat in a handful of
 * cached instructions, so the core looked completely dead - no bus traffic,
 * no LED, nothing. Give up after a while and keep going instead.
 */
static void uart_putc(char c)
{
	uint32_t guard = 200000u;

	if (c == '\n')
		uart_putc('\r');

	while (!(REG32(UART2_BASE + UART_OFF_LSR) & UART_LSR_THRE))
		if (--guard == 0)
			return;

	REG32(UART2_BASE + UART_OFF_RBR) = (uint8_t)c;
}

/* ---------------- HDMI text console ---------------- */

/*
 * A 120x33 character screen in fabric RAM, scanned out as 1920x1080 by
 * text_video.v. Writing a byte here puts a glyph on the display; there is no
 * scrolling and no reading back, which keeps both sides trivial.
 */
static int scr_row, scr_col;
static int scr_top;			/* first row the text may wrap back onto */

static void scr_clear_row(int r)
{
	int c;

	for (c = 0; c < TEXT_COLS; c++)
		REG8(TEXT_CELL(r, c)) = ' ';
}

static void scr_clear(void)
{
	int r;

	for (r = 0; r < TEXT_ROWS; r++)
		scr_clear_row(r);

	scr_row = 0;
	scr_col = 0;
	scr_top = 0;
}

/*
 * Move to the start of the next line, and blank it before anything is written
 * there. At the bottom of the screen the cursor wraps back to scr_top instead
 * of scrolling: scrolling would mean reading the buffer back, and the video
 * side owns the only read port. Setting scr_top past the banner keeps the
 * banner on screen while the heartbeat cycles through the space below it.
 */
static void scr_newline(void)
{
	scr_col = 0;
	scr_row = (scr_row + 1 < TEXT_ROWS) ? (scr_row + 1) : scr_top;
	scr_clear_row(scr_row);
}

static void scr_putc(char ch)
{
	if (ch == '\r')
		return;

	if (ch == '\n') {
		scr_newline();
		return;
	}

	/* wrap at the right edge, like the terminal does */
	if (scr_col >= TEXT_COLS)
		scr_newline();

	REG8(TEXT_CELL(scr_row, scr_col)) = (uint8_t)ch;
	scr_col++;
}

/* ---------------- both outputs at once ---------------- */

static void putc_both(char c)
{
	uart_putc(c);
	scr_putc(c);
}

static void puts_both(const char *s)
{
	while (*s)
		putc_both(*s++);
}

/* ---------------- GPIO ---------------- */

static void led_init(void)
{
	REG32(GPIO_BASE + GPIO_OFF_CHANNELDIR) = 0x1;	/* bit 0 = output */
}

static void led_set(int on)
{
	REG32(GPIO_BASE + GPIO_OFF_DATAOUT) = on ? 0x1 : 0x0;
}

/* Rough delay: the core runs at 800 MHz, but the loop is bounded by whatever
 * the compiler emits, so this is only ever "about half a second". */
static void delay(volatile uint32_t n)
{
	while (n--)
		__asm__ volatile ("nop");
}

/* ---------------- scene ---------------- */

static void print_banner(void)
{
	puts_both(
		"\n"
		"=====================================================\n"
		"  Tang Mega 138K  -  hard RISC-V (AE350) is alive!\n"
		"=====================================================\n"
		"\n"
		"  Vitannia! Hello from an AndesCore A25 running as a\n"
		"  HARD block inside the Gowin GW5AST-138C - it costs\n"
		"  zero LUTs and zero registers of the FPGA fabric.\n"
		"\n");

	puts_both(
		"  The scene\n"
		"  ---------\n"
		"  * core      : AndesCore A25, 800 MHz, RV32\n"
		"  * buses     : AHB 100 MHz, APB 100 MHz, RTC 10 MHz\n"
		"  * this code : fabric BSRAM at 0x80000000, baked\n"
		"                straight into the bitstream - no\n"
		"                debugger, no SPI-flash programming\n"
		"  * data      : fabric RAM at 0x00000000 - stack and .bss.\n"
		"                This core has no usable DLM, and the ddr/sram\n"
		"                port it arrives on is 64 bits wide\n"
		"  * console   : UART2 at 0xF0300000, 115200 8N1,\n"
		"                out through the on-board BL616 bridge\n"
		"  * screen    : this same text, 120x33 characters, written\n"
		"                to fabric RAM at 0x00010000 and scanned out\n"
		"                as 1920x1080@60 HDMI - if you are reading it\n"
		"                on a TV, the CPU put it there\n"
		"  * LED       : GPIO bit 0 - the heartbeat below\n"
		"\n"
		"  Heartbeat:\n");
}

int main(void)
{
	int i;

	/*
	 * Say hello on the LED FIRST, before touching any peripheral that could
	 * misbehave. Ten fast blinks are unmistakable and they prove the core
	 * reached C code - the previous version only blinked after the banner
	 * had been printed, so a silent UART hid the proof of life as well.
	 */
	led_init();
	for (i = 0; i < 20; i++) {
		led_set(i & 1);
		delay(120000);
	}

	uart_init();
	scr_clear();
	print_banner();

	/* Everything above stays put; the heartbeat cycles through what is left. */
	scr_top = scr_row;

	for (;;) {
		led_set(1);
		putc_both('*');
		delay(900000);

		led_set(0);
		delay(900000);
	}

	return 0;
}

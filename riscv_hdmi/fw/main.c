/*
 * Stage 1 firmware for the AE350 hard RISC-V core on the Tang Mega 138K.
 *
 * Prints a greeting and a description of the scene on UART2 (115200 8N1,
 * reachable over the board's BL616 USB-serial bridge), then blinks the LED
 * GPIO forever. The blink matters: it is proof that the core is running our
 * code even if the UART divisor still needs tuning.
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

static void uart_puts(const char *s)
{
	while (*s)
		uart_putc(*s++);
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

/* Rough delay: the core runs at 200 MHz, but the loop is bounded by whatever
 * the compiler emits, so this is only ever "about half a second". */
static void delay(volatile uint32_t n)
{
	while (n--)
		__asm__ volatile ("nop");
}

/* ---------------- scene ---------------- */

static void print_banner(void)
{
	uart_puts(
		"\n"
		"=====================================================\n"
		"  Tang Mega 138K  -  hard RISC-V (AE350) is alive!\n"
		"=====================================================\n"
		"\n"
		"  Vitannia! Hello from an AndesCore A25 running as a\n"
		"  HARD block inside the Gowin GW5AST-138C - it costs\n"
		"  zero LUTs and zero registers of the FPGA fabric.\n"
		"\n");

	uart_puts(
		"  The scene\n"
		"  ---------\n"
		"  * core      : AndesCore A25, 200 MHz, RV32\n"
		"  * buses     : AHB 100 MHz, APB 100 MHz, RTC 10 MHz\n"
		"  * this code : fabric BSRAM at 0x80000000, baked\n"
		"                straight into the bitstream - no\n"
		"                debugger, no SPI-flash programming\n"
		"  * data      : fabric RAM at 0x00000000 - stack and .bss.\n"
		"                This core has no usable DLM, and the ddr/sram\n"
		"                port it arrives on is 64 bits wide\n"
		"  * console   : UART2 at 0xF0300000, 115200 8N1,\n"
		"                out through the on-board BL616 bridge\n"
		"  * LED       : GPIO bit 0 - the heartbeat below\n"
		"\n"
		"  Next stage: this CPU takes the wheel and drives the\n"
		"  1080p HDMI generator over an APB peripheral.\n"
		"\n"
		"  Heartbeat: ");
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
		delay(60000);
	}

	uart_init();
	print_banner();

	for (;;) {
		led_set(1);
		uart_putc('*');
		delay(450000);

		led_set(0);
		delay(450000);
	}

	return 0;
}

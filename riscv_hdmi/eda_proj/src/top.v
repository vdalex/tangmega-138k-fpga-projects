`timescale 1ns / 1ns

//
// Hard RISC-V (AE350) bring-up on the Tang Mega 138K - stage 1.
//
// The GW5AST-138C carries an AndesCore A25 + AE350 subsystem as a HARD block:
// instantiating AE350_SOC costs zero LUTs and zero registers. This stage wires
// it up and proves it executes our C code:
//
//   * boot memory in fabric BSRAM, preloaded from the bitstream (fw/)
//   * greeting + scene description printed on UART2 (115200 8N1, BL616)
//   * LED driven from CPU GPIO, so there is proof of life even if the UART
//     baud rate needs adjusting
//
// Stage 2 adds an APB peripheral so the CPU can drive the HDMI generator.
//
module top (
	input			clk,		// 50 MHz board oscillator (V22)
	input			key_n,		// reset button, active low (F4)

	output			uart_tx,	// to BL616 bridge, BL616_IO28_TX (U15)
	input			uart_rx,	// from BL616 bridge, BL616_IO27_RX (V14)

	// Bring-up diagnostics on the four on-board LEDs (ACTIVE LOW - see below):
	//   led[0] T18  fabric heartbeat; fast = clocks+reset OK, slow = not
	//   led[1] R18  the firmware's own GPIO heartbeat - blinks = C code runs
	//   led[2] R17  ON = >= 1 instruction fetched      (latched)
	//   led[3] P16  ON = the data memory was accessed (latched)
	output	[3 : 0]	led
);

	// ------------------------------------------------------------------
	// clocks: one PLL feeds every AE350 domain (VCO = 50/1*16 = 800 MHz)
	// ------------------------------------------------------------------

	// CORE_CLK is NOT ordinary fabric routing - the primitive calls it a
	// "dedicated clock path", and MUG1030 sec. 2.6.4 is explicit: the core
	// clock comes from "PLL_R[0] > clkout1". So the core is clocked only if
	//   (a) it is driven from clkout1 of this PLL, and
	//   (b) the PLL instance is pinned to PLL_R[0]  -> INS_LOC in the .cst.
	// Driving it from clkout0 (as this design first did) leaves the CPU with
	// no clock at all, which looks exactly like a dead core.

	wire	pll_lock;
	wire	core_clk;	// 200 MHz - CPU core (clkout1, dedicated path)
	wire	ahb_clk;	// 100 MHz - AHB bus
	wire	apb_clk;	// 100 MHz - APB bus and peripherals (UART clock)
	wire	ddr_clk;	//  50 MHz - spare (DDR_CLK is fed from ahb_clk)
	wire	rtc_clk;	//  10 MHz - must keep running for wake-up

	Gowin_PLL_AE350 pll0(
		.lock		(pll_lock),
		.clkout0	(ahb_clk),
		.clkout1	(core_clk),
		.clkout2	(apb_clk),
		.clkout3	(ddr_clk),
		.clkout4	(rtc_clk),
		.clkin		(clk)
	);

	// ------------------------------------------------------------------
	// reset: hold the core down until the PLL is locked and the clocks have
	// had time to settle, then release synchronously to the AHB clock.
	//
	// key_n is deliberately NOT in this path during bring-up. If that pin is
	// not the button we think it is, or simply reads low, it would pin the core
	// in reset forever and look exactly like a dead CPU. One less variable.
	// ------------------------------------------------------------------

	reg	[15 : 0]	rst_cnt = 16'd0;
	reg				rstn_r  = 1'b0;

	always@(posedge ahb_clk)begin
		if(!pll_lock)begin
			rst_cnt	<= 16'd0;
			rstn_r	<= 1'b0;
		end else if(!rst_cnt[15])begin
			rst_cnt	<= rst_cnt + 1'b1;
			rstn_r	<= 1'b0;
		end else begin
			rstn_r	<= 1'b1;
		end
	end

	wire ae350_rstn = rstn_r;

	wire unused_key = key_n;

	// ------------------------------------------------------------------
	// firmware ROM on the core's instruction-memory AHB port (0x80000000).
	// Mutable data and the stack live in data_ram0 below, not in the core.
	// ------------------------------------------------------------------

	wire	[31 : 0]	rom_haddr;
	wire	[1 : 0]		rom_htrans;
	wire	[31 : 0]	rom_hrdata;
	wire				rom_hready;
	wire				rom_hresp;

	boot_rom #(
		.AW			(12),					// 4096 words = 16 KB
		.INIT_FILE	("boot_rom.vh")
	)boot_rom0(
		.hclk		(ahb_clk),
		.haddr		(rom_haddr),
		.htrans		(rom_htrans),
		.hrdata		(rom_hrdata),
		.hready		(rom_hready),
		.hresp		(rom_hresp)
	);

	// ------------------------------------------------------------------
	// data memory (0x00000000) - .data, .bss and the stack.
	// The core's own DLM at 0xA0200000 is absent in this configuration
	// (verified on hardware: store then readback returned the wrong value),
	// so the writable memory lives in fabric BSRAM on the ddr/sram AHB port.
	// ------------------------------------------------------------------

	wire	[31 : 0]	ram_haddr;
	wire	[1 : 0]		ram_htrans;
	wire				ram_hwrite;
	wire	[2 : 0]		ram_hsize;
	wire	[63 : 0]	ram_hwdata;		// this port is 64-bit wide
	wire	[63 : 0]	ram_hrdata;
	wire				ram_hready;
	wire				ram_hresp;

	// DDR_CLK is driven from ahb_clk above, so one clock covers both sides
	// of this port and there is no domain crossing to get wrong.
	data_ram #(
		.AW			(12)					// 4096 x 64-bit = 32 KB
	)data_ram0(
		.hclk		(ahb_clk),
		.haddr		(ram_haddr),
		.htrans		(ram_htrans),
		.hwrite		(ram_hwrite),
		.hsize		(ram_hsize),
		.hwdata		(ram_hwdata),
		.hrdata		(ram_hrdata),
		.hready		(ram_hready),
		.hresp		(ram_hresp)
	);

	// ------------------------------------------------------------------
	// GPIO: bit 0 drives the heartbeat LED
	// ------------------------------------------------------------------

	wire	[31 : 0]	gpio_out;
	wire	[31 : 0]	gpio_oe;

	// ------------------------------------------------------------------
	// bring-up diagnostics
	//
	// The on-board LEDs are ACTIVE LOW (deduced on hardware: with pll_lock and
	// rstn both high their LEDs were dark while the stuck-at-zero fetch counter
	// lit its own). So every status line below is driven inverted - an LED that
	// is ON means the signal it reports is TRUE.
	// ------------------------------------------------------------------

	wire core_wfi;

	// Fabric heartbeat on the raw oscillator: independent of the PLL, so it
	// blinks even if everything else is dead. If this is dark, the bitstream
	// did not load. ~1.5 Hz at 50 MHz.
	reg	[25 : 0]	fab_cnt = 26'd0;
	always@(posedge clk)
		fab_cnt <= fab_cnt + 1'b1;

	// How FAR does execution get? HTRANS[1] marks a real (NONSEQ/SEQ) transfer
	// on the instruction port. Latched thresholds read far more reliably than
	// a blink: each stays lit once passed, so the LEDs show the order of
	// magnitude of instructions fetched before the core stopped (if it did).
	reg	[23 : 0]	fetch_cnt	= 24'd0;
	reg				fetch_1		= 1'b0;		// >= 1 fetch
	reg				fetch_4k	= 1'b0;		// >= 4096 fetches
	reg				fetch_1m	= 1'b0;		// >= 1M fetches - genuinely running

	always@(posedge ahb_clk)begin
		if(!ae350_rstn)begin
			fetch_cnt <= 24'd0;
			fetch_1 <= 1'b0; fetch_4k <= 1'b0; fetch_1m <= 1'b0;
		end else if(rom_htrans[1])begin
			fetch_cnt <= fetch_cnt + 1'b1;
			fetch_1 <= 1'b1;
			if(fetch_cnt >= 24'd4096)		fetch_4k <= 1'b1;
			if(fetch_cnt >= 24'd1000000)	fetch_1m <= 1'b1;
		end
	end

	// T18 always blinks (so "bitstream loaded" is never in doubt) and its RATE
	// reports the clock/reset chain: fast ~6 Hz = PLL locked and core released,
	// slow ~0.75 Hz = something upstream is wrong.
	wire clocks_ok = pll_lock & ae350_rstn;

	// Does the core ever touch the data port? Latched in the port's own
	// clock domain. If this stays dark while instructions are being fetched,
	// the core is not reaching its first stack access at all.
	reg	ram_seen = 1'b0;
	always@(posedge ahb_clk)
		if(ram_htrans[1])	ram_seen <= 1'b1;

	assign led[0] = clocks_ok ? fab_cnt[22] : fab_cnt[25];
	assign led[1] = ~gpio_out[0];	// R18 - the FIRMWARE's own heartbeat
	assign led[2] = ~fetch_1;		// R17 - ON = executed at least 1 instruction
	assign led[3] = ~ram_seen;		// P16 - ON = data memory was accessed

	wire unused_diag = core_wfi | fetch_1m | fetch_4k;

	wire unused_gpio = |{gpio_out[31 : 1], gpio_oe};

	// ------------------------------------------------------------------
	// the hard core
	// ------------------------------------------------------------------

	AE350_SOC ae350_0 (
		// power-on / hardware reset (both active low)
		.POR_N			(ae350_rstn),
		.HW_RSTN		(ae350_rstn),

		// clocks
		.CORE_CLK		(core_clk),
		.AHB_CLK		(ahb_clk),
		.APB_CLK		(apb_clk),
		// Same net as AHB_CLK on purpose: the "ddr/sram" port has its own
		// clock input, and rather than guess which domain the fabric side of
		// it lives in, run both from one clock so the question cannot arise.
		.DDR_CLK		(ahb_clk),
		.RTC_CLK		(rtc_clk),
		.DBG_TCK		(1'b0),

		// clock enables - everything running
		.CORE_CE		(1'b1),
		.AXI_CE			(1'b1),
		.DDR_CE			(1'b1),
		.AHB_CE			(1'b1),
		.APB_CE			(8'hFF),
		.APB2AHB_CE		(1'b1),

		// no scan / test
		.SCAN_TEST		(1'b0),
		.SCAN_EN		(1'b0),
		.TEST_CLK		(1'b0),
		.TEST_MODE		(1'b0),
		.TEST_RSTN		(1'b1),

		// no fabric interrupts or DMA yet
		.GP_INT			(16'd0),
		.DMA_REQ		(8'd0),

		// WAKEUP_IN is ACTIVE LOW ("0 is wake up" in the primitive header).
		// It was tied high here, i.e. permanently asking the core to stay
		// asleep - hold it asserted so the core is always awake.
		.WAKEUP_IN		(1'b0),

		// tells us whether the core parked itself in WFI
		.CORE0_WFI_MODE	(core_wfi),

		// instruction memory (0x80000000)
		.ROM_HADDR		(rom_haddr),
		.ROM_HTRANS		(rom_htrans),
		.ROM_HRDATA		(rom_hrdata),
		.ROM_HREADY		(rom_hready),
		.ROM_HRESP		(rom_hresp),

		// Unused slave ports: their READY inputs must be tied HIGH. Left
		// unconnected they synthesize to 0, which on AHB/APB means "slave not
		// ready" - so a single stray access into one of these regions stalls
		// the core forever and it stops fetching. Tie them off as always-ready,
		// zero-data slaves so such an access completes harmlessly.
		.APB_PRDATA		(32'd0),
		.APB_PREADY		(1'b1),
		.APB_PSLVERR	(1'b0),

		.EXTS_HRDATA	(32'd0),
		.EXTS_HREADYIN	(1'b1),
		.EXTS_HRESP		(1'b0),

		// data memory (0x00000000) - fabric RAM, see data_ram0 below
		.DDR_HADDR		(ram_haddr),
		.DDR_HTRANS		(ram_htrans),
		.DDR_HWRITE		(ram_hwrite),
		.DDR_HSIZE		(ram_hsize),
		.DDR_HWDATA		(ram_hwdata),
		.DDR_HRDATA		(ram_hrdata),
		.DDR_HREADY		(ram_hready),
		.DDR_HRESP		(ram_hresp),

		// JTAG unused (stage 1 loads code from the bitstream)
		.TMS_IN			(1'b1),
		.TRST_IN		(1'b1),
		.TDI_IN			(1'b1),

		// console
		.UART2_TXD		(uart_tx),
		.UART2_RXD		(uart_rx),
		.UART2_CTSN		(1'b0),
		.UART2_DCDN		(1'b0),
		.UART2_DSRN		(1'b0),
		.UART2_RIN		(1'b0),

		// GPIO
		.GPIO_IN		(32'd0),
		.GPIO_OE		(gpio_oe),
		.GPIO_OUT		(gpio_out)
	);

endmodule

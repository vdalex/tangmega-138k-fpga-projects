`timescale 1ns / 1ns

//
// Boot ROM for the AE350 hard RISC-V core.
//
// Sits on the core's dedicated instruction-memory AHB port, which the AE350
// maps at 0x80000000..0x8FFFFFFF (see the Gowin RiscV_AE350_SOC hardware
// manual, "Memory System": SPI Flash / ITCM / *user-customized memory*).
// This is that user-customized memory: fabric BSRAM holding .text and
// .rodata, preloaded straight from the bitstream - so the CPU runs our C
// code with no debugger and no SPI-flash programming.
//
// The port is read-only by construction: the core exposes ROM_HWRITE but no
// write-data bus, so writes cannot be carried. Mutable data and the stack
// live in the core's internal DLM at 0xA0200000 instead.
//
// The image comes from fw/ via tools/bin2vh.py, which emits the $readmemh
// file named by INIT_FILE.
//
// Only the low word index is decoded - the AE350 bus matrix already routes
// just this region here, so the upper bits carry no information.
//
// AHB-lite, zero wait states: the address phase drives the memory and the
// data phase returns the word, so HREADY is tied high.
//
module boot_rom #(
	parameter AW		= 12,				// word-address width (4096 words = 16 KB)
	parameter INIT_FILE	= "boot_rom.vh"
)
(
	input				hclk,

	input	[31 : 0]	haddr,
	input	[1 : 0]		htrans,

	output	[31 : 0]	hrdata,
	output				hready,
	output				hresp
);

	localparam DEPTH = 1 << AW;

	(* ram_style = "block" *)
	reg	[31 : 0]	mem [0 : DEPTH-1];

	initial $readmemh(INIT_FILE, mem);

	// Registered read: address phase -> data phase, one cycle, no wait states.
	reg	[31 : 0]	rdata;

	always@(posedge hclk)
		rdata <= mem[haddr[AW+1 : 2]];

	assign hrdata	= rdata;
	assign hready	= 1'b1;
	assign hresp	= 1'b0;

	// HTRANS is unused: the memory is combinationally addressed every cycle
	// and returning data for an IDLE cycle is harmless.
	wire unused = &{1'b0, htrans, 1'b0};

endmodule

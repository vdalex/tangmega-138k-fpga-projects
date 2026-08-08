`timescale 1ns / 1ns

//
// 8x16 glyph ROM for the HDMI text console.
//
// Contents come from tools/make_font.py, which rasterises Consolas into
// font_rom.vh: printable ASCII 0x20..0x7E, sixteen rows per glyph, MSB of each
// row being the leftmost pixel. Address = glyph_index * 16 + row, where
// glyph_index is (code - 0x20) - the caller does that mapping so it can
// substitute a space for anything unprintable.
//
// Registered output: data is valid the cycle after the address is presented.
//
module font_rom (
	input				clk,
	input	[10 : 0]	addr,
	output	reg	[7 : 0]	data
);

	(* ram_style = "block" *)
	reg	[7 : 0]	rom [0 : 2047];

	initial $readmemh("font_rom.vh", rom);

	always@(posedge clk)
		data <= rom[addr];

endmodule

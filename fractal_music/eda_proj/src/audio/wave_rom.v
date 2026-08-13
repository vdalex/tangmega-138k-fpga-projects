`timescale 1ns / 1ns

//
// Two 256-entry wavetables in one ROM: address = {table, phase[7:0]}.
// Table 0 is a pure sine, used for the bass - giving the low notes harmonics
// too is what turns the bottom end to mud. Table 1 is a sawtooth band-limited
// to five harmonics, which is what puts any brightness in the sound at all.
// Contents come from tools/music_model.py.
//
module wave_rom (
	input					clk,
	input		[8 : 0]		addr,
	output reg signed [15 : 0]	data
);

	(* ram_style = "block" *)
	reg	[15 : 0]	rom [0 : 511];

	initial $readmemh("wave_rom.vh", rom);

	always@(posedge clk)
		data <= rom[addr];

endmodule

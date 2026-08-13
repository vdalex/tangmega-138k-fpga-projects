`timescale 1ns / 1ns

//
// Scale degree -> 32-bit phase increment, precomputed for the sample rate the
// hardware actually runs at. Keeping the frequency table out of the fabric
// means no divider and no floating point here; tools/music_model.py works out
// the pentatonic and bakes the results in.
//
module note_rom (
	input				clk,
	input		[4 : 0]	addr,
	output reg	[31 : 0] data
);

	(* ram_style = "block" *)
	reg	[31 : 0]	rom [0 : 31];

	initial $readmemh("note_rom.vh", rom);

	always@(posedge clk)
		data <= rom[addr];

endmodule

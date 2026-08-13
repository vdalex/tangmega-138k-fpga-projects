`timescale 1ns / 1ns

//
// Stereo ping-pong delay - the "room".
//
// Each channel's feedback goes into the *other* line, so a repeat bounces
// left-right-left. That bounce is most of what makes this read as a space
// rather than as an echo, and it costs nothing extra: the same two memories
// either way, just cross-wired.
//
// Two details that matter more than they look:
//   * The delay is deliberately not a neat fraction of the note grid. An exact
//     multiple would put every repeat on the beat and it would sound like a
//     rhythmic effect instead of a room.
//   * The feedback path is low-passed. Without it the repeats stay as bright
//     as the source and pile up into harshness; rolling the top off makes them
//     recede, which is what the ear reads as distance.
//
// The work is spread over five states with at most one multiply or one
// add-and-saturate in each. Folded into fewer, the chain from the block RAM
// output through the wet multiply, the sum and the saturation became the
// critical path of the design. There are 3000 clocks per sample here, so
// states are free and there is no reason to be clever.
//
// Mirrors the delay section of tools/music_model.py.
//
module pingpong #(
	parameter AW		= 13,		// 8192 samples, ~171 ms at 47.8 kHz
	parameter DELAY_LEN	= 7892,		// 165 ms at 47832 Hz
	parameter FEEDBACK	= 140,		// /256
	parameter WET		= 150,		// /256
	parameter DAMP_SH	= 2
)
(
	input						clk,
	input						reset,

	input						in_stb,
	input	signed	[15 : 0]	in_l,
	input	signed	[15 : 0]	in_r,

	output	reg signed [15 : 0]	out_l,
	output	reg signed [15 : 0]	out_r,
	output	reg					out_stb
);

	(* ram_style = "block" *) reg signed [15 : 0] mem_l [0 : (1 << AW) - 1];
	(* ram_style = "block" *) reg signed [15 : 0] mem_r [0 : (1 << AW) - 1];

	function signed [15 : 0] sat16(input signed [31 : 0] val);
		sat16 = (val >  32'sd32767) ?  16'sd32767 :
				(val < -32'sd32768) ? -16'sd32768 : val[15 : 0];
	endfunction

	reg	[AW-1 : 0]		pos = {AW{1'b0}};
	reg	signed [15 : 0]	dry_l, dry_r;
	reg	signed [15 : 0]	rd_l, rd_r;			// what the lines held
	reg	signed [15 : 0]	rq_l, rq_r;			// ...one more hop from the RAM
	reg	signed [15 : 0]	lp_l, lp_r;			// damped feedback
	reg	signed [16 : 0]	dif_l, dif_r;		// error term for the one-pole
	reg	signed [31 : 0]	wet_l, wet_r;		// echo scaled for the output
	reg	signed [31 : 0]	fb_l, fb_r;			// echo scaled for the write-back
	reg	[2 : 0]			st = 3'd0;

	always@(posedge clk)begin
		out_stb <= 1'b0;

		if(reset)begin
			pos  <= {AW{1'b0}};
			lp_l <= 16'sd0;
			lp_r <= 16'sd0;
			st   <= 3'd0;
		end else case(st)

		3'd0: if(in_stb)begin
				dry_l <= in_l;
				dry_r <= in_r;
				st    <= 3'd1;
			end

		// block RAM read
		3'd1: begin
				rd_l <= mem_l[pos];
				rd_r <= mem_r[pos];
				st   <= 3'd2;
			end

		// Nothing but a hop. A block RAM output has a long clock-to-out and
		// tends to be placed in its own column, so the first thing that touches
		// it inherits that delay plus the trip back - even one subtract was
		// enough to be the critical path. Giving the value a cycle of its own
		// to travel costs nothing here and is worth ~15 MHz.
		3'd2: begin
				rq_l <= rd_l;
				rq_r <= rd_r;
				st   <= 3'd3;
			end

		// one-pole rolloff, split so the difference and the accumulate do not
		// share a cycle
		3'd3: begin
				dif_l <= rq_r - lp_l;			// cross-coupled
				dif_r <= rq_l - lp_r;
				wet_l <= (rq_l * WET) >>> 8;
				wet_r <= (rq_r * WET) >>> 8;
				st    <= 3'd4;
			end

		3'd4: begin
				lp_l <= lp_l + (dif_l >>> DAMP_SH);
				lp_r <= lp_r + (dif_r >>> DAMP_SH);
				st   <= 3'd5;
			end

		// scale the feedback, and publish the output
		3'd5: begin
				fb_l    <= (lp_l * FEEDBACK) >>> 8;
				fb_r    <= (lp_r * FEEDBACK) >>> 8;
				out_l   <= sat16(dry_l + wet_l);
				out_r   <= sat16(dry_r + wet_r);
				out_stb <= 1'b1;
				st      <= 3'd6;
			end

		// write the lines back and advance
		3'd6: begin
				mem_l[pos] <= sat16(dry_l + fb_l);
				mem_r[pos] <= sat16(dry_r + fb_r);
				pos <= (pos == (DELAY_LEN - 1)) ? {AW{1'b0}} : (pos + 1'b1);
				st  <= 3'd0;
			end

		default: st <= 3'd0;
		endcase
	end

endmodule

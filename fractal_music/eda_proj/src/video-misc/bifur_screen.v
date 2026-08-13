`timescale 1ns / 1ns

//
// The score, full screen: the bifurcation diagram with a playhead showing
// where the music currently is.
//
// This is the picture worth looking at. The design used to give most of the
// screen to a live Julia set and put the diagram in a 160-line band along the
// bottom; the diagram won on sight. It is also the more honest illustration -
// every note the piece plays is a point on this curve, and the playhead is
// literally the value of r going into the map.
//
// The diagram is static, so it is baked into block RAM by
// tools/music_model.py rather than computed. Drawing it live would mean
// iterating the map hundreds of times per column, which is a batch job, not
// something a raster can do on the way past. 640x360 at one bit per pixel is
// 7200 words - scaled 2x in both directions to fill 1280x720.
//
// The address arithmetic is spread over several registered stages on purpose.
// Done in one cycle - row index, multiply by the words per row, add the
// column - it was the critical path of the whole design and held the pixel
// clock to 77 MHz. Nothing here is expensive; it just has to be spaced out.
//
// Latency from the counters to `color` is PIPE = 6 clocks. The caller delays
// the syncs by the same amount, so keep the two in step.
//
module bifur_screen #(
	parameter ROM_W				= 640,
	parameter ROM_H				= 360,
	parameter [23 : 0] COL_BG	= 24'h0A0A12,
	parameter [23 : 0] COL_DIAG	= 24'h78F0C8,	// the attractor
	parameter [23 : 0] COL_HEAD	= 24'hFF9030	// the playhead
)
(
	input				pixel_clock,

	input		[10 : 0]	px,			// 0..1279 within the active area
	input		[10 : 0]	py,			// 0..719
	input		[10 : 0]	head_x,		// playhead column, 0..1279

	output	reg	[23 : 0]	color
);

	localparam WORDS_PER_ROW = ROM_W / 32;			// 20
	localparam PIPE          = 6;

	(* ram_style = "block" *)
	reg	[31 : 0]	rom [0 : (ROM_H * WORDS_PER_ROW) - 1];

	initial $readmemh("bifur_rom.vh", rom);

	// A local copy, so the comparators below are fed from next door rather
	// than from wherever the sequencer ended up being placed.
	reg	[10 : 0]	head_r = 11'd0;
	always@(posedge pixel_clock)
		head_r <= head_x;

	// A playhead one pixel wide is invisible at this scale; three is readable
	// without hiding the diagram behind it.
	wire near_head = (px >= head_r) && (px < (head_r + 11'd3));

	// ---- stage 0: which row and column of the stored image ----
	reg	[9 : 0]		ry_0, rx_0;
	reg				hd_0;
	always@(posedge pixel_clock)begin
		ry_0 <= py[10 : 1];							// 2x vertical scale
		rx_0 <= px[10 : 1];							// 2x horizontal scale
		hd_0 <= near_head;
	end

	// ---- stage 1: row base address (the only multiply, by a constant) ----
	reg	[15 : 0]	base_1;
	reg	[9 : 0]		rx_1;
	reg				hd_1;
	always@(posedge pixel_clock)begin
		base_1 <= ry_0 * WORDS_PER_ROW;
		rx_1   <= rx_0;
		hd_1   <= hd_0;
	end

	// ---- stage 2: full word address ----
	reg	[15 : 0]	addr_2;
	reg	[4 : 0]		bit_2;
	reg				hd_2;
	always@(posedge pixel_clock)begin
		addr_2 <= base_1 + rx_1[9 : 5];
		bit_2  <= rx_1[4 : 0];
		hd_2   <= hd_1;
	end

	// ---- stage 3: block RAM read ----
	reg	[31 : 0]	word_3;
	reg	[4 : 0]		bit_3;
	reg				hd_3;
	always@(posedge pixel_clock)begin
		word_3 <= rom[addr_2];
		bit_3  <= bit_2;
		hd_3   <= hd_2;
	end

	// ---- stage 4: pick this pixel's bit (MSB is the leftmost) ----
	reg				set_4, hd_4;
	always@(posedge pixel_clock)begin
		set_4 <= word_3[5'd31 - bit_3];
		hd_4  <= hd_3;
	end

	// ---- stage 5: colour ----
	always@(posedge pixel_clock)
		color <= hd_4 ? COL_HEAD : (set_4 ? COL_DIAG : COL_BG);

endmodule

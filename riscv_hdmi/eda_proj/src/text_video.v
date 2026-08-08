`timescale 1ns / 1ns

//
// Text-mode video generator, 1920x1080@60.
//
// Draws a 120 x 33 character console from the shared text buffer: 8x16 glyphs
// scaled 2x, so each cell is 16 x 32 screen pixels. Like the other generators
// in this repo there is no framebuffer - each pixel is looked up as the raster
// reaches it.
//
// Per pixel the lookup is: cell -> character -> glyph row -> one bit. Both the
// text buffer and the glyph ROM are block RAM with a registered output, so the
// path is pipelined and the sync signals are delayed to match:
//
//   cycle 0  present the text-buffer address for this pixel's cell
//   cycle 1  block RAM reads; its lane mux is registered too
//   cycle 2  character arrives; register the glyph-ROM address
//   cycle 3  glyph ROM reads
//   cycle 4  glyph row arrives; pick the bit for this pixel
//   cycle 5  colour leaves the pipeline
//
// The extra register inside the text buffer's read port is what lets this
// close at 150 MHz - without it the path from block RAM through the lane mux
// and the character decode ran at 112 MHz.
//
// Addressing the buffer needs no multiply: the row stride is 128, so the byte
// address is simply {row, col}.
//
module text_video #(

	parameter video_hlength		= 2200,
	parameter video_vlength		= 1125,
	parameter video_hsync_pol	= 1,
	parameter video_hsync_len	= 44,
	parameter video_hbp_len		= 148,

	parameter video_h_visible	= 1920,
	parameter video_vsync_pol	= 1,
	parameter video_vsync_len	= 5,
	parameter video_vbp_len		= 36,
	parameter video_v_visible	= 1080,

	parameter TEXT_COLS			= 120,
	parameter TEXT_ROWS			= 33,

	parameter [23 : 0] COL_BG	= 24'h101018,	// same palette as the clock
	parameter [23 : 0] COL_FG	= 24'hE8E8F0
)
(
	input				pixel_clock,
	input				reset,

	// shared text buffer (read side)
	output	[12 : 0]	text_addr,
	input	[7 : 0]		text_data,

	output				video_vsync,
	output				video_hsync,
	output				video_den,
	output				video_line_start,
	output	[23 : 0]	video_pixel_even,
	output	[23 : 0]	video_pixel_odd
);

	localparam T_HVIS_BEGIN	= video_hsync_len + video_hbp_len;
	localparam T_HVIS_END	= T_HVIS_BEGIN + video_h_visible - 1;
	localparam T_VVIS_BEGIN	= video_vsync_len + video_vbp_len;

	localparam PIPE = 5;

	// ------------------------------------------------------------------
	// video timing
	// ------------------------------------------------------------------

	wire	[13 : 0]	timing_h_pos;
	wire	[13 : 0]	timing_v_pos;
	wire	[13 : 0]	pixel_x_nc;
	wire	[13 : 0]	pixel_y_nc;

	wire				vsync_int;
	wire				hsync_int;
	wire				den_int;
	wire				line_start_int;

	video_timing_ctrl #(
		.video_hlength(video_hlength),
		.video_vlength(video_vlength),
		.video_hsync_pol(video_hsync_pol),
		.video_hsync_len(video_hsync_len),
		.video_hbp_len(video_hbp_len),
		.video_h_visible(video_h_visible),
		.video_vsync_pol(video_vsync_pol),
		.video_vsync_len(video_vsync_len),
		.video_vbp_len(video_vbp_len),
		.video_v_visible(video_v_visible)
	)video_timing_ctrl_inst0(
		.pixel_clock		(pixel_clock),
		.reset				(reset),
		.ext_sync			(1'b0),
		.timing_h_pos		(timing_h_pos),
		.timing_v_pos		(timing_v_pos),
		.pixel_x			(pixel_x_nc),
		.pixel_y			(pixel_y_nc),
		.video_vsync		(vsync_int),
		.video_hsync		(hsync_int),
		.video_den			(den_int),
		.video_line_start	(line_start_int)
	);

	// ------------------------------------------------------------------
	// active-area counters
	// ------------------------------------------------------------------

	wire pix_load	= (timing_h_pos == (T_HVIS_BEGIN - 1));
	wire line_step	= (timing_h_pos == (T_HVIS_END + 1));
	wire frame_load	= (timing_v_pos == (T_VVIS_BEGIN - 1));

	reg	[10 : 0]	px = 11'd0;
	always@(posedge pixel_clock)
		px <= pix_load ? 11'd0 : (px + 1'b1);

	reg	[10 : 0]	py = 11'd0;
	always@(posedge pixel_clock)
		if(line_step)	py <= frame_load ? 11'd0 : (py + 1'b1);

	wire	[6 : 0]	col = px[10 : 4];	// 0..119  (cells are 16 px wide)
	wire	[5 : 0]	row = py[10 : 5];	// 0..32   (cells are 32 px tall)
	wire	[3 : 0]	gy  = py[4 : 1];	// glyph row, 2x scaled
	wire	[2 : 0]	gx  = px[3 : 1];	// glyph column, 2x scaled

	// ------------------------------------------------------------------
	// stage 0: address the text buffer (stride 128 -> plain concatenation)
	// ------------------------------------------------------------------

	assign text_addr = {row, col};

	// The bottom of the screen is not a whole number of cells (1080 / 32 =
	// 33.75) and columns past the last one do not exist either, so blank
	// anything outside the grid rather than reading past the buffer.
	wire on_grid = (row < TEXT_ROWS) && (col < TEXT_COLS);

	// The character arrives two cycles after its address, so its row index and
	// the on-grid flag have to wait the same amount.
	reg	[3 : 0]	gy_d1, gy_d2;
	reg			grid_d1, grid_d2;
	always@(posedge pixel_clock)begin
		gy_d1   <= gy;		gy_d2   <= gy_d1;
		grid_d1 <= on_grid;	grid_d2 <= grid_d1;
	end

	// ------------------------------------------------------------------
	// stage 1: character -> glyph ROM address
	// ------------------------------------------------------------------

	// Anything outside printable ASCII becomes a space, which also covers the
	// buffer's power-on contents.
	wire printable = grid_d2 && (text_data >= 8'h20) && (text_data <= 8'h7E);
	wire [6 : 0] glyph = printable ? (text_data[6 : 0] - 7'h20) : 7'd0;

	reg	[10 : 0]	font_addr;
	always@(posedge pixel_clock)
		font_addr <= {glyph, gy_d2};

	// ------------------------------------------------------------------
	// stages 2-3: glyph ROM, then pick this pixel's bit
	// ------------------------------------------------------------------

	wire	[7 : 0]	font_bits;

	font_rom font_rom0(
		.clk	(pixel_clock),
		.addr	(font_addr),
		.data	(font_bits)
	);

	// gx has to arrive with the glyph row it belongs to: four cycles later.
	reg	[2 : 0]	gx_d1, gx_d2, gx_d3, gx_d4;
	always@(posedge pixel_clock)begin
		gx_d1 <= gx;
		gx_d2 <= gx_d1;
		gx_d3 <= gx_d2;
		gx_d4 <= gx_d3;
	end

	// ~gx is 7-gx for a 3-bit value, and costs nothing.
	reg	[23 : 0]	color;
	always@(posedge pixel_clock)
		color <= font_bits[~gx_d4] ? COL_FG : COL_BG;

	// ------------------------------------------------------------------
	// sync signals, delayed to match
	// ------------------------------------------------------------------

	reg	[PIPE-1 : 0]	den_dly, hsync_dly, vsync_dly, line_start_dly;
	always@(posedge pixel_clock)begin
		den_dly			<= {den_dly[PIPE-2 : 0], den_int};
		hsync_dly		<= {hsync_dly[PIPE-2 : 0], hsync_int};
		vsync_dly		<= {vsync_dly[PIPE-2 : 0], vsync_int};
		line_start_dly	<= {line_start_dly[PIPE-2 : 0], line_start_int};
	end

	wire den_out = den_dly[PIPE-1];

	assign video_den		= den_out;
	assign video_hsync		= hsync_dly[PIPE-1];
	assign video_vsync		= vsync_dly[PIPE-1];
	assign video_line_start	= line_start_dly[PIPE-1];

	assign video_pixel_even	= den_out ? color : 24'h000000;
	assign video_pixel_odd	= den_out ? color : 24'h000000;

endmodule

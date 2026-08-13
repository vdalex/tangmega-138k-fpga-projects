`timescale 1ns / 1ns

//
// The screen: the bifurcation diagram, full frame, with a playhead marking
// where the music is.
//
//   +--------------------------------------+
//   |                                      |
//   |   bifurcation diagram + playhead     |  720 lines
//   |                                      |
//   +--------------------------------------+
//
// This used to be a split screen - a live Julia set for c = r(2-r)/4 above,
// the diagram in a 160-line band below - which is a neater illustration of
// the conjugacy between the two maps but a worse picture. The diagram is the
// one worth looking at, so it now has the whole frame. The Julia core and the
// alignment delay it needed are in this file's history if they are ever
// wanted back; sweep_rom.v still emits the matching c for each r.
//
// 1280x720 at a 75 MHz pixel clock. The 1080p version of this design would
// not close timing: with the audio engine sharing the die and the clock, the
// placer spread the two apart and every failing path was routing, not logic.
// 720p has margin to spare and costs the picture nothing that matters here.
//
// With one producer there is no alignment to get wrong any more - the syncs
// are simply delayed by the diagram's own latency.
//
module music_video #(
	parameter video_hlength		= 1650,
	parameter video_vlength		= 750,
	parameter video_hsync_pol	= 1,
	parameter video_hsync_len	= 40,
	parameter video_hbp_len		= 220,

	parameter video_h_visible	= 1280,
	parameter video_vsync_pol	= 1,
	parameter video_vsync_len	= 5,
	parameter video_vbp_len		= 20,
	parameter video_v_visible	= 720
)
(
	input				pixel_clock,
	input				reset,

	// from the composer: where we are along the diagram
	input		[10 : 0]	head_x,

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

	localparam PIPE			= 6;		// bifur_screen, counters -> colour

	// ------------------------------------------------------------------
	// raster
	// ------------------------------------------------------------------

	wire	[13 : 0]	timing_h_pos, timing_v_pos, pixel_x_nc, pixel_y_nc;
	wire				vsync_int, hsync_int, den_int, line_start_int;

	video_timing_ctrl #(
		.video_hlength(video_hlength),		.video_vlength(video_vlength),
		.video_hsync_pol(video_hsync_pol),	.video_hsync_len(video_hsync_len),
		.video_hbp_len(video_hbp_len),		.video_h_visible(video_h_visible),
		.video_vsync_pol(video_vsync_pol),	.video_vsync_len(video_vsync_len),
		.video_vbp_len(video_vbp_len),		.video_v_visible(video_v_visible)
	)timing0(
		.pixel_clock(pixel_clock),	.reset(reset),	.ext_sync(1'b0),
		.timing_h_pos(timing_h_pos),.timing_v_pos(timing_v_pos),
		.pixel_x(pixel_x_nc),		.pixel_y(pixel_y_nc),
		.video_vsync(vsync_int),	.video_hsync(hsync_int),
		.video_den(den_int),		.video_line_start(line_start_int)
	);

	wire pix_load	= (timing_h_pos == (T_HVIS_BEGIN - 1));
	wire line_step	= (timing_h_pos == (T_HVIS_END + 1));
	wire frame_load	= (timing_v_pos == (T_VVIS_BEGIN - 1));

	reg	[10 : 0]	px = 11'd0;
	always@(posedge pixel_clock)
		px <= pix_load ? 11'd0 : (px + 1'b1);

	reg	[10 : 0]	py = 11'd0;
	always@(posedge pixel_clock)
		if(line_step)	py <= frame_load ? 11'd0 : (py + 1'b1);

	// ------------------------------------------------------------------
	// the picture
	// ------------------------------------------------------------------

	wire	[23 : 0]	diagram;

	bifur_screen screen0(
		.pixel_clock	(pixel_clock),
		.px				(px),
		.py				(py),
		.head_x			(head_x),
		.color			(diagram)
	);

	// ------------------------------------------------------------------
	// syncs, delayed to match
	// ------------------------------------------------------------------
	//
	// These must be FLIP-FLOPS. Left to itself the tool implements delay lines
	// as LUT-RAM with a shared address counter, and that counter - fanout in
	// the dozens, loads scattered across the die - produced a single 4.8 ns
	// route against a 6.67 ns budget. It was the last thing holding this design
	// at 109 MHz. Real registers are local to where they are used.

	(* syn_srlstyle = "registers" *)
	reg	[PIPE-1 : 0]	den_dly, hsync_dly, vsync_dly, ls_dly;
	always@(posedge pixel_clock)begin
		den_dly		<= {den_dly[PIPE-2 : 0], den_int};
		hsync_dly	<= {hsync_dly[PIPE-2 : 0], hsync_int};
		vsync_dly	<= {vsync_dly[PIPE-2 : 0], vsync_int};
		ls_dly		<= {ls_dly[PIPE-2 : 0], line_start_int};
	end

	wire den_out = den_dly[PIPE-1];

	assign video_den		= den_out;
	assign video_hsync		= hsync_dly[PIPE-1];
	assign video_vsync		= vsync_dly[PIPE-1];
	assign video_line_start	= ls_dly[PIPE-1];

	assign video_pixel_even	= den_out ? diagram : 24'h000000;
	assign video_pixel_odd	= den_out ? diagram : 24'h000000;

endmodule

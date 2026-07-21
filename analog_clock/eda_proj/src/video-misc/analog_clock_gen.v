`timescale 1ns / 1ns

//
// Analog clock generator, 1920x1080@60.
// Draws a clock face (ring, 12 hour marks) and three moving hands.
//
// A pixel (dx, dy) relative to the centre lies on a hand with unit
// direction vector (sx, sy) (scaled by 256) when
//   dot   = dx*sx + dy*sy   is within [-tail, length] * 256
//   cross = dx*sy - dy*sx   is within [-halfwidth, halfwidth] * 256
// and inside the face ring when r2 = dx*dx + dy*dy is in range.
//
// To close timing at the 150 MHz pixel clock these quantities are NOT
// multiplied per pixel. They are affine (dot/cross) or quadratic (r2)
// in the raster coordinates, so they are evaluated incrementally with
// adders only (a DDA): each accumulator is loaded at the start of an
// active line and then stepped once per pixel. The only multiplies left
// are the six per-frame line-start constants, computed once per frame
// (huge slack) and mapped to DSP blocks. The per-pixel datapath is:
//   stage 0 : DDA accumulators (dx, r2, dot/cross per hand)
//   stage 1 : shape flags
//   stage 2 : colour priority mux
// The sync signals are delayed 2 cycles to match.
//
module analog_clock_gen #(

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

	parameter init_hour			= 10,
	parameter init_min			= 8,
	parameter init_sec			= 0
)
(
	input				pixel_clock,
	input				reset,

	output				video_vsync,
	output				video_hsync,
	output				video_den,
	output				video_line_start,
	output	[23 : 0]	video_pixel_even,
	output	[23 : 0]	video_pixel_odd
);

	localparam CENTER_X		= video_h_visible / 2;	// 960
	localparam CENTER_Y		= video_v_visible / 2;	// 540
	localparam CX_SQ		= CENTER_X * CENTER_X;
	localparam CY_SQ		= CENTER_Y * CENTER_Y;

	// active-region boundaries in raster counter space
	localparam T_HVIS_BEGIN	= video_hsync_len + video_hbp_len;			// 192
	localparam T_HVIS_END	= T_HVIS_BEGIN + video_h_visible - 1;		// 2111
	localparam T_VVIS_BEGIN	= video_vsync_len + video_vbp_len;			// 41

	localparam RING_R2_IN	= 400 * 400;
	localparam RING_R2_OUT	= 416 * 416;
	localparam CENTER_R2	= 12 * 12;

	localparam SEC_LEN		= 370;
	localparam SEC_TAIL		= 50;
	localparam SEC_HW		= 3;

	localparam MIN_LEN		= 330;
	localparam MIN_TAIL		= 12;
	localparam MIN_HW		= 7;

	localparam HR_LEN		= 230;
	localparam HR_TAIL		= 12;
	localparam HR_HW		= 10;

	localparam TICK_HS		= 8;	// hour mark half-size (square)

	localparam COL_BG		= 24'h101018;
	localparam COL_FACE		= 24'h1E1E28;
	localparam COL_RING		= 24'hE8E8F0;
	localparam COL_TICK		= 24'hB0B0C0;
	localparam COL_HR		= 24'hF0F0F8;
	localparam COL_MIN		= 24'hD8D8E0;
	localparam COL_SEC		= 24'hFF3020;
	localparam COL_DOT		= 24'hFF3020;

	// initial hand positions (hour hand advances one LUT step every 12 min)
	localparam INIT_HIDX	= ((init_hour % 12) * 5) + (init_min / 12);
	localparam INIT_MIN12	= init_min % 12;

	// sin(idx * 6 deg) * 256, idx = 0..59
	function signed [9 : 0] sin_lut(input [5 : 0] idx);
		case(idx)
			6'd0:  sin_lut =  10'sd0;
			6'd1:  sin_lut =  10'sd27;
			6'd2:  sin_lut =  10'sd53;
			6'd3:  sin_lut =  10'sd79;
			6'd4:  sin_lut =  10'sd104;
			6'd5:  sin_lut =  10'sd128;
			6'd6:  sin_lut =  10'sd150;
			6'd7:  sin_lut =  10'sd171;
			6'd8:  sin_lut =  10'sd190;
			6'd9:  sin_lut =  10'sd207;
			6'd10: sin_lut =  10'sd222;
			6'd11: sin_lut =  10'sd234;
			6'd12: sin_lut =  10'sd243;
			6'd13: sin_lut =  10'sd250;
			6'd14: sin_lut =  10'sd255;
			6'd15: sin_lut =  10'sd256;
			6'd16: sin_lut =  10'sd255;
			6'd17: sin_lut =  10'sd250;
			6'd18: sin_lut =  10'sd243;
			6'd19: sin_lut =  10'sd234;
			6'd20: sin_lut =  10'sd222;
			6'd21: sin_lut =  10'sd207;
			6'd22: sin_lut =  10'sd190;
			6'd23: sin_lut =  10'sd171;
			6'd24: sin_lut =  10'sd150;
			6'd25: sin_lut =  10'sd128;
			6'd26: sin_lut =  10'sd104;
			6'd27: sin_lut =  10'sd79;
			6'd28: sin_lut =  10'sd53;
			6'd29: sin_lut =  10'sd27;
			6'd30: sin_lut =  10'sd0;
			6'd31: sin_lut = -10'sd27;
			6'd32: sin_lut = -10'sd53;
			6'd33: sin_lut = -10'sd79;
			6'd34: sin_lut = -10'sd104;
			6'd35: sin_lut = -10'sd128;
			6'd36: sin_lut = -10'sd150;
			6'd37: sin_lut = -10'sd171;
			6'd38: sin_lut = -10'sd190;
			6'd39: sin_lut = -10'sd207;
			6'd40: sin_lut = -10'sd222;
			6'd41: sin_lut = -10'sd234;
			6'd42: sin_lut = -10'sd243;
			6'd43: sin_lut = -10'sd250;
			6'd44: sin_lut = -10'sd255;
			6'd45: sin_lut = -10'sd256;
			6'd46: sin_lut = -10'sd255;
			6'd47: sin_lut = -10'sd250;
			6'd48: sin_lut = -10'sd243;
			6'd49: sin_lut = -10'sd234;
			6'd50: sin_lut = -10'sd222;
			6'd51: sin_lut = -10'sd207;
			6'd52: sin_lut = -10'sd190;
			6'd53: sin_lut = -10'sd171;
			6'd54: sin_lut = -10'sd150;
			6'd55: sin_lut = -10'sd128;
			6'd56: sin_lut = -10'sd104;
			6'd57: sin_lut = -10'sd79;
			6'd58: sin_lut = -10'sd53;
			6'd59: sin_lut = -10'sd27;
			default: sin_lut = 10'sd0;
		endcase
	endfunction

	// cos(idx * 6 deg) * 256 = sin((idx + 15) mod 60)
	function signed [9 : 0] cos_lut(input [5 : 0] idx);
		cos_lut = sin_lut((idx < 6'd45) ? (idx + 6'd15) : (idx - 6'd45));
	endfunction

	// hour mark: square of half-size TICK_HS at (tx, ty) relative to centre
	function in_tick(
		input signed [12 : 0] px,
		input signed [12 : 0] py,
		input signed [12 : 0] tx,
		input signed [12 : 0] ty
	);
		in_tick =	(px >= (tx - TICK_HS)) && (px <= (tx + TICK_HS)) &&
					(py >= (ty - TICK_HS)) && (py <= (ty + TICK_HS));
	endfunction

	// per-frame line-start constants, precomputed vs the hand index:
	//   f0_dot(idx) = -CX*sin - CY*(-cos)   f0_crs(idx) = -CX*(-cos) + CY*sin
	// a table lookup replaces the once-per-frame multiply (keeps the
	// datapath multiplier-free).
	function signed [23 : 0] f0_dot_lut(input [5 : 0] idx);
		case(idx)
			6'd0:  f0_dot_lut =  24'sd138240;
			6'd1:  f0_dot_lut =  24'sd111780;
			6'd2:  f0_dot_lut =  24'sd84120;
			6'd3:  f0_dot_lut =  24'sd55380;
			6'd4:  f0_dot_lut =  24'sd26520;
			6'd5:  f0_dot_lut = -24'sd3000;
			6'd6:  f0_dot_lut = -24'sd32220;
			6'd7:  f0_dot_lut = -24'sd61560;
			6'd8:  f0_dot_lut = -24'sd90060;
			6'd9:  f0_dot_lut = -24'sd117720;
			6'd10:  f0_dot_lut = -24'sd144000;
			6'd11:  f0_dot_lut = -24'sd168480;
			6'd12:  f0_dot_lut = -24'sd190620;
			6'd13:  f0_dot_lut = -24'sd211380;
			6'd14:  f0_dot_lut = -24'sd230220;
			6'd15:  f0_dot_lut = -24'sd245760;
			6'd16:  f0_dot_lut = -24'sd259380;
			6'd17:  f0_dot_lut = -24'sd268620;
			6'd18:  f0_dot_lut = -24'sd275940;
			6'd19:  f0_dot_lut = -24'sd280800;
			6'd20:  f0_dot_lut = -24'sd282240;
			6'd21:  f0_dot_lut = -24'sd279720;
			6'd22:  f0_dot_lut = -24'sd274740;
			6'd23:  f0_dot_lut = -24'sd266760;
			6'd24:  f0_dot_lut = -24'sd255780;
			6'd25:  f0_dot_lut = -24'sd242760;
			6'd26:  f0_dot_lut = -24'sd226200;
			6'd27:  f0_dot_lut = -24'sd207060;
			6'd28:  f0_dot_lut = -24'sd185880;
			6'd29:  f0_dot_lut = -24'sd163620;
			6'd30:  f0_dot_lut = -24'sd138240;
			6'd31:  f0_dot_lut = -24'sd111780;
			6'd32:  f0_dot_lut = -24'sd84120;
			6'd33:  f0_dot_lut = -24'sd55380;
			6'd34:  f0_dot_lut = -24'sd26520;
			6'd35:  f0_dot_lut =  24'sd3000;
			6'd36:  f0_dot_lut =  24'sd32220;
			6'd37:  f0_dot_lut =  24'sd61560;
			6'd38:  f0_dot_lut =  24'sd90060;
			6'd39:  f0_dot_lut =  24'sd117720;
			6'd40:  f0_dot_lut =  24'sd144000;
			6'd41:  f0_dot_lut =  24'sd168480;
			6'd42:  f0_dot_lut =  24'sd190620;
			6'd43:  f0_dot_lut =  24'sd211380;
			6'd44:  f0_dot_lut =  24'sd230220;
			6'd45:  f0_dot_lut =  24'sd245760;
			6'd46:  f0_dot_lut =  24'sd259380;
			6'd47:  f0_dot_lut =  24'sd268620;
			6'd48:  f0_dot_lut =  24'sd275940;
			6'd49:  f0_dot_lut =  24'sd280800;
			6'd50:  f0_dot_lut =  24'sd282240;
			6'd51:  f0_dot_lut =  24'sd279720;
			6'd52:  f0_dot_lut =  24'sd274740;
			6'd53:  f0_dot_lut =  24'sd266760;
			6'd54:  f0_dot_lut =  24'sd255780;
			6'd55:  f0_dot_lut =  24'sd242760;
			6'd56:  f0_dot_lut =  24'sd226200;
			6'd57:  f0_dot_lut =  24'sd207060;
			6'd58:  f0_dot_lut =  24'sd185880;
			6'd59:  f0_dot_lut =  24'sd163620;
			default: f0_dot_lut = 24'sd0;
		endcase
	endfunction

	function signed [23 : 0] f0_crs_lut(input [5 : 0] idx);
		case(idx)
			6'd0:  f0_crs_lut =  24'sd245760;
			6'd1:  f0_crs_lut =  24'sd259380;
			6'd2:  f0_crs_lut =  24'sd268620;
			6'd3:  f0_crs_lut =  24'sd275940;
			6'd4:  f0_crs_lut =  24'sd280800;
			6'd5:  f0_crs_lut =  24'sd282240;
			6'd6:  f0_crs_lut =  24'sd279720;
			6'd7:  f0_crs_lut =  24'sd274740;
			6'd8:  f0_crs_lut =  24'sd266760;
			6'd9:  f0_crs_lut =  24'sd255780;
			6'd10:  f0_crs_lut =  24'sd242760;
			6'd11:  f0_crs_lut =  24'sd226200;
			6'd12:  f0_crs_lut =  24'sd207060;
			6'd13:  f0_crs_lut =  24'sd185880;
			6'd14:  f0_crs_lut =  24'sd163620;
			6'd15:  f0_crs_lut =  24'sd138240;
			6'd16:  f0_crs_lut =  24'sd111780;
			6'd17:  f0_crs_lut =  24'sd84120;
			6'd18:  f0_crs_lut =  24'sd55380;
			6'd19:  f0_crs_lut =  24'sd26520;
			6'd20:  f0_crs_lut = -24'sd3000;
			6'd21:  f0_crs_lut = -24'sd32220;
			6'd22:  f0_crs_lut = -24'sd61560;
			6'd23:  f0_crs_lut = -24'sd90060;
			6'd24:  f0_crs_lut = -24'sd117720;
			6'd25:  f0_crs_lut = -24'sd144000;
			6'd26:  f0_crs_lut = -24'sd168480;
			6'd27:  f0_crs_lut = -24'sd190620;
			6'd28:  f0_crs_lut = -24'sd211380;
			6'd29:  f0_crs_lut = -24'sd230220;
			6'd30:  f0_crs_lut = -24'sd245760;
			6'd31:  f0_crs_lut = -24'sd259380;
			6'd32:  f0_crs_lut = -24'sd268620;
			6'd33:  f0_crs_lut = -24'sd275940;
			6'd34:  f0_crs_lut = -24'sd280800;
			6'd35:  f0_crs_lut = -24'sd282240;
			6'd36:  f0_crs_lut = -24'sd279720;
			6'd37:  f0_crs_lut = -24'sd274740;
			6'd38:  f0_crs_lut = -24'sd266760;
			6'd39:  f0_crs_lut = -24'sd255780;
			6'd40:  f0_crs_lut = -24'sd242760;
			6'd41:  f0_crs_lut = -24'sd226200;
			6'd42:  f0_crs_lut = -24'sd207060;
			6'd43:  f0_crs_lut = -24'sd185880;
			6'd44:  f0_crs_lut = -24'sd163620;
			6'd45:  f0_crs_lut = -24'sd138240;
			6'd46:  f0_crs_lut = -24'sd111780;
			6'd47:  f0_crs_lut = -24'sd84120;
			6'd48:  f0_crs_lut = -24'sd55380;
			6'd49:  f0_crs_lut = -24'sd26520;
			6'd50:  f0_crs_lut =  24'sd3000;
			6'd51:  f0_crs_lut =  24'sd32220;
			6'd52:  f0_crs_lut =  24'sd61560;
			6'd53:  f0_crs_lut =  24'sd90060;
			6'd54:  f0_crs_lut =  24'sd117720;
			6'd55:  f0_crs_lut =  24'sd144000;
			6'd56:  f0_crs_lut =  24'sd168480;
			6'd57:  f0_crs_lut =  24'sd190620;
			6'd58:  f0_crs_lut =  24'sd211380;
			6'd59:  f0_crs_lut =  24'sd230220;
			default: f0_crs_lut = 24'sd0;
		endcase
	endfunction

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
	// time base: one frame tick per frame, 60 frames = 1 second
	// ------------------------------------------------------------------

	wire frame_tick = (timing_h_pos == 0) && (timing_v_pos == 0);

	reg		[5 : 0]		frame_cnt	= 0;
	reg		[5 : 0]		sec_idx		= init_sec;
	reg		[5 : 0]		min_idx		= init_min;
	reg		[3 : 0]		min12_cnt	= INIT_MIN12;
	reg		[5 : 0]		hour_idx	= INIT_HIDX;

	always@(posedge pixel_clock)begin

		if(reset)begin

			frame_cnt	<= 0;
			sec_idx		<= init_sec;
			min_idx		<= init_min;
			min12_cnt	<= INIT_MIN12;
			hour_idx	<= INIT_HIDX;

		end else if(frame_tick)begin

			if(frame_cnt == 6'd59)begin

				frame_cnt <= 0;

				if(sec_idx == 6'd59)begin

					sec_idx <= 0;
					min_idx <= (min_idx == 6'd59) ? 6'd0 : (min_idx + 1'b1);

					if(min12_cnt == 4'd11)begin
						min12_cnt <= 0;
						hour_idx <= (hour_idx == 6'd59) ? 6'd0 : (hour_idx + 1'b1);
					end else begin
						min12_cnt <= min12_cnt + 1'b1;
					end

				end else begin
					sec_idx <= sec_idx + 1'b1;
				end

			end else begin
				frame_cnt <= frame_cnt + 1'b1;
			end
		end
	end

	// hand direction vectors in screen coordinates (y grows downwards):
	// angle is clockwise from 12 o'clock -> (sx, sy) = (sin, -cos)
	// indices only change during vblank, so these are stable per frame.
	reg signed	[9 : 0]		sc_sx = 0, sc_sy = 0;
	reg signed	[9 : 0]		mn_sx = 0, mn_sy = 0;
	reg signed	[9 : 0]		hr_sx = 0, hr_sy = 0;

	always@(posedge pixel_clock)begin
		sc_sx <= sin_lut(sec_idx);
		sc_sy <= -cos_lut(sec_idx);
		mn_sx <= sin_lut(min_idx);
		mn_sy <= -cos_lut(min_idx);
		hr_sx <= sin_lut(hour_idx);
		hr_sy <= -cos_lut(hour_idx);
	end

	// ------------------------------------------------------------------
	// per-line accumulators (updated once per line, after active region)
	// ------------------------------------------------------------------

	wire line_step	= (timing_h_pos == (T_HVIS_END + 1));
	wire frame_load	= (timing_v_pos == (T_VVIS_BEGIN - 1));

	reg signed	[12 : 0]	dy_line	= 0;
	reg signed	[26 : 0]	ls_r2	= 0;
	reg signed	[23 : 0]	ls_dot_s, ls_crs_s;
	reg signed	[23 : 0]	ls_dot_m, ls_crs_m;
	reg signed	[23 : 0]	ls_dot_h, ls_crs_h;

	always@(posedge pixel_clock)begin
		if(line_step)begin
			if(frame_load)begin
				dy_line		<= -CENTER_Y;
				ls_r2		<= CX_SQ + CY_SQ;
				ls_dot_s	<= f0_dot_lut(sec_idx);		ls_crs_s <= f0_crs_lut(sec_idx);
				ls_dot_m	<= f0_dot_lut(min_idx);		ls_crs_m <= f0_crs_lut(min_idx);
				ls_dot_h	<= f0_dot_lut(hour_idx);	ls_crs_h <= f0_crs_lut(hour_idx);
			end else begin
				dy_line		<= dy_line + 1'b1;
				ls_r2		<= ls_r2 + (dy_line <<< 1) + 1'b1;
				ls_dot_s	<= ls_dot_s + sc_sy;	ls_crs_s <= ls_crs_s - sc_sx;
				ls_dot_m	<= ls_dot_m + mn_sy;	ls_crs_m <= ls_crs_m - mn_sx;
				ls_dot_h	<= ls_dot_h + hr_sy;	ls_crs_h <= ls_crs_h - hr_sx;
			end
		end
	end

	// ------------------------------------------------------------------
	// stage 0: per-pixel accumulators (loaded at start of each line)
	// ------------------------------------------------------------------

	wire pix_load = (timing_h_pos == (T_HVIS_BEGIN - 1));

	reg signed	[12 : 0]	dx;
	reg signed	[26 : 0]	r2;
	reg signed	[23 : 0]	dot_s, crs_s;
	reg signed	[23 : 0]	dot_m, crs_m;
	reg signed	[23 : 0]	dot_h, crs_h;

	always@(posedge pixel_clock)begin
		if(pix_load)begin
			dx		<= -CENTER_X;
			r2		<= ls_r2;
			dot_s	<= ls_dot_s;	crs_s <= ls_crs_s;
			dot_m	<= ls_dot_m;	crs_m <= ls_crs_m;
			dot_h	<= ls_dot_h;	crs_h <= ls_crs_h;
		end else begin
			dx		<= dx + 1'b1;
			r2		<= r2 + (dx <<< 1) + 1'b1;
			dot_s	<= dot_s + sc_sx;	crs_s <= crs_s + sc_sy;
			dot_m	<= dot_m + mn_sx;	crs_m <= crs_m + mn_sy;
			dot_h	<= dot_h + hr_sx;	crs_h <= crs_h + hr_sy;
		end
	end

	// ------------------------------------------------------------------
	// stage 1: shape flags
	// ------------------------------------------------------------------

	// hour marks at radius 370: (370*sin(k*30), -370*cos(k*30))
	wire tick_hit =
		in_tick(dx, dy_line,  13'sd0,   -13'sd370) |
		in_tick(dx, dy_line,  13'sd185, -13'sd320) |
		in_tick(dx, dy_line,  13'sd320, -13'sd185) |
		in_tick(dx, dy_line,  13'sd370,  13'sd0  ) |
		in_tick(dx, dy_line,  13'sd320,  13'sd185) |
		in_tick(dx, dy_line,  13'sd185,  13'sd320) |
		in_tick(dx, dy_line,  13'sd0,    13'sd370) |
		in_tick(dx, dy_line, -13'sd185,  13'sd320) |
		in_tick(dx, dy_line, -13'sd320,  13'sd185) |
		in_tick(dx, dy_line, -13'sd370,  13'sd0  ) |
		in_tick(dx, dy_line, -13'sd320, -13'sd185) |
		in_tick(dx, dy_line, -13'sd185, -13'sd320);

	reg		ring_s1, face_s1, dot_s1, tick_s1;
	reg		sec_s1, min_s1, hr_s1;

	always@(posedge pixel_clock)begin

		ring_s1	<= (r2 >= RING_R2_IN) && (r2 <= RING_R2_OUT);
		face_s1	<= (r2 <  RING_R2_IN);
		dot_s1	<= (r2 <= CENTER_R2);
		tick_s1	<= tick_hit;

		sec_s1	<=	(dot_s >= -(SEC_TAIL << 8)) && (dot_s <= (SEC_LEN << 8)) &&
					(crs_s >= -(SEC_HW  << 8)) && (crs_s <= (SEC_HW  << 8));

		min_s1	<=	(dot_m >= -(MIN_TAIL << 8)) && (dot_m <= (MIN_LEN << 8)) &&
					(crs_m >= -(MIN_HW  << 8)) && (crs_m <= (MIN_HW  << 8));

		hr_s1	<=	(dot_h >= -(HR_TAIL << 8)) && (dot_h <= (HR_LEN << 8)) &&
					(crs_h >= -(HR_HW  << 8)) && (crs_h <= (HR_HW  << 8));
	end

	// ------------------------------------------------------------------
	// stage 2: colour priority mux
	// ------------------------------------------------------------------

	reg		[23 : 0]	pixel_s2;

	always@(posedge pixel_clock)begin

		if(dot_s1)			pixel_s2 <= COL_DOT;
		else if(sec_s1)		pixel_s2 <= COL_SEC;
		else if(min_s1)		pixel_s2 <= COL_MIN;
		else if(hr_s1)		pixel_s2 <= COL_HR;
		else if(tick_s1)	pixel_s2 <= COL_TICK;
		else if(ring_s1)	pixel_s2 <= COL_RING;
		else if(face_s1)	pixel_s2 <= COL_FACE;
		else				pixel_s2 <= COL_BG;
	end

	// ------------------------------------------------------------------
	// sync delay line matching the 2-stage pixel pipeline
	// ------------------------------------------------------------------

	localparam PIPE_LEN = 2;

	reg		[PIPE_LEN-1 : 0]	den_dly, hsync_dly, vsync_dly, line_start_dly;

	always@(posedge pixel_clock)begin
		den_dly			<= {den_dly[PIPE_LEN-2 : 0], den_int};
		hsync_dly		<= {hsync_dly[PIPE_LEN-2 : 0], hsync_int};
		vsync_dly		<= {vsync_dly[PIPE_LEN-2 : 0], vsync_int};
		line_start_dly	<= {line_start_dly[PIPE_LEN-2 : 0], line_start_int};
	end

	wire den_out = den_dly[PIPE_LEN-1];

	assign video_den		= den_out;
	assign video_hsync		= hsync_dly[PIPE_LEN-1];
	assign video_vsync		= vsync_dly[PIPE_LEN-1];
	assign video_line_start	= line_start_dly[PIPE_LEN-1];

	assign video_pixel_even	= den_out ? pixel_s2 : 24'h000000;
	assign video_pixel_odd	= den_out ? pixel_s2 : 24'h000000;

endmodule

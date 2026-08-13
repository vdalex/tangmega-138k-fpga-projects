`timescale 1ns / 1ns

//
// Fractal music generator with visualisation, on the Tang Mega 138K.
//
// A logistic map composes, and the bifurcation diagram of that same map fills
// the screen with a playhead riding along it - so what you see is literally
// where the notes are coming from. Below the first bifurcation the orbit is a
// fixed point and one note repeats; past it the orbit splits and a two-note
// figure appears, then four, then chaos, and inside the chaos are windows
// (the period-3 one at r ~ 3.83 is unmistakable) where a clear motif returns.
//
// The orbit is not reseeded when the sweep wraps, so the forty-second journey
// keeps its shape while the notes never repeat - see LOOP_REPEATS in
// logistic_seq.v, which turns that off for verification against the model.
//
// An earlier version drew a live Julia set for c = r(2-r)/4 above the diagram,
// the two being conjugate maps. julia_core.v is still in the tree; it was
// dropped from the build because the diagram is the better picture.
//
// Sound goes out over the board's I2S DAC. HDMI audio would need real HDMI -
// data islands, TERC4, clock regeneration, InfoFrames - which the DVI
// transmitter here does not do, so that is a separate project.
//
// EVERYTHING runs on the 75 MHz pixel clock, audio included. There is no
// simulator for this board, and a clock domain crossing is exactly the sort of
// fault that is expensive to find without one. That single decision fixes the
// audio rates: BCK is 75 MHz / 49 and the sample rate is BCK / 32 = 47831.6 Hz,
// which is the number tools/music_model.py is told to use. See the I2S section
// for why 49 - it is 6 cents from 48 kHz, where 48 would have been 30.
//
// The output is 1280x720. At 1080p this would not close timing - sharing the
// die and the clock with the audio engine left every failing path dominated by
// routing rather than logic, and there was no logic left to remove.
//
module top (
	input			clk,			// 50 MHz oscillator (V22)

	// HDMI
	output			tmds_clk_p_0,
	output			tmds_clk_n_0,
	output	[2 : 0]	tmds_d_p_0,
	output	[2 : 0]	tmds_d_n_0,

	// on-board I2S DAC
	output			HP_BCK,
	output			HP_WS,
	output			HP_DIN,
	output			PA_EN,

	output	[3 : 0]	led				// active low; see the .cst
);

	// ------------------------------------------------------------------
	// clocks and reset
	// ------------------------------------------------------------------

	wire	pll_lock, pixel_clock, serial_clock;

	Gowin_PLL_Video pll0(
		.lock		(pll_lock),
		.clkout0	(pixel_clock),		// 75 MHz
		.clkout1	(serial_clock),		// 375 MHz, 5x DDR bit clock
		.clkin		(clk)
	);

	reg	[3 : 0]	rst_cnt = 4'd0;
	always@(posedge pixel_clock)begin
		if(!pll_lock)			rst_cnt <= 4'd0;
		else if(!rst_cnt[3])	rst_cnt <= rst_cnt + 1'b1;
	end
	wire reset = ~rst_cnt[3];

	// ------------------------------------------------------------------
	// the composer
	// ------------------------------------------------------------------

	localparam NOTE_DIV = 5979;			// SR / 8 notes per second

	wire			sample_tick;		// from the DAC frame; see pt8211_tx
	reg	[12 : 0]	note_div = 13'd0;
	reg				note_tick = 1'b0;

	always@(posedge pixel_clock)begin
		note_tick <= 1'b0;
		if(reset)begin
			note_div <= 13'd0;
		end else if(sample_tick)begin
			if(note_div == (NOTE_DIV - 1))begin
				note_div  <= 13'd0;
				note_tick <= 1'b1;
			end else begin
				note_div <= note_div + 1'b1;
			end
		end
	end

	wire	[4 : 0]		degree;
	wire				is_bass;
	wire	[7 : 0]		note_pan;
	wire				note_stb;
	wire	[17 : 0]	x_cur, r_val;
	wire	[9 : 0]		sweep_idx;
	wire				orbit_clamped;

	// r for the current position and the Julia constant that matches it, from
	// one table so the music and the picture cannot disagree - see sweep_rom.v.
	sweep_rom sweep0(
		.clk	(pixel_clock),
		.addr	(sweep_idx),
		.r_val	(r_val),
		.c_re	()			// the Julia set is not drawn any more; see music_video.v
	);

	logistic_seq seq0(
		.clk		(pixel_clock),
		.reset		(reset),
		.note_tick	(note_tick),
		.r_val		(r_val),
		.degree		(degree),
		.is_bass	(is_bass),
		.pan		(note_pan),
		.note_stb	(note_stb),
		.x_cur		(x_cur),
		.sweep_idx	(sweep_idx),
		.clamp_hit	(orbit_clamped)
	);

	// degree -> phase increment. The ROM is registered, so the increment lands
	// a cycle after note_stb; delay the note event to match.
	wire	[31 : 0]	note_inc;

	note_rom notes0(
		.clk	(pixel_clock),
		.addr	(degree),
		.data	(note_inc)
	);

	reg			note_stb_d;
	reg	[7 : 0]	note_pan_d;
	reg			is_bass_d;
	always@(posedge pixel_clock)begin
		note_stb_d <= note_stb;
		note_pan_d <= note_pan;
		is_bass_d  <= is_bass;
	end

	// ------------------------------------------------------------------
	// the synthesiser and the room
	// ------------------------------------------------------------------

	wire	[8 : 0]			wave_addr;
	wire signed [15 : 0]	wave_data;

	wave_rom waves0(
		.clk	(pixel_clock),
		.addr	(wave_addr),
		.data	(wave_data)
	);

	wire signed [15 : 0]	dry_l, dry_r;
	wire					dry_stb;
	wire					synth_clip;

	synth8 synth0(
		.clk		(pixel_clock),
		.reset		(reset),
		.sample_tick(sample_tick),
		.note_stb	(note_stb_d),
		.note_inc	(note_inc),
		.note_pan	(note_pan_d),
		.note_bass	(is_bass_d),
		.wave_addr	(wave_addr),
		.wave_data	(wave_data),
		.out_l		(dry_l),
		.out_r		(dry_r),
		.out_stb	(dry_stb),
		.clip		(synth_clip)
	);

	wire signed [15 : 0]	wet_l, wet_r;
	wire					wet_stb;

	pingpong delay0(
		.clk	(pixel_clock),
		.reset	(reset),
		.in_stb	(dry_stb),
		.in_l	(dry_l),
		.in_r	(dry_r),
		.out_l	(wet_l),
		.out_r	(wet_r),
		.out_stb(wet_stb)
	);

	// The DAC takes whatever is latched when its frame turns over, so the
	// effect chain only has to keep up - which it does with room to spare: the
	// synth walk is 50 clocks and the delay 7, against 1568 between frames.
	reg signed [15 : 0]	play_l, play_r;
	always@(posedge pixel_clock)
		if(wet_stb)begin
			play_l <= wet_l;
			play_r <= wet_r;
		end

	// ------------------------------------------------------------------
	// the DAC
	// ------------------------------------------------------------------
	//
	// One clock domain for the whole design, this included - see pt8211_tx.v
	// for why the bits go out on the falling edge of BCK and why there is no
	// separate bit clock any more.
	//
	// The divider sets the sample rate: 75 MHz / 49 / 32 = 47831.6 Hz, six
	// cents below 48 kHz. It has to be a uniform divide - the DAC converts on
	// each word select edge, so the frame rate IS its conversion clock and
	// dithering a fractional divider to average out at exactly 48 kHz would
	// put that jitter straight into the audio. tools/music_model.py is told
	// the same 47832, so the increments baked into note_rom.vh give the
	// pitches heard in the preview.

	pt8211_tx #(
		.DIV	(49),
		.HALF	(24)
	)dac0(
		.clk			(pixel_clock),
		.reset			(reset),
		.sample_l		(play_l),
		.sample_r		(play_r),
		.sample_tick	(sample_tick),
		.bck			(HP_BCK),
		.ws				(HP_WS),
		.din			(HP_DIN)
	);

	assign PA_EN = 1'b0;

	// ------------------------------------------------------------------
	// c = r(2 - r)/4  -  the conjugacy that ties the picture to the music
	// ------------------------------------------------------------------
	//
	// Looked up rather than computed: see c_rom.v for why. The table is
	// indexed by the same sweep position that drives the playhead, so the
	// shape on screen and the note being played can never drift apart.

	// ------------------------------------------------------------------
	// the screen
	// ------------------------------------------------------------------

	wire	[23 : 0]	dvi_data;
	wire				dvi_den, dvi_hsync, dvi_vsync;

	// 320 notes across 1280 pixels: the playhead is the sweep index times 4.
	// Registered because it is otherwise a shift-and-add hanging off the
	// sequencer, feeding comparators on the far side of the die - it was the
	// last path holding the clock down. The playhead moves eight times a
	// second, so a cycle of latency is not a concept that applies.
	reg	[10 : 0]	head_x = 11'd0;
	always@(posedge pixel_clock)
		head_x <= {sweep_idx[8 : 0], 2'b00};

	music_video video0(
		.pixel_clock		(pixel_clock),
		.reset				(reset),
		.head_x				(head_x),
		.video_vsync		(dvi_vsync),
		.video_hsync		(dvi_hsync),
		.video_den			(dvi_den),
		.video_line_start	(),
		.video_pixel_even	(dvi_data),
		.video_pixel_odd	()
	);

	// VIDEO_OFF holds the transmitter in reset so the TMDS lines stop
	// switching. The audio is clean digitally by every measure available, yet
	// the analogue output is modulated - and the one thing sharing this board
	// with the DAC that could do that is three differential pairs slamming at
	// 375 MHz. If the tone cleans up with this set, the fault is coupling, not
	// code. Set back to 0 for a picture.
	localparam VIDEO_OFF = 0;

	dvi_tx_top dvi0(
		.pixel_clock	(pixel_clock),
		.ddr_bit_clock	(serial_clock),
		.reset			(reset | VIDEO_OFF[0]),
		.den			(dvi_den),
		.hsync			(dvi_hsync),
		.vsync			(dvi_vsync),
		.pixel_data		(dvi_data),
		.tmds_clk		({tmds_clk_p_0, tmds_clk_n_0}),
		.tmds_d0		({tmds_d_p_0[0], tmds_d_n_0[0]}),
		.tmds_d1		({tmds_d_p_0[1], tmds_d_n_0[1]}),
		.tmds_d2		({tmds_d_p_0[2], tmds_d_n_0[2]})
	);

	// ------------------------------------------------------------------
	// signs of life (LEDs are active low on this board)
	// ------------------------------------------------------------------

	reg	[25 : 0]	heartbeat = 26'd0;
	always@(posedge pixel_clock)
		heartbeat <= heartbeat + 1'b1;

	// Four health indicators, all latched except the first, so an answer can be
	// read at leisure rather than caught in the act. Every one of them earned
	// its place during bring-up; between them they say whether the fabric is
	// running, whether audio is flowing, whether the mix is overdriven and
	// whether the composer's arithmetic still holds its invariant.
	//
	// The LEDs on this board are ACTIVE LOW - driving 0 lights them - so each
	// flag is inverted on its way out.

	reg	samp_seen  = 1'b0;		// the DAC frame is running at all
	reg	orbit_bad  = 1'b0;		// the map left [0,1) and had to be clamped

	always@(posedge pixel_clock)begin
		if(reset)begin
			samp_seen <= 1'b0;
			orbit_bad <= 1'b0;
		end else begin
			if(sample_tick)		samp_seen <= 1'b1;
			if(orbit_clamped)	orbit_bad <= 1'b1;
		end
	end

	assign led[0] = heartbeat[24];		// T18: blinks - the fabric is running
	assign led[1] = ~samp_seen;			// R18: lit  - sample frames are flowing
	assign led[2] = ~synth_clip;		// R17: lit  - the mix has hit the rails
	assign led[3] = ~orbit_bad;			// P16: lit  - the orbit escaped [0,1)

	// Normal operation is T18 blinking, R18 lit, R17 and P16 dark.

	wire unused = |{x_cur, r_val, note_pan, wet_stb};

endmodule

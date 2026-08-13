`timescale 1ns / 1ns

//
// Eight-voice synthesiser, time-multiplexed onto one wavetable and one set of
// multipliers.
//
// There are 3072 clocks between samples and eight voices to service, so the
// engine walks them one at a time and is still idle for most of the sample
// period. That is what makes eight voices cost about the same as one: the
// expensive parts are shared, and only per-voice state is replicated.
//
// Two things here are shaped by the tools rather than by the algorithm:
//
//   * The walk is spread over six short stages. Reading phase[v] and inc[v]
//     is an 8:1 mux on 32-bit words, and doing that plus the add in one cycle
//     was the critical path of the whole design - 84 MHz against a 150 MHz
//     target. Two extra cycles per voice out of ~380 available buys the clock.
//   * Each per-voice array has exactly ONE write statement, with the index and
//     data muxed. Written from two places - a new note, and the walk - the
//     tool infers a dual-port block RAM for eight words and then rejects the
//     write mode it would need, which reads as a baffling error about DPB
//     write modes rather than "this should have been flip-flops".
//
// Per voice, per sample:
//   phase += inc
//   s      = wave[{timbre, phase[31:24]}]
//   a      = s * env >> 16
//   left  += a * (255 - pan) >> 8      right += a * pan >> 8
//   env   -= (env >> DECAY_SH) + 1
//
// Mirrors the voice loop in tools/music_model.py.
//
module synth8 #(
	parameter DECAY_SH	= 13,		// envelope tail, ~0.6 s
	// Matches tools/music_model.py, so the board and the preview WAV are the
	// same piece at the same level. This was briefly set to 3 while chasing a
	// rasp on the assumption the analogue side was being overdriven; it was not
	// - dropping 12 dB changed nothing, and the fault turned out to be in the
	// I2S driver. Left at the model's value.
	parameter MIX_SH	= 3			// voice sum >> this
)
(
	input					clk,
	input					reset,

	input					sample_tick,	// one pulse per output sample
	input					note_stb,		// a new note is being handed over
	input		[31 : 0]	note_inc,		// its phase increment
	input		[7 : 0]		note_pan,
	input					note_bass,		// selects the sine timbre

	// shared wavetable ROM
	output		[8 : 0]		wave_addr,
	input	signed [15 : 0]	wave_data,

	output reg signed [15 : 0]	out_l,
	output reg signed [15 : 0]	out_r,
	output reg					out_stb,

	// Latches if the mix ever hits the rails. Eight voices at full envelope
	// would sum well past full scale, and whether that actually happens
	// depends on how much they overlap - which is a property of the music, not
	// something worth guessing at. So measure it instead.
	output reg					clip
);

	function signed [15 : 0] sat16(input signed [31 : 0] val);
		sat16 = (val >  32'sd32767) ?  16'sd32767 :
				(val < -32'sd32768) ? -16'sd32768 : val[15 : 0];
	endfunction

	// ------------------------------------------------------------------
	// per-voice state (a register file, not memory - see the header)
	// ------------------------------------------------------------------

	// These land in 24 SSRAM(RAM16) cells, not flip-flops - the synthesis log
	// says "Extracting RAM for identifier 'phase'" and the same for the other
	// four, and neither (* ram_style = "registers" *) nor the trailing
	// /* synthesis syn_ramstyle = "registers" */ form talks it out of that.
	//
	// Checked rather than fought, and it is fine: RAM16SDP reads
	// asynchronously, so an eight-entry array read combinationally behaves
	// exactly as the flip-flop version would, read-during-write included. The
	// one thing it does cost is the initial block below - distributed RAM comes
	// up zeroed, so pan starts hard left and tbl on the sine instead of the
	// values written there. That washes out after the first eight notes, which
	// is why this is documented rather than worked around.
	reg	[31 : 0]	phase	[0 : 7];
	reg	[31 : 0]	inc		[0 : 7];
	reg	[16 : 0]	env		[0 : 7];		// Q16; 1<<16 is full scale
	reg	[7 : 0]		pan		[0 : 7];
	reg				tbl		[0 : 7];

	integer i;
	initial begin
		for(i = 0; i < 8; i = i + 1)begin
			phase[i] = 32'd0;
			inc[i]   = 32'd0;
			env[i]   = 17'd0;				// silent until a note arrives
			pan[i]   = 8'd128;
			tbl[i]   = 1'b1;
		end
	end

	reg	[2 : 0]	next_v = 3'd0;				// round-robin allocation

	// ------------------------------------------------------------------
	// the walk
	// ------------------------------------------------------------------

	localparam S_IDLE = 3'd0, S_SEL = 3'd1, S_ADD  = 3'd2, S_FETCH = 3'd3,
			   S_MUL  = 3'd4, S_PAN = 3'd5, S_ACC  = 3'd6, S_DONE  = 3'd7;

	reg	[2 : 0]		st = S_IDLE;
	reg	[2 : 0]		v  = 3'd0;

	// the selected voice's state, held while it is worked on
	reg	[31 : 0]	ph_sel, inc_sel, ph_next;
	reg	[16 : 0]	env_sel;
	reg	[7 : 0]		pan_sel;
	reg				tbl_sel;

	// The product must be formed at FULL width before it is shifted. Written as
	//     a_scaled <= (wave_data * env) >>> 16;
	// with a_scaled 18 bits, Verilog sizes the whole right-hand side from the
	// assignment context - so the 34-bit product is truncated to 18 bits BEFORE
	// the shift, and what reaches the DAC is noise. It sounded exactly like
	// that on hardware. Keeping the product in its own wide net fixes it.
	wire signed [33 : 0] a_full = wave_data * $signed({1'b0, env_sel});

	// After the shift the value fits in 17 bits (|wave| <= 32767, env <= 1<<16),
	// which keeps the pan multiplies down to one DSP each.
	reg	signed [17 : 0]	a_scaled;
	reg	signed [31 : 0]	pan_l, pan_r;		// this voice's contribution
	reg	signed [31 : 0]	acc_l, acc_r;

	assign wave_addr = {tbl_sel, ph_next[31 : 24]};

	// ------------------------------------------------------------------
	// single write port per array
	// ------------------------------------------------------------------
	//
	// A note and the walk can want to write in the same cycle. The note wins;
	// the cost is that one voice misses a single phase step and one envelope
	// decrement, which at 48 kHz is inaudible.

	wire	[16 : 0]	env_decayed = (env[v] > ((env[v] >> DECAY_SH) + 1))
									? (env[v] - ((env[v] >> DECAY_SH) + 1))
									: 17'd0;

	wire				wr_note = note_stb;
	wire	[2 : 0]		wi      = wr_note ? next_v : v;

	// A silent voice is frozen, and a new note resumes the phase where the last
	// one left it. Both of those matter, and neither is arbitrary - they are
	// what tools/music_model.py does, and the preview WAV is the target.
	//
	// This used to zero the phase on every new note and keep advancing it while
	// the voice was silent. With a sawtooth, where a note starts in its cycle
	// decides how the voices line up against each other, so restarting them all
	// at zero made the chord sum differently from the preview - which is what
	// "the harmony is wrong" turned out to mean. It is not an edge case either:
	// an envelope reaches zero after ~18000 samples and a voice is only
	// re-triggered every ~48000, so voices are silent most of the time.
	//
	// Bonus: phase now has a single writer at a single index, which is exactly
	// what keeps the tool from inferring block RAM for it.
	wire				voice_live = |env_sel;
	wire				ph_we = (st == S_FETCH) & voice_live;

	wire				en_we = wr_note | (st == S_ACC);
	wire	[16 : 0]	en_wd = wr_note ? 17'h1_0000 : env_decayed;

	always@(posedge clk)begin
		if(ph_we)	phase[v] <= ph_next;
		if(en_we)	env[wi]  <= en_wd;
		if(wr_note)begin
			// Halving the phase increment IS the octave drop. The model does
			// this (oct_mul = 0.5) and an earlier version of this file carried
			// only the timbre change across, which left the music with no bass
			// line under the chord - it read as "no harmony".
			inc[wi] <= note_bass ? {1'b0, note_inc[31 : 1]} : note_inc;
			pan[wi] <= note_pan;
			tbl[wi] <= ~note_bass;			// bass -> table 0 (sine)
		end
	end

	always@(posedge clk)
		if(reset)			next_v <= 3'd0;
		else if(wr_note)	next_v <= next_v + 1'b1;

	// ------------------------------------------------------------------
	// the state machine
	// ------------------------------------------------------------------

	always@(posedge clk)begin
		out_stb <= 1'b0;

		if(reset)begin
			st    <= S_IDLE;
			acc_l <= 32'sd0;
			acc_r <= 32'sd0;
			clip  <= 1'b0;
		end else case(st)

		S_IDLE: if(sample_tick)begin
				v     <= 3'd0;
				acc_l <= 32'sd0;
				acc_r <= 32'sd0;
				st    <= S_SEL;
			end

		S_SEL: begin							// mux only
				ph_sel  <= phase[v];
				inc_sel <= inc[v];
				env_sel <= env[v];
				pan_sel <= pan[v];
				tbl_sel <= tbl[v];
				st      <= S_ADD;
			end

		S_ADD: begin							// add only
				ph_next <= ph_sel + inc_sel;
				st      <= S_FETCH;
			end

		S_FETCH: st <= S_MUL;					// wavetable read in flight

		S_MUL: begin
				a_scaled <= a_full >>> 16;
				st       <= S_PAN;
			end

		// The pan multiplies and the accumulate get a cycle each. Together they
		// were the last thing holding the clock down - a DSP feeding straight
		// into a 32-bit adder is a long way for one cycle.
		S_PAN: begin
				pan_l <= (a_scaled * $signed({1'b0, 8'd255 - pan_sel})) >>> 8;
				pan_r <= (a_scaled * $signed({1'b0, pan_sel})) >>> 8;
				st    <= S_ACC;
			end

		S_ACC: begin
				acc_l <= acc_l + pan_l;
				acc_r <= acc_r + pan_r;
				if(v == 3'd7)	st <= S_DONE;	// let the last add land
				else begin
					v  <= v + 1'b1;
					st <= S_SEL;
				end
			end

		S_DONE: begin
				out_l   <= sat16(acc_l >>> MIX_SH);
				out_r   <= sat16(acc_r >>> MIX_SH);
				out_stb <= 1'b1;
				st      <= S_IDLE;

				if(((acc_l >>> MIX_SH) >  32'sd32767) ||
				   ((acc_l >>> MIX_SH) < -32'sd32768) ||
				   ((acc_r >>> MIX_SH) >  32'sd32767) ||
				   ((acc_r >>> MIX_SH) < -32'sd32768))
					clip <= 1'b1;
			end

		default: st <= S_IDLE;
		endcase
	end

endmodule

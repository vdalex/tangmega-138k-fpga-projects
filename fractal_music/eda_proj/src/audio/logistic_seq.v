`timescale 1ns / 1ns

//
// The composer: sweeps the logistic map and emits note events.
//
// x <- r*x*(1-x) in Q3.15, ITERS steps per note - see the parameter. Everything musical falls out of
// where r happens to be: below the first bifurcation the orbit is a fixed
// point and one note repeats; past it the orbit splits and a two-note figure
// appears, then four, then eight, then chaos - and inside the chaos there are
// windows (the period-3 one at r ~ 3.83 is unmistakable) where a clear motif
// returns. That structure is the composition; nothing here scripts it.
//
// The number format is set by the silicon, not by taste. The DSP blocks on
// this part are 18x18, so at Q3.15 each of the two products is exactly one DSP
// and one cycle. A Q2.30 version needed 32x32, which the tool builds as a
// cascade of DSPs and adders - it held the entire design to 83 MHz against a
// 150 MHz target. Fifteen fractional bits is far finer than the structure that
// matters here.
//
// r comes from a table rather than an accumulator so this visits exactly the r
// values tools/music_model.py does. With a chaotic map, "very nearly the same"
// is a different piece of music.
//
// One note takes 6 clocks and notes are 6000 clocks apart, so this is idle
// almost always and one multiplier does both products.
//
module logistic_seq #(
	parameter FRAC			= 15,
	parameter N_DEGREES		= 15,
	parameter SWEEP_TICKS	= 320,		// notes in one pass across the diagram

	// Map iterations per note. The screen shows the ATTRACTOR at each r - every
	// column of the diagram is drawn after 300 settling iterations - while the
	// music steps the map as r sweeps past. With one step per note the orbit is
	// forever chasing the attractor and never catches it: measured against the
	// diagram, that was 46 notes behind, nearly six seconds and 184 pixels.
	//
	// Where it hurts most is the first bifurcation. Convergence there is
	// critically slow - the multiplier of the fixed point goes to 1 as r
	// approaches 3, so the orbit settles algebraically rather than
	// geometrically - and that is exactly the moment the eye is watching the
	// diagram split in two. It also matters at the start of every lap, because
	// with LOOP_REPEATS = 0 the orbit arrives at r = 2.8 from deep in chaos and
	// has to find the fixed point again.
	//
	// Measured, note the diagram splits at (54) versus the note the two-note
	// figure becomes audible:
	//
	//     7 steps -> note 63, +9 notes,  36 px      127 steps -> note 54, exact
	//    31 steps -> note 57, +3 notes,  12 px
	//
	// The count must be COPRIME with the period of every window worth hearing,
	// or the motif collapses: 15 and 63 are divisible by three and turn the
	// period-3 window - the most striking figure in the piece - into one
	// repeated note. 127 is prime, so only period-7... only period-127 windows
	// suffer, and those do not exist at this resolution.
	//
	// Cost is 127 x 4 = 508 clocks out of the 5979 between notes.
	parameter ITERS			= 127,

	// 0 = the orbit carries over between laps, so the piece never repeats.
	// 1 = reseed each lap, which reproduces docs/preview.wav exactly and is
	//     what makes the board comparable with the model. See state 5.
	parameter LOOP_REPEATS	= 0
)
(
	input				clk,
	input				reset,
	input				note_tick,		// one pulse per note

	// r for this note, from r_rom, indexed by sweep_idx
	input	[17 : 0]	r_val,

	output	reg	[4 : 0]		degree,		// scale degree for this note
	output	reg				is_bass,	// octave down, and the sine timbre
	output	reg	[7 : 0]		pan,		// 0 = hard left, 255 = hard right
	output	reg				note_stb,	// pulses when the three above are valid

	output	reg	[17 : 0]	x_cur,		// current orbit point
	output	reg	[9 : 0]		sweep_idx,	// position along the diagram

	// Latches if the clamp above ever has to act. On paper it cannot; if this
	// lights, the arithmetic in this module is not doing what it reads like.
	output	reg				clamp_hit
);

	localparam [17 : 0] ONE      = 18'd1 << FRAC;		// 1.0 = 32768
	localparam [7 : 0]  PAN_MIN  = 8'd40;
	localparam [7 : 0]  PAN_SPAN = 8'd175;				// PAN_MAX - PAN_MIN

	reg	[2 : 0]		st;
	reg	[7 : 0]		it_cnt;					// up to 255 iterations per note
	reg	[17 : 0]	x;
	reg	[17 : 0]	t_term;
	reg	[35 : 0]	sq;
	reg	[7 : 0]		note_i;

	// One register per product, not one shared by both. Sharing meant a single
	// 36-bit register fed by two different 18x18 multiplies through a mux,
	// which is the exact shape a tool wants to fold into a DSP's own output
	// register - and a DSP output register that does not keep its clock enable
	// latches a product on every cycle, including the one where the state
	// machine reads the previous result back out.
	reg	[35 : 0]	p_t;					// x * (1 - x)
	reg	[35 : 0]	p_x;					// r * t

	// Explicitly 18 bits wide. Written inline as x * (ONE - x) against a
	// 36-bit destination, the subtraction is evaluated at 36 bits as well,
	// which is not the same thing the moment x is out of range.
	wire	[17 : 0]	one_minus_x = ONE - x;

	// The orbit cannot leave [0,1) on paper: x(1-x) peaks at 0.25 and the
	// largest r in the sweep is 3.996, so x tops out at 32736 against
	// ONE = 32768. The hardware disagreed - a diagnostic latch caught the orbit
	// escaping while r was verified in range - and the failure is permanent
	// once it happens, because the next (ONE - x) wraps in unsigned arithmetic
	// and the sequence never comes back. This clamp makes that state
	// unreachable. It never fires in tools/music_model.py, where the orbit
	// peaks at 32386, so it cannot alter the music - only keep it alive.
	wire	[17 : 0]	x_raw  = p_x[FRAC + 17 : FRAC];
	wire				x_over = (x_raw >= ONE);
	wire	[17 : 0]	x_next = x_over ? (ONE - 18'd1) : x_raw;

	// Same trap as in the synth: pan is 8 bits, so writing
	//     pan <= PAN_MIN + ((x * PAN_SPAN) >> FRAC);
	// sizes the product from the destination and truncates x*175 - which needs
	// 26 bits - down to 18 before the shift. The result is a random pan per
	// note instead of a considered one.
	wire	[25 : 0]	pan_full = x * PAN_SPAN;

	always@(posedge clk)begin
		note_stb <= 1'b0;

		if(reset)begin
			st			<= 3'd0;
			it_cnt		<= 8'd0;
			x			<= ONE >> 1;				// 0.5, the model's seed
			x_cur		<= ONE >> 1;
			note_i		<= 8'd0;
			sweep_idx	<= 10'd0;
			clamp_hit	<= 1'b0;
		end else case(st)

		// idle until the note grid ticks
		3'd0: if(note_tick)begin
				it_cnt <= 8'd0;
				st     <= 3'd1;
			end

		3'd1: begin
				p_t <= x * one_minus_x;				// one 18x18 DSP
				st  <= 3'd2;
			end

		3'd2: begin
				t_term <= p_t[FRAC + 17 : FRAC];	// t = x(1-x)
				st     <= 3'd3;
			end

		3'd3: begin
				p_x <= r_val * t_term;				// the second DSP
				st  <= 3'd4;
			end

		3'd4: begin
				x         <= x_next;				// x = r*t, held inside [0,1)
				x_cur     <= x_next;
				clamp_hit <= clamp_hit | x_over;

				// Round again until ITERS steps have been taken; only the last
				// one becomes a note.
				if(it_cnt == (ITERS - 1))begin
					st <= 3'd5;
				end else begin
					it_cnt <= it_cnt + 1'b1;
					st     <= 3'd1;
				end
			end

		// Square before scaling to a degree: the orbit crowds the top of its
		// range, and squaring spreads that region across the scale instead of
		// bunching every note onto the highest few notes.
		3'd5: begin
				sq <= x * x;
				st <= 3'd6;
			end

		3'd6: begin
				degree   <= ((sq[FRAC + 17 : FRAC] * N_DEGREES) >> FRAC) > (N_DEGREES - 1)
							? (N_DEGREES - 1)
							: ((sq[FRAC + 17 : FRAC] * N_DEGREES) >> FRAC);
				pan      <= PAN_MIN + (pan_full >> FRAC);
				is_bass  <= ((note_i + 1'b1) & 8'd3) == 8'd0;	// every 4th note

				note_i    <= note_i + 1'b1;
				note_stb  <= 1'b1;
				st        <= 3'd0;

				// What happens at the end of a lap decides whether the piece
				// repeats. LOOP_REPEATS = 0 leaves the orbit alone, so the next
				// pass starts wherever this one finished; in the chaotic half
				// of the diagram a different starting point is a different
				// piece, so the notes never come round again while the shape of
				// the journey - calm, period doubling, chaos, the period-3
				// window - stays recognisable every forty seconds.
				//
				// LOOP_REPEATS = 1 reseeds to 0.5 and every pass is identical
				// to docs/preview.wav. That is a verification mode, not a
				// musical one: it is what allowed the board to be compared with
				// the model sample for sample, which is how several real bugs
				// were finally cornered. Worth turning back on before trusting
				// any change to the composer.
				if(sweep_idx == (SWEEP_TICKS - 1))begin
					sweep_idx <= 10'd0;
					if(LOOP_REPEATS)begin
						x     <= ONE >> 1;
						x_cur <= ONE >> 1;
					end
				end else begin
					sweep_idx <= sweep_idx + 1'b1;
				end
			end

		default: st <= 3'd0;
		endcase
	end

endmodule

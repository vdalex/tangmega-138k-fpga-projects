`timescale 1ns / 1ns

//
// Serial transmitter for the board's PT8211 DAC.
//
// The datasheet is specific about two things, and both shape this module:
//
//   * "Each valid DIN data will be shifted to the input register in the RISING
//     edge of the BCK." So the FPGA must have DIN settled before that edge.
//   * "When the WS clock is in the Low level, the DIN data will be shifted to
//     the RIGHT input register" - low is right, high is left. Note that this
//     is the opposite of what Sipeed's audio_drive.v claims in its comments,
//     and that example does play its channels swapped. Nobody notices on a
//     mono test tone.
//
// The format is LSB-justified ("Japanese"), two's complement, MSB first. With
// exactly sixteen bit-clocks per half-frame the sixteen bits after a word
// select transition are also the sixteen before the next one, so LSBJ and
// left-justified coincide here and there is no offset to get wrong.
//
// DIN AND WS CHANGE ON THE FALLING EDGE. That is the whole point of this file.
// The reference driver hands the bit clock straight to the pin and clocks its
// output registers on the same edge, so data changes exactly when the DAC
// samples - the setup time is zero, and whether it works depends on which of
// the two signals happens to reach the DAC first through the routing. It did
// work, for a while, on one placement. Presenting on the falling edge instead
// gives a full half period: 24 pixel clocks, 320 ns, against a part rated to
// 20 MHz. Hold after the sampling edge is the other 25 counts.
//
// Everything runs on the pixel clock. An earlier version generated a real bit
// clock and ran the driver on it, which put a clock domain crossing between
// the frame counter and the rest of the design - unconstrained, because the
// tool invents its own frequency for a fabric-divided clock - and an occasional
// mis-sampled sample_tick moved every phase accumulator in the synth off the
// grid. That reads as notes drifting out of tune, not as a glitch, and it took
// a long time to find. There is no second clock here now.
//
// DIV is pixel clocks per bit period. 49 gives 75 MHz / 49 / 32 = 47831.6 Hz,
// six cents below 48 kHz - see the sample rate note in tools/music_model.py
// for why a uniform divider is required and why 48 is worse than 49.
//
module pt8211_tx #(
	parameter DIV	= 49,				// pixel clocks per BCK period
	parameter HALF	= 24				// ...of which BCK is low for this many
)
(
	input					clk,		// the pixel clock; no other domain
	input					reset,

	input	signed	[15 : 0]	sample_l,
	input	signed	[15 : 0]	sample_r,

	output	reg				sample_tick,	// one pulse per stereo frame
	output	reg				bck,
	output	reg				ws,
	output	reg				din
);

	reg	[5 : 0]		div;
	reg	[4 : 0]		slot;				// bit position within the 32-bit frame
	reg	[15 : 0]	shift;

	wire	[4 : 0]	slot_n = slot + 1'b1;

	always@(posedge clk)begin
		sample_tick <= 1'b0;

		if(reset)begin
			div   <= 6'd0;
			slot  <= 5'd31;				// so the first falling edge starts at 0
			bck   <= 1'b0;
			ws    <= 1'b1;
			din   <= 1'b0;
			shift <= 16'd0;
		end else if(div == (DIV - 1))begin

			// ---- falling edge: present the next bit and the word select ----
			//
			// Everything the DAC will latch changes here, together, HALF counts
			// before the edge that latches it.
			div  <= 6'd0;
			bck  <= 1'b0;
			slot <= slot_n;

			if(slot_n == 5'd0)begin
				// left channel, and a whole frame has gone by
				din         <= sample_l[15];
				shift       <= {sample_l[14 : 0], 1'b0};
				ws          <= 1'b1;			// HIGH is left on this part
				sample_tick <= 1'b1;
			end else if(slot_n == 5'd16)begin
				din   <= sample_r[15];
				shift <= {sample_r[14 : 0], 1'b0};
				ws    <= 1'b0;					// LOW is right
			end else begin
				din   <= shift[15];
				shift <= {shift[14 : 0], 1'b0};
			end

		end else begin
			div <= div + 1'b1;

			// ---- rising edge: the DAC samples DIN and WS here ----
			if(div == (HALF - 1))
				bck <= 1'b1;
		end
	end

endmodule

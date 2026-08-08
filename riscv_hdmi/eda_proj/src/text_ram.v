`timescale 1ns / 1ns

//
// Text buffer shared between the CPU and the video generator.
//
// The CPU writes characters over its data-memory AHB port (the same 64-bit
// "ddr/sram" port data_ram sits on, decoded to a separate address window in
// top.v); the video side reads them out a byte at a time on the pixel clock.
//
// It is WRITE-ONLY from the bus: reads return zero. That is deliberate - with
// one write port and one read port each byte lane infers as a simple dual-port
// BSRAM with independent clocks, which is exactly what is needed here. Letting
// the CPU read back as well would demand a third access per lane, which block
// RAM cannot do. The firmware never reads the screen, so nothing is lost.
//
// Layout: byte address = {row, col} with a stride of 128, i.e. row * 128 + col.
// A power-of-two stride keeps the video address a plain concatenation instead
// of a multiply.
//
module text_ram #(
	parameter AW = 10					// 64-bit-word address width (1024 x 8B = 8 KB)
)
(
	// ---- CPU side: AHB-lite, 64-bit, zero wait states ----
	input				hclk,
	input	[31 : 0]	haddr,
	input	[1 : 0]		htrans,
	input				hwrite,
	input	[2 : 0]		hsize,
	input	[63 : 0]	hwdata,
	output	[63 : 0]	hrdata,
	output				hready,
	output				hresp,

	// ---- video side: byte reads, TWO cycles of latency ----
	input				vclk,
	input	[AW+2 : 0]	vaddr,			// byte address
	output	reg	[7 : 0]	vdata
);

	localparam DEPTH = 1 << AW;

	(* ram_style = "block" *) reg [7 : 0] mem0 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem1 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem2 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem3 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem4 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem5 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem6 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem7 [0 : DEPTH-1];

	// ---------------- CPU write port ----------------

	wire				sel  = htrans[1] & hwrite;
	wire	[AW-1 : 0]	widx = haddr[AW+2 : 3];

	reg		[7 : 0]		be;
	always@(*)begin
		case(hsize)
			3'd0:	be = 8'h01 << haddr[2 : 0];			// byte
			3'd1:	be = 8'h03 << {haddr[2 : 1], 1'b0};	// halfword
			3'd2:	be = 8'h0F << {haddr[2], 2'b00};		// word
			default:be = 8'hFF;							// doubleword
		endcase
	end

	// address phase -> data phase (hwdata is valid one cycle after the address)
	reg					wr_d	= 1'b0;
	reg		[AW-1 : 0]	idx_d	= {AW{1'b0}};
	reg		[7 : 0]		be_d	= 8'd0;

	always@(posedge hclk)begin
		wr_d  <= sel;
		idx_d <= widx;
		be_d  <= be;
	end

	always@(posedge hclk)begin
		if(wr_d)begin
			if(be_d[0])	mem0[idx_d] <= hwdata[7  :  0];
			if(be_d[1])	mem1[idx_d] <= hwdata[15 :  8];
			if(be_d[2])	mem2[idx_d] <= hwdata[23 : 16];
			if(be_d[3])	mem3[idx_d] <= hwdata[31 : 24];
			if(be_d[4])	mem4[idx_d] <= hwdata[39 : 32];
			if(be_d[5])	mem5[idx_d] <= hwdata[47 : 40];
			if(be_d[6])	mem6[idx_d] <= hwdata[55 : 48];
			if(be_d[7])	mem7[idx_d] <= hwdata[63 : 56];
		end
	end

	assign hrdata = 64'd0;				// write-only, see the header
	assign hready = 1'b1;
	assign hresp  = 1'b0;

	// ---------------- video read port ----------------

	wire	[AW-1 : 0]	vidx = vaddr[AW+2 : 3];

	reg		[7 : 0]		q0, q1, q2, q3, q4, q5, q6, q7;
	reg		[2 : 0]		vsel;

	always@(posedge vclk)begin
		q0 <= mem0[vidx];	q1 <= mem1[vidx];
		q2 <= mem2[vidx];	q3 <= mem3[vidx];
		q4 <= mem4[vidx];	q5 <= mem5[vidx];
		q6 <= mem6[vidx];	q7 <= mem7[vidx];
		vsel <= vaddr[2 : 0];
	end

	reg		[7 : 0]		vmux;
	always@(*)begin
		case(vsel)
			3'd0:	vmux = q0;
			3'd1:	vmux = q1;
			3'd2:	vmux = q2;
			3'd3:	vmux = q3;
			3'd4:	vmux = q4;
			3'd5:	vmux = q5;
			3'd6:	vmux = q6;
			default:vmux = q7;
		endcase
	end

	// Registered, deliberately. Leaving the lane mux combinational put the
	// BSRAM output, this 8:1 mux and the caller's character decode all in one
	// 150 MHz cycle, and the pixel clock only reached 112 MHz.
	always@(posedge vclk)
		vdata <= vmux;

endmodule

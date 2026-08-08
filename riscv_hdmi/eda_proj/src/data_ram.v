`timescale 1ns / 1ns

//
// Read/write data memory for the AE350 hard core, in fabric BSRAM.
//
// Sits on the core's "ddr/sram" AHB port, which serves the data-memory region
// 0x00000000..0x7FFFFFFF. The core's own DLM at 0xA0200000 is NOT present in
// this configuration - a store/readback test on hardware came back wrong - so
// this is where .data, .bss and the stack live instead.
//
// The port is 64 BITS WIDE (DDR_HWDATA/DDR_HRDATA are [63:0] in the primitive;
// it is meant to face a DDR3 controller). A 32-bit store therefore lands in
// the upper or lower half depending on address bit 2, which is why the byte
// lanes below are driven from HSIZE together with haddr[2:0].
//
// AHB-lite slave, zero wait states (HREADY tied high).
//
// One subtlety worth spelling out: on AHB the data phase of a write overlaps
// the address phase of the next transfer, so a load immediately following a
// store to the same word would read the memory before the write commits. A
// stack does exactly that, so the read path bypasses the in-flight write.
//
module data_ram #(
	parameter AW = 12					// 64-bit-word address width (4096 x 8B = 32 KB)
)
(
	input				hclk,

	input	[31 : 0]	haddr,
	input	[1 : 0]		htrans,
	input				hwrite,
	input	[2 : 0]		hsize,
	input	[63 : 0]	hwdata,

	output	[63 : 0]	hrdata,
	output				hready,
	output				hresp
);

	localparam DEPTH = 1 << AW;

	// one BSRAM per byte lane, so sb/sh/sw/sd all work
	(* ram_style = "block" *) reg [7 : 0] mem0 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem1 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem2 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem3 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem4 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem5 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem6 [0 : DEPTH-1];
	(* ram_style = "block" *) reg [7 : 0] mem7 [0 : DEPTH-1];

	// ---------------- address phase ----------------

	wire				sel  = htrans[1];			// NONSEQ or SEQ
	wire	[AW-1 : 0]	widx = haddr[AW+2 : 3];		// 8-byte granularity

	// byte lanes within the 64-bit bus, from the transfer size and address
	reg		[7 : 0]		be;
	always@(*)begin
		case(hsize)
			3'd0:	be = 8'h01 << haddr[2 : 0];			// byte
			3'd1:	be = 8'h03 << {haddr[2 : 1], 1'b0};	// halfword
			3'd2:	be = 8'h0F << {haddr[2], 2'b00};		// word
			default:be = 8'hFF;							// doubleword
		endcase
	end

	reg					wr_d	= 1'b0;
	reg		[AW-1 : 0]	idx_d	= {AW{1'b0}};
	reg		[7 : 0]		be_d	= 8'd0;

	always@(posedge hclk)begin
		wr_d  <= sel & hwrite;
		idx_d <= widx;
		be_d  <= be;
	end

	// ---------------- data phase: commit the write ----------------

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

	// ---------------- read, with write-in-flight bypass ----------------

	reg		[63 : 0]	rd_mem;
	always@(posedge hclk)
		rd_mem <= {mem7[widx], mem6[widx], mem5[widx], mem4[widx],
				   mem3[widx], mem2[widx], mem1[widx], mem0[widx]};

	// True when this cycle's address phase targets the word the overlapping
	// write is about to commit; that write's data is then the correct value.
	// The data must be captured here too: by the time hrdata is driven, one
	// cycle later, hwdata already belongs to the following transfer.
	reg					byp;
	reg		[7 : 0]		byp_be;
	reg		[63 : 0]	byp_data;
	always@(posedge hclk)begin
		byp      <= wr_d & (widx == idx_d);
		byp_be   <= be_d;
		byp_data <= hwdata;
	end

	genvar i;
	generate for(i = 0; i < 8; i = i + 1) begin : lane
		assign hrdata[i*8 +: 8] = (byp & byp_be[i]) ? byp_data[i*8 +: 8]
													: rd_mem[i*8 +: 8];
	end endgenerate

	assign hready = 1'b1;
	assign hresp  = 1'b0;

endmodule

`timescale 1ns / 1ns

//
// I2S driver, taken verbatim from Sipeed's audio_i2s example for this board.
//
// Kept unmodified on purpose. Two hand-written versions of this - one textbook
// I2S, one left-justified - both produced artefacts on the DAC that measured
// clean everywhere in the digital path, and reasoning about which edge and
// which bit offset this codec wants was not converging. This code is known to
// drive it correctly, so the sensible move is to stop guessing and use it.
//
// Interface: it asks for a 16-bit word on `req` twice per stereo frame - first
// the left channel, then the right - and expects the word two bit-clocks
// later. Everything runs on the bit clock.
//

//audio驱动
module audio_drive(
    input        clk_1p536m,//bit时钟，每个采样点占32个clk_1p536m(左右声道各16)
    input        rst_n     ,//低电平有效异步复位信号
    //用户数据接口
    input [15:0] idata     ,
    output       req       ,//数据请求信号，可接外部FIFO的读请求(为避免空读，尽量和!fifo_empty相与后作为fifo_rd)
    //audio接口
    output       HP_BCK   ,//同clk_1p536m
    output       HP_WS    ,//左右声道切换信号，低电平对应左声道
    output       HP_DIN    //dac串行数据输入信号
);
reg [4:0] b_cnt;
reg       req_r,req_r1;//req_r1延迟req_r一个时钟
reg [15:0] idata_r;//暂存idata,用于移位并转串时的中间变量
reg HP_WS_r,HP_DIN_r;
assign HP_BCK = clk_1p536m;
assign HP_WS  = HP_WS_r   ;
assign HP_DIN = HP_DIN_r  ;
assign req    = req_r     ;
//b_cnt
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    b_cnt    <= 5'd0;
else
    b_cnt <= b_cnt+1'b1;
end
//req_r
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    req_r <= 1'b0;
else
    req_r <= (b_cnt == 5'd0) || (b_cnt == 5'd16);//每16个时钟读入一个数据
end
//idata_r
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    begin
    req_r1  <= 1'b0;
    idata_r <= 16'd0;
    end
else
    begin
    req_r1  <= req_r;
    idata_r <= req_r1?idata:idata_r<<1;
    end
end
//HP_DIN_r
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    HP_DIN_r <= 1'b0;
else
    HP_DIN_r <= idata_r[15];
end
//HP_WS_r
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    HP_WS_r <= 1'b0;
else
    HP_WS_r <= (b_cnt == 5'd3)?1'b0: ((b_cnt == 5'd19)?1'b1:HP_WS_r);//对齐数据
end
endmodule
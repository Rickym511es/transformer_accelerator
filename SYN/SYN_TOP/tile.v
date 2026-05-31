`timescale 1ns/10ps
// Pure Verilog-2001 rewrite of the MAC tile.
// All multi-dimensional / unpacked-array signals are collapsed to flat
// packed buses so the older synth/APR flow can read it without
// `-format sverilog`.
//
// Bus layouts
//   vecA            : 16 lanes * 256 bits ; lane k at vecA[k*256 +: 256]
//   latch_array     : 16 lanes * 16 cols * 24 bits ; element (lane,col)
//                     at latch_array[(lane*16 + col)*24 +: 24]
//   collector       : same layout as latch_array (internal)
//   partial_sum_in  : 16 lanes * 24 bits  ; lane k at [k*24 +: 24]
//   MAC_result      : 16 lanes * 24 bits  ; lane k at [k*24 +: 24]

module tile(clk, rst_n, vecA, vecB, tile_done, latch_array, start);
    input clk;
    input rst_n;
    input  [16*256-1:0]    vecA;
    input  [255:0]         vecB;
    input  start;
    input  tile_done;
    output reg [16*16*24-1:0] latch_array;

    wire [16*24-1:0] MAC_result;
    reg  [16*24-1:0] partial_sum_in;

    MAC16 MAC_unit (
                .vecA(vecA),
                .vecB(vecB),
                .partial_sum_in(partial_sum_in),
                .result(MAC_result)
                );

    parameter AD = 16;
    reg [4:0] counter;
    reg [16*16*24-1:0] collector;

    // prepare partial_sum_in from collector
    integer k;
    always @(*) begin
        for (k = 0; k < 16; k = k + 1) begin
            if (counter == 0)
                partial_sum_in[k*24 +: 24] = 24'd0;
            else
                partial_sum_in[k*24 +: 24] = collector[(k*16 + (counter-1))*24 +: 24];
        end
    end

    integer i, j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= 0;
            for (i = 0; i < 16; i = i + 1) begin
                for (j = 0; j < AD; j = j + 1) begin
                    collector[(i*16 + j)*24 +: 24] <= 24'b0;
                end
            end
        end
        else if (tile_done) begin
            // commit result
            for (i = 0; i < 16; i = i + 1)
                for (j = 0; j < AD; j = j + 1)
                    latch_array[(i*16 + j)*24 +: 24] <= collector[(i*16 + j)*24 +: 24];

            // clear collector for next tile
            for (i = 0; i < 16; i = i + 1)
                for (j = 0; j < AD; j = j + 1)
                    collector[(i*16 + j)*24 +: 24] <= 24'b0;

            counter <= 0;
        end
        else if (!start) begin
            counter <= 0;
        end
        else begin
            // advance column (vecA reuse)
            if (counter == AD)
                counter <= 0;
            else
                counter <= counter + 1;
            // normal accumulation
            if (counter != 0) begin
                for (i = 0; i < 16; i = i + 1) begin
                    collector[(i*16 + (counter-1))*24 +: 24] <= MAC_result[i*24 +: 24];
                end
            end
        end
    end
endmodule

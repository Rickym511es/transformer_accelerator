`timescale 1ns/1ps

module PPU(
    clk,
    rst_n,
    valid,
    mac_result_vec,
    softmax_valid,
    softmax_result_vec,
    softmax_scale
);
input clk;
input rst_n;
// valid pulses with one full 16x16 MAC tile. Each tile element is signed 24-bit.
input valid;
input signed [16*16*24-1:0] mac_result_vec;
output reg softmax_valid;
// Final int8 quantized softmax output for one 16-element row.
output reg [16*8-1:0] softmax_result_vec;
// Softmax int8 dequant scale, UQ0.24, aligned with softmax_valid.
// softmax_scale = round(2^24 / ((128 - 1) times sum_buffer_real)).
output reg [23:0] softmax_scale;

localparam [23:0] ROUND_Q16 = 24'd32768;
localparam [3:0] LAST_ROW = 4'd15;

reg signed [16*16*24-1:0] tile_buffer;
reg signed [16*40-1:0] softmax_input;

wire tile_start;
wire path1_fire;
wire path2_fire;
wire path1_row_last;
wire path2_row_last;
wire path1_complete;
wire path2_complete;

reg tile_active;
reg path2_mode;
reg [3:0] row_counter;
reg [3:0] path2_row_counter;
reg signed [39:0] max_buffer [0:15];
reg [27:0] sum_buffer [0:15];

wire [3:0] softmax_row_index;
wire signed [16*16*24-1:0] tile_source;

wire signed [39:0] path1_block_max;
reg [27:0] path1_exp_sum;

wire signed [39:0] path2_max_value;
wire [27:0] path2_sum_value;
wire [16:0] path2_reciprocal;
wire [16*8-1:0] path2_quant_comb;
wire [24:0] path2_scale_numer;
wire [23:0] path2_scale_comb;

wire signed [16*40-1:0] shared_exp_data_vec;
wire signed [39:0] shared_exp_max_value;
wire [16*17-1:0] shared_exp_result_vec;

assign tile_start = valid && !tile_active;
assign path1_fire = tile_start || (tile_active && !path2_mode);
assign path2_fire = tile_active && path2_mode;
assign path1_row_last = (row_counter == LAST_ROW);
assign path2_row_last = (path2_row_counter == LAST_ROW);
assign path1_complete = path1_fire && path1_row_last;
assign path2_complete = path2_fire && path2_row_last;

assign softmax_row_index = path2_mode ? path2_row_counter : row_counter;
assign tile_source = tile_start ? mac_result_vec : tile_buffer;

// Bias addition and ReLU are removed for the softmax-only PPU. One internal
// cycle selects one 16x1 row from the buffered 16x16 signed-24b MAC tile and
// converts it directly to Q24.16, matching the old PMS scale.
integer lane_i;
reg signed [23:0] mac_lane_value;
always @(*) begin
    softmax_input = {16*40{1'b0}};
    for (lane_i = 0; lane_i < 16; lane_i = lane_i + 1) begin
        mac_lane_value = tile_source[((softmax_row_index * 16) + lane_i) * 24 +: 24];
        softmax_input[lane_i*40 +: 40] = $signed({{16{mac_lane_value[23]}}, mac_lane_value}) <<< 13;
    end
end

// A full MAC tile is folded through one shared 16-lane LPW exponential bank:
// 16 cycles for path1 max/sum collection, then 16 cycles for path2 output.
vec_max path1_row_max_inst (
    .data_in_vec(softmax_input),
    .max_value  (path1_block_max)
);

assign path2_max_value = max_buffer[path2_row_counter];
assign path2_sum_value = sum_buffer[path2_row_counter];

assign shared_exp_data_vec = softmax_input;
assign shared_exp_max_value = path2_fire ? path2_max_value : path1_block_max;

genvar shared_exp_i;
generate
    for (shared_exp_i = 0; shared_exp_i < 16; shared_exp_i = shared_exp_i + 1) begin : SHARED_EXP_LANE
        LPW_expo shared_exp_inst (
            .data_in(shared_exp_data_vec[shared_exp_i*40 +: 40]),
            .max    (shared_exp_max_value),
            .result (shared_exp_result_vec[shared_exp_i*17 +: 17])
        );
    end
endgenerate

integer path1_exp_sum_i;
always @(*) begin
    path1_exp_sum = 28'd0;
    for (path1_exp_sum_i = 0; path1_exp_sum_i < 16; path1_exp_sum_i = path1_exp_sum_i + 1) begin
        path1_exp_sum = path1_exp_sum + {11'd0, shared_exp_result_vec[path1_exp_sum_i*17 +: 17]};
    end
end

LPW_reciprocal path2_reciprocal_inst (
    .data_in(path2_sum_value),
    .result (path2_reciprocal)
);

genvar path2_i;
generate
    for (path2_i = 0; path2_i < 16; path2_i = path2_i + 1) begin : PATH2_LANE
        wire [16:0] exp_q16;
        wire [23:0] quant_shift_sub_full;
        wire [7:0] quant_shift_sub_round;

        assign exp_q16 = shared_exp_result_vec[path2_i*17 +: 17];
        // The 128 - 1 factor is implemented as (exp_q16 << 7) - exp_q16.
        assign quant_shift_sub_full = ({7'd0, exp_q16} << 7) - {7'd0, exp_q16} + ROUND_Q16;
        assign quant_shift_sub_round = quant_shift_sub_full[23:16];
        assign path2_quant_comb[path2_i*8 +: 8] = quant_shift_sub_round;
    end
endgenerate

// path2_reciprocal is Q1.16. Convert reciprocal/127 into UQ0.24:
// scale_q24 = round((reciprocal_q16 * 2^8) / 127).
assign path2_scale_numer = ({8'd0, path2_reciprocal} << 8) + 25'd63;
assign path2_scale_comb = path2_scale_numer / 7'd127;

integer rst_i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tile_buffer <= {16*16*24{1'b0}};
        tile_active <= 1'b0;
        path2_mode <= 1'b0;
        row_counter <= 4'd0;
        path2_row_counter <= 4'd0;
        softmax_valid <= 1'b0;
        softmax_result_vec <= {16*8{1'b0}};
        softmax_scale <= 24'd0;
        for (rst_i = 0; rst_i < 16; rst_i = rst_i + 1) begin
            max_buffer[rst_i] <= 40'sd0;
            sum_buffer[rst_i] <= 28'd0;
        end
    end
    else begin
        softmax_valid <= 1'b0;

        if (tile_start) begin
            tile_buffer <= mac_result_vec;
            tile_active <= 1'b1;
        end

        if (path1_fire) begin
            max_buffer[row_counter] <= path1_block_max;
            sum_buffer[row_counter] <= path1_exp_sum;

            if (path1_row_last)
                row_counter <= 4'd0;
            else
                row_counter <= row_counter + 4'd1;

            if (path1_complete)
                path2_mode <= 1'b1;
        end

        if (path2_fire) begin
            softmax_result_vec <= path2_quant_comb;
            softmax_scale <= path2_scale_comb;
            softmax_valid <= 1'b1;

            if (path2_row_last)
                path2_row_counter <= 4'd0;
            else
                path2_row_counter <= path2_row_counter + 4'd1;
        end

        if (path2_complete) begin
            tile_active <= 1'b0;
            path2_mode <= 1'b0;
            row_counter <= 4'd0;
            path2_row_counter <= 4'd0;
            for (rst_i = 0; rst_i < 16; rst_i = rst_i + 1) begin
                max_buffer[rst_i] <= 40'sd0;
                sum_buffer[rst_i] <= 28'd0;
            end
        end
    end
end
endmodule

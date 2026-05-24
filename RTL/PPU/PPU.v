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
// One 16x1 MAC result row. Each element is signed 24-bit.
// For each 16x16 tile, feed 16 valid rows on the low-half cycles; the high
// half is used internally to finish the folded LPW calculation.
input valid;
input signed [16*24-1:0] mac_result_vec;
output reg softmax_valid;
// Final int8 quantized softmax output for one 16-element row.
output reg [16*8-1:0] softmax_result_vec;
// Softmax int8 dequant scale, UQ0.24, aligned with softmax_valid.
// softmax_scale = round(2^24 / ((128 - 1) times sum_buffer_real)).
output reg [23:0] softmax_scale;

localparam signed [39:0] MIN_SCORE = {1'b1, 39'd0};
localparam [27:0] SUM_SAT = 28'hfffffff;
localparam [23:0] ROUND_Q16 = 24'd32768;
localparam [3:0] LAST_ROW = 4'd15;
localparam [5:0] LAST_TILE = 6'd63;

reg signed [16*24-1:0] row_buffer;
reg signed [16*40-1:0] softmax_input;

wire path1_low_fire;
wire path1_high_fire;
wire path2_low_fire;
wire path2_high_fire;
wire path1_row_last;
wire path2_row_last;
wire path1_tile_last;
wire path2_tile_last;
wire path1_pass_done;
wire path2_pass_done;

reg path2_mode;
reg half_select;
reg [3:0] row_counter;
reg [3:0] path2_row_counter;
reg [5:0] tile_counter;
reg [5:0] path2_tile_counter;
reg signed [39:0] max_buffer [0:15];
reg [27:0] sum_buffer [0:15];
reg [27:0] path1_exp_sum_lo;
reg [8*8-1:0] path2_quant_lo;

wire signed [16*24-1:0] row_source;
wire signed [39:0] path1_block_max;
wire signed [39:0] path1_previous_max;
wire signed [39:0] path1_new_max;
wire path1_max_unchanged;
wire signed [39:0] path1_delta_exp_data_in;
wire signed [39:0] path1_delta_exp_max;
wire [16:0] path1_max_delta_exp;
wire [27:0] path1_previous_sum;
wire [27:0] path1_previous_sum_adjusted;
wire [27:0] path1_previous_sum_scaled;
wire [44:0] path1_previous_sum_adjusted_full;
wire [28:0] path1_previous_sum_adjusted_wide;
wire [28:0] path1_exp_sum_full;
wire [27:0] path1_current_exp_sum;
wire [28:0] path1_sum_value_wide;
wire [27:0] path1_sum_value;

wire signed [39:0] path2_max_value;
wire [27:0] path2_sum_value;
wire [16:0] path2_reciprocal;
wire [24:0] path2_scale_numer;
wire [23:0] path2_scale_comb;

wire signed [8*40-1:0] folded_exp_data_vec;
wire signed [39:0] folded_exp_max_value;
wire [8*17-1:0] folded_exp_result_vec;
reg [27:0] folded_exp_sum;
wire [8*8-1:0] path2_quant_folded_comb;
wire [16*8-1:0] path2_quant_row_comb;

assign path1_low_fire = valid && !path2_mode && !half_select;
assign path1_high_fire = !path2_mode && half_select;
assign path2_low_fire = valid && path2_mode && !half_select;
assign path2_high_fire = path2_mode && half_select;

assign path1_row_last = (row_counter == LAST_ROW);
assign path2_row_last = (path2_row_counter == LAST_ROW);
assign path1_tile_last = (tile_counter == LAST_TILE);
assign path2_tile_last = (path2_tile_counter == LAST_TILE);
assign path1_pass_done = path1_high_fire && path1_row_last && path1_tile_last;
assign path2_pass_done = path2_high_fire && path2_row_last && path2_tile_last;

assign row_source = half_select ? row_buffer : mac_result_vec;

// Bias addition and ReLU are removed for the softmax-only PPU. The incoming
// 16x1 signed-24b MAC row is converted directly to Q24.16.
integer lane_i;
reg signed [23:0] mac_lane_value;
always @(*) begin
    softmax_input = {16*40{1'b0}};
    for (lane_i = 0; lane_i < 16; lane_i = lane_i + 1) begin
        mac_lane_value = row_source[lane_i*24 +: 24];
        softmax_input[lane_i*40 +: 40] = $signed({{16{mac_lane_value[23]}}, mac_lane_value}) <<< 13;
    end
end

vec_max path1_row_max_inst (
    .data_in_vec(softmax_input),
    .max_value  (path1_block_max)
);

assign path1_previous_max = max_buffer[row_counter];
assign path1_previous_sum = sum_buffer[row_counter];
assign path1_new_max = (path1_block_max > path1_previous_max) ? path1_block_max : path1_previous_max;
assign path1_max_unchanged = (path1_new_max == path1_previous_max);
assign path1_delta_exp_data_in = path1_max_unchanged ? 40'sd0 : path1_previous_max;
assign path1_delta_exp_max = path1_max_unchanged ? 40'sd0 : path1_new_max;

LPW_expo path1_max_delta_exp_inst (
    .data_in(path1_delta_exp_data_in),
    .max    (path1_delta_exp_max),
    .result (path1_max_delta_exp)
);

assign path1_previous_sum_adjusted_full = path1_previous_sum * path1_max_delta_exp;
assign path1_previous_sum_adjusted_wide = path1_previous_sum_adjusted_full >> 16;
assign path1_previous_sum_scaled = path1_previous_sum_adjusted_wide[28] ? SUM_SAT : path1_previous_sum_adjusted_wide[27:0];
assign path1_previous_sum_adjusted = path1_max_unchanged ? path1_previous_sum : path1_previous_sum_scaled;

assign path2_max_value = max_buffer[path2_row_counter];
assign path2_sum_value = sum_buffer[path2_row_counter];
assign folded_exp_max_value = path2_mode ? path2_max_value : path1_new_max;

genvar folded_i;
generate
    for (folded_i = 0; folded_i < 8; folded_i = folded_i + 1) begin : FOLDED_EXP_LANE
        assign folded_exp_data_vec[folded_i*40 +: 40] =
            half_select ? softmax_input[(folded_i + 8)*40 +: 40] :
                          softmax_input[folded_i*40 +: 40];

        LPW_expo folded_exp_inst (
            .data_in(folded_exp_data_vec[folded_i*40 +: 40]),
            .max    (folded_exp_max_value),
            .result (folded_exp_result_vec[folded_i*17 +: 17])
        );
    end
endgenerate

integer folded_exp_sum_i;
always @(*) begin
    folded_exp_sum = 28'd0;
    for (folded_exp_sum_i = 0; folded_exp_sum_i < 8; folded_exp_sum_i = folded_exp_sum_i + 1) begin
        folded_exp_sum = folded_exp_sum + {11'd0, folded_exp_result_vec[folded_exp_sum_i*17 +: 17]};
    end
end

assign path1_exp_sum_full = {1'b0, path1_exp_sum_lo} + {1'b0, folded_exp_sum};
assign path1_current_exp_sum = path1_exp_sum_full[28] ? SUM_SAT : path1_exp_sum_full[27:0];
assign path1_sum_value_wide = {1'b0, path1_previous_sum_adjusted} + {1'b0, path1_current_exp_sum};
assign path1_sum_value = path1_sum_value_wide[28] ? SUM_SAT : path1_sum_value_wide[27:0];

LPW_reciprocal path2_reciprocal_inst (
    .data_in(path2_sum_value),
    .result (path2_reciprocal)
);

genvar path2_i;
generate
    for (path2_i = 0; path2_i < 8; path2_i = path2_i + 1) begin : PATH2_FOLDED_LANE
        wire [16:0] exp_q16;
        wire [23:0] quant_shift_sub_full;
        wire [7:0] quant_shift_sub_round;

        assign exp_q16 = folded_exp_result_vec[path2_i*17 +: 17];
        // The 128 - 1 factor is implemented as (exp_q16 << 7) - exp_q16.
        assign quant_shift_sub_full = ({7'd0, exp_q16} << 7) - {7'd0, exp_q16} + ROUND_Q16;
        assign quant_shift_sub_round = quant_shift_sub_full[23:16];
        assign path2_quant_folded_comb[path2_i*8 +: 8] = quant_shift_sub_round;
    end
endgenerate

assign path2_quant_row_comb = {path2_quant_folded_comb, path2_quant_lo};

// path2_reciprocal is Q1.16. Convert reciprocal/127 into UQ0.24:
// scale_q24 = round((reciprocal_q16 * 2^8) / 127).
assign path2_scale_numer = ({8'd0, path2_reciprocal} << 8) + 25'd63;
assign path2_scale_comb = path2_scale_numer / 7'd127;

integer rst_i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        row_buffer <= {16*24{1'b0}};
        path2_mode <= 1'b0;
        half_select <= 1'b0;
        row_counter <= 4'd0;
        path2_row_counter <= 4'd0;
        tile_counter <= 6'd0;
        path2_tile_counter <= 6'd0;
        path1_exp_sum_lo <= 28'd0;
        path2_quant_lo <= {8*8{1'b0}};
        softmax_valid <= 1'b0;
        softmax_result_vec <= {16*8{1'b0}};
        softmax_scale <= 24'd0;
        for (rst_i = 0; rst_i < 16; rst_i = rst_i + 1) begin
            max_buffer[rst_i] <= MIN_SCORE;
            sum_buffer[rst_i] <= 28'd0;
        end
    end
    else begin
        softmax_valid <= 1'b0;

        if (path1_low_fire) begin
            row_buffer <= mac_result_vec;
            path1_exp_sum_lo <= folded_exp_sum;
            half_select <= 1'b1;
        end

        if (path1_high_fire) begin
            max_buffer[row_counter] <= path1_new_max;
            sum_buffer[row_counter] <= path1_sum_value;
            path1_exp_sum_lo <= 28'd0;
            half_select <= 1'b0;

            if (path1_row_last) begin
                row_counter <= 4'd0;
                if (path1_tile_last)
                    tile_counter <= 6'd0;
                else
                    tile_counter <= tile_counter + 6'd1;
            end
            else begin
                row_counter <= row_counter + 4'd1;
            end

            if (path1_pass_done)
                path2_mode <= 1'b1;
        end

        if (path2_low_fire) begin
            row_buffer <= mac_result_vec;
            path2_quant_lo <= path2_quant_folded_comb;
            half_select <= 1'b1;
        end

        if (path2_high_fire) begin
            softmax_result_vec <= path2_quant_row_comb;
            softmax_scale <= path2_scale_comb;
            softmax_valid <= 1'b1;
            path2_quant_lo <= {8*8{1'b0}};
            half_select <= 1'b0;

            if (path2_row_last) begin
                path2_row_counter <= 4'd0;
                if (path2_tile_last)
                    path2_tile_counter <= 6'd0;
                else
                    path2_tile_counter <= path2_tile_counter + 6'd1;
            end
            else begin
                path2_row_counter <= path2_row_counter + 4'd1;
            end
        end

        if (path2_pass_done) begin
            path2_mode <= 1'b0;
            half_select <= 1'b0;
            row_counter <= 4'd0;
            path2_row_counter <= 4'd0;
            tile_counter <= 6'd0;
            path2_tile_counter <= 6'd0;
            path1_exp_sum_lo <= 28'd0;
            path2_quant_lo <= {8*8{1'b0}};
            for (rst_i = 0; rst_i < 16; rst_i = rst_i + 1) begin
                max_buffer[rst_i] <= MIN_SCORE;
                sum_buffer[rst_i] <= 28'd0;
            end
        end
    end
end
endmodule

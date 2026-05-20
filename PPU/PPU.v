`timescale 1ns/1ps

module PPU(
    clk,
    rst_n,
    valid,
    mac_result_vec,
    bias,
    softmax_valid,
    softmax_result_vec,
    softmax_scale
);
input clk;
input rst_n;
input valid;
input signed [16*24-1:0] mac_result_vec;
input signed [16*8-1:0] bias;
output reg softmax_valid;
// Final int8 quantized softmax output, 16 packed lanes.
output reg [16*8-1:0] softmax_result_vec;
// Softmax int8 dequant scale, UQ0.24, aligned with softmax_valid.
// softmax_scale = round(2^24 / ((128 - 1) times sum_buffer_real)).
output reg [23:0] softmax_scale;

localparam signed [39:0] MAX_Q16_24 = 40'sh7fffffffff;
localparam signed [47:0] MAX_Q16_24_EXT = 48'sh007fffffffff;
localparam [27:0] SUM_SAT = 28'hfffffff;
localparam [23:0] ROUND_Q16 = 24'd32768;
localparam [3:0] LAST_ROW = 4'd15;
localparam [5:0] LAST_TILE = 6'd63;

wire signed [16*40-1:0] pms_ba_relu_result;
reg signed [16*40-1:0] softmax_input;

wire path1_fire;
wire path2_fire;
wire path1_row_last;
wire path2_row_last;
wire path1_tile_last;
wire path2_tile_last;
wire path1_buffers_done;
wire softmax_done;

reg [3:0] row_counter;
reg [3:0] path2_row_counter;
reg [5:0] tile_counter;
reg [5:0] path2_tile_counter;
reg path2_mode;
reg path1_input_done;
reg path2_input_done;
reg signed [39:0] max_buffer [0:15];
reg [27:0] sum_buffer [0:15];

// Path1 stage 1 registers: combined PMS, bias add, ReLU, then Q16.24 conversion.
reg path1_s1_valid;
reg path1_s1_last;
reg [3:0] path1_s1_row;
reg signed [16*40-1:0] path1_s1_data;

// Path1 stage 2 registers: carry data and new max into the LPW stage.
reg path1_s2_valid;
reg path1_s2_last;
reg [3:0] path1_s2_row;
reg signed [16*40-1:0] path1_s2_data;
reg signed [39:0] path1_s2_new_max;

wire signed [39:0] path1_block_max;
wire signed [39:0] path1_previous_max;
wire signed [39:0] path1_new_max;
wire path1_max_unchanged;
wire signed [39:0] path1_delta_exp_data_in;
wire signed [39:0] path1_delta_exp_max;
wire [16:0] path1_max_delta_exp;
reg [27:0] path1_exp_sum;
wire [27:0] path1_previous_sum;
wire [27:0] path1_previous_sum_adjusted;
wire [27:0] path1_previous_sum_scaled;
wire [44:0] path1_previous_sum_adjusted_full;
wire [28:0] path1_previous_sum_adjusted_wide;
wire [27:0] path1_sum_current;
wire [28:0] path1_sum_value_wide;
wire [27:0] path1_sum_value;

// Path2 stage 1 registers: combined PMS, bias add, ReLU, then Q16.24 conversion.
reg path2_s1_valid;
reg path2_s1_last;
reg [3:0] path2_s1_row;
reg signed [16*40-1:0] path2_s1_data;

wire signed [39:0] path2_s1_max_value;
wire [27:0] path2_s1_sum_value;
wire [16:0] path2_reciprocal;
wire [16*8-1:0] path2_quant_comb;
wire [24:0] path2_scale_numer;
wire [23:0] path2_scale_comb;
wire signed [16*40-1:0] shared_exp_data_vec;
wire signed [39:0] shared_exp_max_value;
wire [16*17-1:0] shared_exp_result_vec;

PMS_BA_ReLU pms_ba_relu_inst (
    .MAC_result (mac_result_vec),
    .scale      (256'd0),
    .bias       (bias),
    .ReLU_result(pms_ba_relu_result)
);

integer lane_i;
reg signed [47:0] relu_q16_24_ext;
always @(*) begin
    softmax_input = {16*40{1'b0}};
    for (lane_i = 0; lane_i < 16; lane_i = lane_i + 1) begin
        relu_q16_24_ext = $signed(pms_ba_relu_result[lane_i*40 +: 40]) <<< 8;
        if (relu_q16_24_ext > MAX_Q16_24_EXT)
            softmax_input[lane_i*40 +: 40] = MAX_Q16_24;
        else
            softmax_input[lane_i*40 +: 40] = relu_q16_24_ext[39:0];
    end
end

// One external valid stream is reused. Path2 can accept its first replay beat
// when path1 stage 3 commits the final max/sum buffers.
assign path1_fire = valid && !path2_mode && !path1_input_done;
assign path2_fire = valid && (path2_mode || path1_buffers_done) && !path2_input_done;
assign path1_row_last = (row_counter == LAST_ROW);
assign path2_row_last = (path2_row_counter == LAST_ROW);
assign path1_tile_last = (tile_counter == LAST_TILE);
assign path2_tile_last = (path2_tile_counter == LAST_TILE);
assign path1_buffers_done = path1_s2_valid && path1_s2_last;
assign softmax_done = path2_s1_valid && path2_s1_last;

// Path1 stage 2: find the new row max and overwrite max/sum buffers.
vec_max path1_row_max_inst (
    .data_in_vec(path1_s1_data),
    .max_value  (path1_block_max)
);

assign path1_previous_max = max_buffer[path1_s1_row];
assign path1_previous_sum = sum_buffer[path1_s1_row];
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
// If the row max did not change, delta is zero and the old row sum passes directly.
assign path1_previous_sum_adjusted = path1_max_unchanged ? path1_previous_sum : path1_previous_sum_scaled;

// Path1 stage 3 adds the new exponential sum into sum_buffer.
// Path1 stage 3 and path2 stage 2 share the 16-lane LPW exponential bank.
assign shared_exp_data_vec = path2_s1_valid ? path2_s1_data : path1_s2_data;
assign shared_exp_max_value = path2_s1_valid ? path2_s1_max_value : path1_s2_new_max;

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

assign path1_sum_current = sum_buffer[path1_s2_row];
assign path1_sum_value_wide = {1'b0, path1_sum_current} + {1'b0, path1_exp_sum};
assign path1_sum_value = path1_sum_value_wide[28] ? SUM_SAT : path1_sum_value_wide[27:0];

// Path2 stage 2 uses the stage-1 input and the row max from max_buffer.
assign path2_s1_max_value = max_buffer[path2_s1_row];

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

// Path2 scale is independent of the LPW exp result, so compute it in parallel
// with path2 stage 2 using the same row index.
assign path2_s1_sum_value = sum_buffer[path2_s1_row];

LPW_reciprocal path2_reciprocal_inst (
    .data_in(path2_s1_sum_value),
    .result (path2_reciprocal)
);

// path2_reciprocal is Q1.16. Convert reciprocal/127 into UQ0.24:
// scale_q24 = round((reciprocal_q16 * 2^8) / 127).
assign path2_scale_numer = ({8'd0, path2_reciprocal} << 8) + 25'd63;
assign path2_scale_comb = path2_scale_numer / 7'd127;

integer rst_i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        row_counter <= 4'd0;
        path2_row_counter <= 4'd0;
        tile_counter <= 6'd0;
        path2_tile_counter <= 6'd0;
        path2_mode <= 1'b0;
        path1_input_done <= 1'b0;
        path2_input_done <= 1'b0;
        path1_s1_valid <= 1'b0;
        path1_s1_last <= 1'b0;
        path1_s1_row <= 4'd0;
        path1_s1_data <= {16*40{1'b0}};
        path1_s2_valid <= 1'b0;
        path1_s2_last <= 1'b0;
        path1_s2_row <= 4'd0;
        path1_s2_data <= {16*40{1'b0}};
        path1_s2_new_max <= 40'sd0;
        path2_s1_valid <= 1'b0;
        path2_s1_last <= 1'b0;
        path2_s1_row <= 4'd0;
        path2_s1_data <= {16*40{1'b0}};
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

        path1_s1_valid <= path1_fire;
        if (path1_fire) begin
            path1_s1_last <= path1_row_last && path1_tile_last;
            path1_s1_row <= row_counter;
            path1_s1_data <= softmax_input;

            if (path1_row_last && path1_tile_last)
                path1_input_done <= 1'b1;

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
        end

        path1_s2_valid <= path1_s1_valid;
        if (path1_s1_valid) begin
            max_buffer[path1_s1_row] <= path1_new_max;
            sum_buffer[path1_s1_row] <= path1_previous_sum_adjusted;
            path1_s2_last <= path1_s1_last;
            path1_s2_row <= path1_s1_row;
            path1_s2_data <= path1_s1_data;
            path1_s2_new_max <= path1_new_max;
        end

        if (path1_s2_valid) begin
            sum_buffer[path1_s2_row] <= path1_sum_value;
        end

        if (path1_buffers_done) begin
            path2_mode <= 1'b1;
            path1_input_done <= 1'b0;
        end

        path2_s1_valid <= path2_fire;
        if (path2_fire) begin
            path2_s1_last <= path2_row_last && path2_tile_last;
            path2_s1_row <= path2_row_counter;
            path2_s1_data <= softmax_input;
            if (path2_row_last && path2_tile_last)
                path2_input_done <= 1'b1;

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

        if (path2_s1_valid) begin
            softmax_result_vec <= path2_quant_comb;
            softmax_scale <= path2_scale_comb;
            softmax_valid <= 1'b1;
        end

        // End of one internal path1+path2 softmax pass. Do not require rst_n;
        // clear row state and the max/sum buffers for the next tile row.
        if (softmax_done) begin
            row_counter <= 4'd0;
            path2_row_counter <= 4'd0;
            tile_counter <= 6'd0;
            path2_tile_counter <= 6'd0;
            path2_mode <= 1'b0;
            path1_input_done <= 1'b0;
            path2_input_done <= 1'b0;
            path1_s1_valid <= 1'b0;
            path1_s2_valid <= 1'b0;
            path2_s1_valid <= 1'b0;
            for (rst_i = 0; rst_i < 16; rst_i = rst_i + 1) begin
                max_buffer[rst_i] <= 40'sd0;
                sum_buffer[rst_i] <= 28'd0;
            end
        end
    end
end
endmodule

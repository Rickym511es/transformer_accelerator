`timescale 1ns/1ps

module PPU(
    clk,
    rst_n,
    valid,
    mac_result_vec,
    bias
);
input clk;
input rst_n;
input valid;
input signed [16*24-1:0] mac_result_vec;
input signed [16*8-1:0] bias;

localparam signed [39:0] MAX_Q16_24 = 40'sh7fffffffff;
localparam signed [47:0] MAX_Q16_24_EXT = 48'sh007fffffffff;
localparam [27:0] SUM_SAT = 28'hfffffff;

wire signed [16*40-1:0] pms_result;
wire signed [16*40-1:0] ba_result;
wire signed [16*40-1:0] relu_result;
reg signed [16*40-1:0] softmax_input;

wire signed [39:0] block_max;
wire signed [39:0] previous_max;
wire signed [39:0] max_value;
wire [16:0] max_delta_exp;
wire [16*17-1:0] exp_result_vec;
reg [27:0] exp_sum;
wire [27:0] previous_sum;
wire [27:0] previous_sum_adjusted;
wire [27:0] sum_value;

reg [3:0] row_counter;
reg signed [39:0] max_buffer [0:15];
reg [27:0] sum_buffer [0:15];

PMS pms_inst (mac_result_vec, 256'd0, pms_result);

BA ba_inst (
    .PMS_result(pms_result),
    .bias      (bias),
    .BA_result (ba_result)
);

ReLU relu_inst (
    .BA_result  (ba_result),
    .ReLU_result(relu_result)
);

integer qconv_i;
reg signed [47:0] qconv_tmp;
always @(*) begin
    softmax_input = {16*40{1'b0}};
    for (qconv_i = 0; qconv_i < 16; qconv_i = qconv_i + 1) begin
        qconv_tmp = $signed(relu_result[qconv_i*40 +: 40]) <<< 8;
        if (qconv_tmp > MAX_Q16_24_EXT)
            softmax_input[qconv_i*40 +: 40] = MAX_Q16_24;
        else
            softmax_input[qconv_i*40 +: 40] = qconv_tmp[39:0];
    end
end

vec_max row_max_inst (
    .data_in_vec(softmax_input),
    .max_value  (block_max)
);

assign previous_max = max_buffer[row_counter];
assign previous_sum = sum_buffer[row_counter];
assign max_value = (block_max > previous_max) ? block_max : previous_max;

genvar exp_i;
generate
    for (exp_i = 0; exp_i < 16; exp_i = exp_i + 1) begin : EXP_LANE
        LPW_expo exp_inst (
            .data_in(softmax_input[exp_i*40 +: 40]),
            .max    (max_value),
            .result (exp_result_vec[exp_i*17 +: 17])
        );
    end
endgenerate

integer exp_sum_i;
always @(*) begin
    exp_sum = 28'd0;
    for (exp_sum_i = 0; exp_sum_i < 16; exp_sum_i = exp_sum_i + 1) begin
        exp_sum = exp_sum + {11'd0, exp_result_vec[exp_sum_i*17 +: 17]};
    end
end

LPW_expo max_delta_exp_inst (
    .data_in(previous_max),
    .max    (max_value),
    .result (max_delta_exp)
);

wire [44:0] previous_sum_adjusted_full;
wire [28:0] previous_sum_adjusted_wide;
wire [28:0] sum_value_wide;

assign previous_sum_adjusted_full = previous_sum * max_delta_exp;
assign previous_sum_adjusted_wide = previous_sum_adjusted_full >> 16;
assign previous_sum_adjusted = previous_sum_adjusted_wide[28] ? SUM_SAT : previous_sum_adjusted_wide[27:0];
assign sum_value_wide = {1'b0, previous_sum_adjusted} + {1'b0, exp_sum};
assign sum_value = sum_value_wide[28] ? SUM_SAT : sum_value_wide[27:0];

integer rst_i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        row_counter <= 4'd0;
        for (rst_i = 0; rst_i < 16; rst_i = rst_i + 1) begin
            max_buffer[rst_i] <= 40'sd0;
            sum_buffer[rst_i] <= 28'd0;
        end
    end
    else if (valid) begin
        max_buffer[row_counter] <= max_value;
        sum_buffer[row_counter] <= sum_value;
        if (row_counter == 4'd15)
            row_counter <= 4'd0;
        else
            row_counter <= row_counter + 4'd1;
    end
end
endmodule

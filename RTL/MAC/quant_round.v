`timescale 1ns/10ps

// quant_round - per-group int16 -> int8 quantization
// Pure Verilog-2001 rewrite: every unpacked array (ports and internal
// nets/regs) is collapsed to a flat packed bus so the older synth/APR
// flow does not need `-format sverilog`.
//
// Bus layouts (lane index k, embedding column c)
//   data_in    : COLS lanes * IN_W  bits ; element c at data_in[c*IN_W +: IN_W]
//   quant_out  : COLS lanes * OUT_W bits ; element c at quant_out[c*OUT_W +: OUT_W]
//   buf_mem    : ROWS rows of COLS*IN_W bits each
//                row r, col c at buf_mem[r][c*IN_W +: IN_W]
//
// Protocol (unchanged)
//  1. Assert `start` for one cycle to begin a new group.
//  2. Drive `data_in` (COLS lanes) with `valid_in` high for ROWS
//     consecutive cycles (FIND_MAX phase). Each row is buffered and
//     folded into the running global absolute max.
//  3. After the last row the module enters QUANTIZE.
//     `scale_valid` pulses for one cycle with `scale = global_max >> 7`.
//     Then `valid_out` goes high for ROWS cycles; each cycle
//     `quant_out` carries one fully-quantized row.

module quant_round #(
    parameter ROWS  = 1024,
    parameter COLS  = 64,
    parameter IN_W  = 16,
    parameter OUT_W = 8
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // control
    input  wire                        start,
    input  wire                        valid_in,

    // data in: one complete row per cycle (packed: COLS * IN_W bits)
    input  wire [COLS*IN_W-1:0]        data_in,

    // outputs
    output reg  [IN_W-1:0]             scale,
    output reg                         scale_valid,
    output reg                         valid_out,
    output reg  [COLS*OUT_W-1:0]       quant_out
);

// --- FSM states ---------------------------------------------------------------
localparam IDLE     = 2'd0,
           FIND_MAX = 2'd1,
           QUANTIZE = 2'd2;

reg [1:0] state;
reg [9:0] row_cnt;

// --- Buffer: 1-D array of wide rows (V2001-legal) ----------------------------
reg [COLS*IN_W-1:0] buf_mem [0:ROWS-1];

// --- Global max accumulator --------------------------------------------------
reg [IN_W-1:0] global_max;

// --- Absolute value per column (combinational) -------------------------------
// data_in element c spans bits [c*IN_W +: IN_W]; its sign bit is
// data_in[c*IN_W + IN_W - 1].
wire [COLS*IN_W-1:0] abs_in;
genvar g;
generate
    for (g = 0; g < COLS; g = g + 1) begin : GEN_ABS
        assign abs_in[g*IN_W +: IN_W] =
            data_in[g*IN_W + IN_W - 1]
                ? (~data_in[g*IN_W +: IN_W] + {{IN_W-1{1'b0}}, 1'b1})
                :  data_in[g*IN_W +: IN_W];
    end
endgenerate

// --- 6-level binary max-reduction tree: COLS leaves -> 1 ---------------------
// COLS is fixed at 64; tree widths are hard-coded to match.
wire [32*IN_W-1:0] t0;
wire [16*IN_W-1:0] t1;
wire [ 8*IN_W-1:0] t2;
wire [ 4*IN_W-1:0] t3;
wire [ 2*IN_W-1:0] t4;
wire [   IN_W-1:0] t5;

generate
    for (g = 0; g < 32; g = g + 1) begin : T0
        assign t0[g*IN_W +: IN_W] =
            (abs_in[(2*g  )*IN_W +: IN_W] >= abs_in[(2*g+1)*IN_W +: IN_W])
                ? abs_in[(2*g  )*IN_W +: IN_W]
                : abs_in[(2*g+1)*IN_W +: IN_W];
    end
    for (g = 0; g < 16; g = g + 1) begin : T1
        assign t1[g*IN_W +: IN_W] =
            (t0[(2*g  )*IN_W +: IN_W] >= t0[(2*g+1)*IN_W +: IN_W])
                ? t0[(2*g  )*IN_W +: IN_W]
                : t0[(2*g+1)*IN_W +: IN_W];
    end
    for (g = 0; g < 8; g = g + 1) begin : T2
        assign t2[g*IN_W +: IN_W] =
            (t1[(2*g  )*IN_W +: IN_W] >= t1[(2*g+1)*IN_W +: IN_W])
                ? t1[(2*g  )*IN_W +: IN_W]
                : t1[(2*g+1)*IN_W +: IN_W];
    end
    for (g = 0; g < 4; g = g + 1) begin : T3
        assign t3[g*IN_W +: IN_W] =
            (t2[(2*g  )*IN_W +: IN_W] >= t2[(2*g+1)*IN_W +: IN_W])
                ? t2[(2*g  )*IN_W +: IN_W]
                : t2[(2*g+1)*IN_W +: IN_W];
    end
    for (g = 0; g < 2; g = g + 1) begin : T4
        assign t4[g*IN_W +: IN_W] =
            (t3[(2*g  )*IN_W +: IN_W] >= t3[(2*g+1)*IN_W +: IN_W])
                ? t3[(2*g  )*IN_W +: IN_W]
                : t3[(2*g+1)*IN_W +: IN_W];
    end
endgenerate
assign t5 = (t4[0*IN_W +: IN_W] >= t4[1*IN_W +: IN_W])
                ? t4[0*IN_W +: IN_W]
                : t4[1*IN_W +: IN_W];

// Fold current row max into running global max.
wire [IN_W-1:0] new_max = (t5 >= global_max) ? t5 : global_max;

// --- Quantization combinational path -----------------------------------------
// Guard against zero-divide when all inputs are zero.
wire [IN_W-1:0] eff_scale = (scale == {IN_W{1'b0}})
                           ? {{IN_W-1{1'b0}}, 1'b1}
                           : scale;

integer q;
reg signed [IN_W:0]          div_result;
reg        [COLS*OUT_W-1:0]  quant_next;
reg signed [IN_W-1:0]        num_signed;

always @(*) begin
    quant_next = {COLS*OUT_W{1'b0}};
    for (q = 0; q < COLS; q = q + 1) begin
        // Read element q out of the current buffered row.
        num_signed = buf_mem[row_cnt][q*IN_W +: IN_W];
        // Sign-extend numerator to IN_W+1 bits; zero-extend denominator.
        div_result = {num_signed[IN_W-1], num_signed}
                   / $signed({1'b0, eff_scale});

        if (div_result[IN_W : OUT_W-1] != {(IN_W-OUT_W+2){div_result[IN_W]}})
            quant_next[q*OUT_W +: OUT_W] = div_result[IN_W] ? 8'h80 : 8'h7F;
        else
            quant_next[q*OUT_W +: OUT_W] = div_result[OUT_W-1:0];
    end
end

// --- FSM ---------------------------------------------------------------------
integer i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= IDLE;
        row_cnt     <= 10'd0;
        global_max  <= {IN_W{1'b0}};
        scale       <= {IN_W{1'b0}};
        scale_valid <= 1'b0;
        valid_out   <= 1'b0;
        quant_out   <= {COLS*OUT_W{1'b0}};
    end
    else begin
        scale_valid <= 1'b0;
        valid_out   <= 1'b0;

        case (state)

            IDLE: begin
                if (start) begin
                    state      <= FIND_MAX;
                    row_cnt    <= 10'd0;
                    global_max <= {IN_W{1'b0}};
                end
            end

            FIND_MAX: begin
                if (valid_in) begin
                    buf_mem[row_cnt] <= data_in;
                    global_max       <= new_max;

                    if (row_cnt == ROWS - 1) begin
                        scale       <= new_max >> 7;
                        scale_valid <= 1'b1;
                        row_cnt     <= 10'd0;
                        state       <= QUANTIZE;
                    end
                    else begin
                        row_cnt <= row_cnt + 1'b1;
                    end
                end
            end

            QUANTIZE: begin
                quant_out <= quant_next;
                valid_out <= 1'b1;

                if (row_cnt == ROWS - 1) begin
                    state   <= IDLE;
                    row_cnt <= 10'd0;
                end
                else begin
                    row_cnt <= row_cnt + 1'b1;
                end
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule

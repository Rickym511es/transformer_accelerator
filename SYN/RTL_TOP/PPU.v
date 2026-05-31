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

// =====================================================================
// PATH-1 PIPELINE (timing fix)
// ---------------------------------------------------------------------
// The original path-1 computed, in a single cycle:
//   vec_max -> new_max -> LPW_expo(delta) -> *prev_sum -> +exp_sum -> sum_buffer
// ~14 ns of logic.  vec_max+LPW_expo alone is ~10.6 ns, so vec_max must be in
// a different cycle from LPW_expo, and the prev_sum rescale multiply needs its
// own cycle too.  Path-1 is therefore pipelined into 4 stages (II still 2
// cycles/row, +2 cycles latency).  The folded 8-LPW engine and the per-row
// low/high split are kept (no extra exp area).  PATH-2 is unchanged.
//
//   Stage M  (launch, on `valid`): vec_max(live row) -> new_max; sample
//            max_buffer/sum_buffer; stash the converted Q24.16 row in a
//            ping-pong buffer (a row must survive M->E0->E1 = 3 cycles while a
//            new row arrives every 2 cycles, hence two buffers).
//   Stage E0 (next cycle): folded LPW on low 8 lanes (max = registered
//            new_max) -> exp_sum_lo; LPW_expo(delta) -> delta_exp.
//   Stage E1 (next cycle): folded LPW on high 8 lanes -> current_exp_sum.
//   Stage A  (next cycle): prev_sum*delta_exp + current_exp_sum -> sum_buffer,
//            new_max -> max_buffer.
//
// Per-row hazard: max_buffer[r]/sum_buffer[r] are read at M and written at A
// (3 cycles later).  Consecutive rows use distinct indices; the same index is
// re-touched only in the next tile (~32-35 cycles later, see top.v feeder), far
// beyond the pipeline depth, so there is no RAW/WAW hazard.
// =====================================================================

reg path2_mode;
reg half_select;                            // PATH-2 low/high selector only
reg [3:0] row_counter;                      // PATH-1 row index at stage M
reg [3:0] path2_row_counter;
reg [5:0] tile_counter;                     // PATH-1 tile index at stage M
reg [5:0] path2_tile_counter;
reg signed [39:0] max_buffer [0:15];
reg [27:0] sum_buffer [0:15];
reg [8*8-1:0] path2_quant_lo;

// ---- ping-pong row buffers for path-1 (M..E1 lifetime) ----
// Holds the *converted* Q24.16 softmax_input snapshot (not raw mac bits) so the
// testbench `force dut.softmax_input` hook still drives the folded exp lanes.
reg signed [16*40-1:0] pp_row [0:1];
reg pp_wr_sel;                              // buffer stage M writes next

// ---- M -> E0 registers ----
reg               e_valid;
reg [3:0]         e_row;
reg               e_row_last, e_tile_last;
reg signed [39:0] e_new_max;
reg signed [39:0] e_prev_max;
reg [27:0]        e_prev_sum;
reg               e_max_unchanged;
reg               e_rd_sel;                 // which pp_row this job lives in

// ---- E0 -> E1 registers ----
reg               e1_valid;
reg [3:0]         e1_row;
reg               e1_row_last, e1_tile_last;
reg signed [39:0] e1_new_max;
reg [27:0]        e1_prev_sum;
reg [16:0]        e1_delta_exp;
reg               e1_max_unchanged;
reg [27:0]        e1_exp_sum_lo;
reg               e1_rd_sel;

// ---- E1 -> A registers ----
reg               a_valid;
reg [3:0]         a_row;
reg               a_row_last, a_tile_last;
reg signed [39:0] a_new_max;
reg [27:0]        a_prev_sum;
reg [16:0]        a_delta_exp;
reg               a_max_unchanged;
reg [27:0]        a_current_exp_sum;

// PATH-2 fire signals (unchanged)
wire path2_low_fire;
wire path2_high_fire;
wire path2_row_last;
wire path2_tile_last;
wire path2_pass_done;

// PATH-2 datapath wires (unchanged)
wire signed [39:0] path2_max_value;
wire [27:0]        path2_sum_value;
wire [16:0]        path2_reciprocal;
wire [24:0]        path2_scale_numer;
wire [23:0]        path2_scale_comb;

// shared folded-exp engine wires
wire signed [16*40-1:0] folded_exp_data_vec;
wire signed [39:0]      folded_exp_max_value;
wire [8*17-1:0]         folded_exp_result_vec;
reg  [27:0]             folded_exp_sum;
wire [8*8-1:0]          path2_quant_folded_comb;
wire [16*8-1:0]         path2_quant_row_comb;

// ---------------------------------------------------------------------
// Q24.16 conversion: signed 24b MAC lane -> Q24.16 (<<<13), 16 lanes.
// ---------------------------------------------------------------------
function [16*40-1:0] to_q2416;
    input signed [16*24-1:0] raw;
    integer li;
    reg signed [23:0] v;
    begin
        to_q2416 = {16*40{1'b0}};
        for (li = 0; li < 16; li = li + 1) begin
            v = raw[li*24 +: 24];
            to_q2416[li*40 +: 40] = $signed({{16{v[23]}}, v}) <<< 13;
        end
    end
endfunction

// =====================================================================
// Single Q24.16 input conversion point (path-1 stage M AND path-2).
// softmax_input is a reg so testbenches can `force` it to inject exact
// Q24.16 scores (tb_PPU_new_quant, tb_softmax) bypassing the <<<13 path.
//
// The feeder (top.v) holds mac_result_vec STABLE across both half-cycles of
// each row (it no longer zeroes on the high half), and tile.v's latch_array
// holds the whole tile until the next tile_done.  So path-2's high cycle can
// read mac_result_vec directly -- no internal row_buffer needed.  Path-1
// snapshots its own copy into pp_row at stage M, so it is independent of this.
// =====================================================================
reg  [16*40-1:0]        softmax_input;
always @(*) softmax_input = to_q2416(mac_result_vec);

// =====================================================================
// PATH-1 stage M (combinational): live row max + buffer reads
// =====================================================================
wire signed [39:0] block_max_live;

vec_max path1_row_max_inst (
    .data_in_vec(softmax_input),
    .max_value  (block_max_live)
);

wire signed [39:0] m_prev_max      = max_buffer[row_counter];
wire [27:0]        m_prev_sum       = sum_buffer[row_counter];
wire signed [39:0] m_new_max        = (block_max_live > m_prev_max) ? block_max_live : m_prev_max;
wire               m_max_unchanged  = (m_new_max == m_prev_max);
wire               m_row_last        = (row_counter == LAST_ROW);
wire               m_tile_last       = (tile_counter == LAST_TILE);
wire               launch1           = valid && !path2_mode;

// =====================================================================
// PATH-1 stage E0 (combinational): delta-exp rescale factor
// =====================================================================
wire signed [39:0] delta_exp_data_in = e_max_unchanged ? 40'sd0 : e_prev_max;
wire signed [39:0] delta_exp_max     = e_max_unchanged ? 40'sd0 : e_new_max;
wire [16:0]        delta_exp_comb;

LPW_expo path1_max_delta_exp_inst (
    .data_in(delta_exp_data_in),
    .max    (delta_exp_max),
    .result (delta_exp_comb)
);

// =====================================================================
// Shared folded-exp engine input mux (path-1 E0/E1 vs path-2)
// ---------------------------------------------------------------------
// Path-1 half selection is driven by the pipeline's OWN valid bits, NOT the
// live `valid` input.  With II=2 feeding, in any cycle exactly one of:
//   e_valid  -> an E0 job is present (process LOW 8 lanes of e_rd_sel's row)
//   e1_valid -> an E1 job is present (process HIGH 8 lanes of e1_rd_sel's row)
// is set.  Using e1_valid keeps the high-half selection correct even when the
// feeder pauses (e.g. the last row of a tile, where `valid` has already
// dropped but the row's E1 stage still has to run).
// (Structural note: e_valid and e1_valid are never both set in the same cycle
//  under the II=2 feed contract, so the single folded engine never collides.)
// =====================================================================
wire               p1_hi    = e1_valid;                 // 1 = E1/high, 0 = E0/low
wire               fold_hi  = path2_mode ? half_select : p1_hi;

// Path-1 folds the buffered Q24.16 row (converted/forced at stage M);
// path-2 folds the live softmax_input.  Single conversion point either way.
wire [16*40-1:0]   fold_src_q = path2_mode ? softmax_input
                                           : pp_row[p1_hi ? e1_rd_sel : e_rd_sel];
assign folded_exp_max_value = path2_mode ? path2_max_value
                                         : (p1_hi ? e1_new_max : e_new_max);

genvar folded_i;
generate
    for (folded_i = 0; folded_i < 8; folded_i = folded_i + 1) begin : FOLDED_EXP_LANE
        assign folded_exp_data_vec[folded_i*40 +: 40] =
            fold_hi ? fold_src_q[(folded_i + 8)*40 +: 40] :
                      fold_src_q[folded_i*40 +: 40];

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

// PATH-1 stage E1 (combinational): full current-row exp sum (lo + hi)
wire [28:0] e1_cur_full = {1'b0, e1_exp_sum_lo} + {1'b0, folded_exp_sum};
wire [27:0] e1_cur_sat  = e1_cur_full[28] ? SUM_SAT : e1_cur_full[27:0];

// PATH-1 stage A (combinational): rescale prev sum and accumulate
wire [44:0] a_adj_full      = a_prev_sum * a_delta_exp;
wire [28:0] a_adj_wide      = a_adj_full >> 16;
wire [27:0] a_adj_scaled    = a_adj_wide[28] ? SUM_SAT : a_adj_wide[27:0];
wire [27:0] a_prev_adjusted = a_max_unchanged ? a_prev_sum : a_adj_scaled;
wire [28:0] a_sum_full      = {1'b0, a_prev_adjusted} + {1'b0, a_current_exp_sum};
wire [27:0] a_sum_value     = a_sum_full[28] ? SUM_SAT : a_sum_full[27:0];

// =====================================================================
// PATH-2 (unchanged)
// =====================================================================
assign path2_low_fire  = valid && path2_mode && !half_select;
assign path2_high_fire = path2_mode && half_select;
assign path2_row_last  = (path2_row_counter == LAST_ROW);
assign path2_tile_last = (path2_tile_counter == LAST_TILE);
assign path2_pass_done = path2_high_fire && path2_row_last && path2_tile_last;

assign path2_max_value = max_buffer[path2_row_counter];
assign path2_sum_value = sum_buffer[path2_row_counter];

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

// =====================================================================
// Sequential
// =====================================================================
integer rst_i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        path2_mode <= 1'b0;
        half_select <= 1'b0;
        row_counter <= 4'd0;
        path2_row_counter <= 4'd0;
        tile_counter <= 6'd0;
        path2_tile_counter <= 6'd0;
        path2_quant_lo <= {8*8{1'b0}};
        softmax_valid <= 1'b0;
        softmax_result_vec <= {16*8{1'b0}};
        softmax_scale <= 24'd0;

        pp_row[0] <= {16*40{1'b0}};
        pp_row[1] <= {16*40{1'b0}};
        pp_wr_sel <= 1'b0;

        e_valid <= 1'b0;   e1_valid <= 1'b0;   a_valid <= 1'b0;
        e_rd_sel <= 1'b0;  e1_rd_sel <= 1'b0;

        for (rst_i = 0; rst_i < 16; rst_i = rst_i + 1) begin
            max_buffer[rst_i] <= MIN_SCORE;
            sum_buffer[rst_i] <= 28'd0;
        end
    end
    else begin
        softmax_valid <= 1'b0;

        // ---------------- PATH-1 pipeline ----------------
        // Stage M -> E0
        if (launch1) begin
            pp_row[pp_wr_sel] <= softmax_input;   // buffer converted Q24.16 row
            pp_wr_sel  <= ~pp_wr_sel;

            e_valid    <= 1'b1;
            e_new_max  <= m_new_max;
            e_prev_max <= m_prev_max;
            e_prev_sum <= m_prev_sum;
            e_max_unchanged <= m_max_unchanged;
            e_row      <= row_counter;
            e_row_last <= m_row_last;
            e_tile_last<= m_tile_last;
            e_rd_sel   <= pp_wr_sel;

            if (m_row_last) begin
                row_counter <= 4'd0;
                tile_counter <= m_tile_last ? 6'd0 : (tile_counter + 6'd1);
            end
            else begin
                row_counter <= row_counter + 4'd1;
            end
        end
        else begin
            e_valid <= 1'b0;
        end

        // Stage E0 -> E1 (shift every cycle; e1_valid gates use)
        e1_valid        <= e_valid;
        e1_new_max      <= e_new_max;
        e1_prev_sum     <= e_prev_sum;
        e1_delta_exp    <= delta_exp_comb;
        e1_max_unchanged<= e_max_unchanged;
        e1_exp_sum_lo   <= folded_exp_sum;   // E0 produced the low-half sum
        e1_row          <= e_row;
        e1_row_last     <= e_row_last;
        e1_tile_last    <= e_tile_last;
        e1_rd_sel       <= e_rd_sel;

        // Stage E1 -> A (shift every cycle; a_valid gates writeback)
        a_valid         <= e1_valid;
        a_new_max       <= e1_new_max;
        a_prev_sum      <= e1_prev_sum;
        a_delta_exp     <= e1_delta_exp;
        a_max_unchanged <= e1_max_unchanged;
        a_current_exp_sum <= e1_cur_sat;     // E1 produced the full current sum
        a_row           <= e1_row;
        a_row_last      <= e1_row_last;
        a_tile_last     <= e1_tile_last;

        // Stage A: write back accumulated max/sum
        if (a_valid) begin
            max_buffer[a_row] <= a_new_max;
            sum_buffer[a_row] <= a_sum_value;
            if (a_row_last && a_tile_last)
                path2_mode <= 1'b1;
        end

        // ---------------- PATH-2 ----------------
        // mac_result_vec is held stable by the feeder across both half-cycles,
        // so the high cycle re-reads it directly (no row_buffer).
        if (path2_low_fire) begin
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
            path2_quant_lo <= {8*8{1'b0}};
            // drain path-1 pipeline so a new row group starts clean
            e_valid <= 1'b0;
            e1_valid <= 1'b0;
            a_valid <= 1'b0;
            for (rst_i = 0; rst_i < 16; rst_i = rst_i + 1) begin
                max_buffer[rst_i] <= MIN_SCORE;
                sum_buffer[rst_i] <= 28'd0;
            end
        end
    end
end
endmodule

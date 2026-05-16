`timescale 1ns/1ps
// Generate testcase first:
// python testbench/generate_ppu_cases.py
//
// Run example:
// iverilog -g2012 -o tb_softmax.vvp PPU_modules.v softmax_modules.v PPU.v testbench/tb_softmax.v
// vvp tb_softmax.vvp

module tb_softmax;

parameter ROWS = 16;
parameter TILES = 64;
parameter LANES = 16;
parameter TOTAL_VALUES = ROWS * TILES * LANES;
parameter WORST_LOSS_CASES_PER_ROW = 5;
parameter CHECK_LOSS_LIMITS = 0;
parameter CHECK_RANK_ORDER = 0;
parameter MAX_ABS_LOSS_LIMIT = 0.001000;
parameter ROW_SUM_LOSS_LIMIT = 0.025000;

reg clk;
reg rst_n;
reg valid;
reg path2_valid;
reg signed [16*24-1:0] mac_result_vec;
reg signed [16*8-1:0] bias;
reg signed [16*40-1:0] score_input_vec;

wire softmax_valid;
wire [16*8-1:0] softmax_result_vec;

real score_real [0:TOTAL_VALUES-1];
real golden_e_softmax [0:TOTAL_VALUES-1];
real golden_2_softmax [0:TOTAL_VALUES-1];
real hw_softmax [0:TOTAL_VALUES-1];
real row_max_real [0:ROWS-1];
real row_output_sum [0:ROWS-1];
real row_abs_loss_e_sum [0:ROWS-1];
real row_sq_loss_e_sum [0:ROWS-1];
real row_max_abs_loss_e [0:ROWS-1];
real row_abs_loss_2_sum [0:ROWS-1];
real row_sq_loss_2_sum [0:ROWS-1];
real row_max_abs_loss_2 [0:ROWS-1];
real row_abs_loss_base_sum [0:ROWS-1];
real row_sq_loss_base_sum [0:ROWS-1];
real row_max_abs_loss_base [0:ROWS-1];

integer error_count;
integer output_count;
integer testcase_count;
integer worst_e_row;
integer worst_e_tile;
integer worst_e_lane;
integer worst_2_row;
integer worst_2_tile;
integer worst_2_lane;
integer worst_base_row;
integer worst_base_tile;
integer worst_base_lane;
real total_abs_loss_e;
real total_sq_loss_e;
real total_rel_loss_pct_e;
real max_abs_loss_e;
real max_rel_loss_pct_e;
real worst_e_golden;
real worst_e_observed;
real total_abs_loss_2;
real total_sq_loss_2;
real total_rel_loss_pct_2;
real max_abs_loss_2;
real max_rel_loss_pct_2;
real worst_2_golden;
real worst_2_observed;
real total_abs_loss_base;
real total_sq_loss_base;
real total_rel_loss_pct_base;
real max_abs_loss_base;
real max_rel_loss_pct_base;
real worst_base_e;
real worst_base_2;

PPU dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .valid             (valid),
    .mac_result_vec    (mac_result_vec),
    .bias              (bias),
    .path2_valid       (path2_valid),
    .softmax_valid     (softmax_valid),
    .softmax_result_vec(softmax_result_vec)
);

initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
end

function integer value_idx;
    input integer row_idx;
    input integer tile_idx;
    input integer lane_idx;
    begin
        value_idx = ((row_idx * TILES) + tile_idx) * LANES + lane_idx;
    end
endfunction

function real abs_real;
    input real value;
    begin
        if (value < 0.0)
            abs_real = -value;
        else
            abs_real = value;
    end
endfunction

function real q16_product_to_real;
    input [16:0] exp_value;
    input [16:0] recip_value;
    begin
        q16_product_to_real = (exp_value / 65536.0) * (recip_value / 65536.0);
    end
endfunction

function real q24_to_real;
    input signed [39:0] value;
    begin
        q24_to_real = $signed(value) / 16777216.0;
    end
endfunction

function signed [39:0] real_to_q24;
    input real value;
    begin
        real_to_q24 = $rtoi(value * 16777216.0);
    end
endfunction

task init_arrays;
    integer row_idx;
    integer idx;
    begin
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            row_max_real[row_idx] = -1.0e30;
            row_output_sum[row_idx] = 0.0;
            row_abs_loss_e_sum[row_idx] = 0.0;
            row_sq_loss_e_sum[row_idx] = 0.0;
            row_max_abs_loss_e[row_idx] = 0.0;
            row_abs_loss_2_sum[row_idx] = 0.0;
            row_sq_loss_2_sum[row_idx] = 0.0;
            row_max_abs_loss_2[row_idx] = 0.0;
            row_abs_loss_base_sum[row_idx] = 0.0;
            row_sq_loss_base_sum[row_idx] = 0.0;
            row_max_abs_loss_base[row_idx] = 0.0;
        end

        for (idx = 0; idx < TOTAL_VALUES; idx = idx + 1) begin
            score_real[idx] = 0.0;
            golden_e_softmax[idx] = 0.0;
            golden_2_softmax[idx] = 0.0;
            hw_softmax[idx] = 0.0;
        end
    end
endtask

task load_testcase;
    integer fd;
    integer scan_count;
    integer row_idx;
    integer tile_idx;
    integer lane_idx;
    integer idx;
    real score_value;
    real golden_e_value;
    real golden_2_value;
    begin
        testcase_count = 0;
        init_arrays;

        fd = $fopen("testbench/testcase/softmax_cases.txt", "r");
        if (fd == 0)
            fd = $fopen("testcase/softmax_cases.txt", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open testbench/testcase/softmax_cases.txt");
            $display("Run: python testbench/generate_ppu_cases.py");
            $finish;
        end

        while (!$feof(fd)) begin
            scan_count = $fscanf(fd, "%d %d %d %f %f %f\n",
                                 row_idx, tile_idx, lane_idx,
                                 score_value, golden_e_value, golden_2_value);
            if (scan_count == 6) begin
                if ((row_idx < 0) || (row_idx >= ROWS) ||
                    (tile_idx < 0) || (tile_idx >= TILES) ||
                    (lane_idx < 0) || (lane_idx >= LANES)) begin
                    $display("ERROR: testcase index out of range row=%0d tile=%0d lane=%0d",
                             row_idx, tile_idx, lane_idx);
                    $finish;
                end

                idx = value_idx(row_idx, tile_idx, lane_idx);
                score_real[idx] = score_value;
                golden_e_softmax[idx] = golden_e_value;
                golden_2_softmax[idx] = golden_2_value;
                testcase_count = testcase_count + 1;

                if (score_value > row_max_real[row_idx])
                    row_max_real[row_idx] = score_value;
            end
            else if (scan_count != -1) begin
                $display("ERROR: testcase format mismatch. Expected columns:");
                $display("row tile lane score_real golden_e_softmax golden_2_softmax");
                $display("Regenerate with: python testbench/generate_ppu_cases.py");
                $finish;
            end
        end

        $fclose(fd);

        if (testcase_count != TOTAL_VALUES) begin
            $display("ERROR: testcase count mismatch, got=%0d expected=%0d", testcase_count, TOTAL_VALUES);
            $finish;
        end
    end
endtask

task drive_softmax_input;
    input integer tile_idx;
    input integer row_idx;
    integer lane_idx;
    integer idx;
    begin
        score_input_vec = {16*40{1'b0}};
        mac_result_vec = {16*24{1'b0}};
        bias = {16*8{1'b0}};

        for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
            idx = value_idx(row_idx, tile_idx, lane_idx);
            score_input_vec[lane_idx*40 +: 40] = real_to_q24(score_real[idx]);
        end

        // Softmax-only comparison: ignore PMS/BA/ReLU and drive the score directly.
        force dut.softmax_input = score_input_vec;
    end
endtask

task run_path1;
    integer row_idx;
    integer tile_idx;
    begin
        $display("=== SOFTMAX PATH1 START: 64 tiles x 16 rows ===");
        for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                @(negedge clk);
                drive_softmax_input(tile_idx, row_idx);
                valid = 1'b1;
                path2_valid = 1'b0;

                @(posedge clk);
                #1;
                if (softmax_valid !== 1'b0) begin
                    error_count = error_count + 1;
                    $display("ERROR: softmax_valid asserted during path1 at tile=%0d row=%0d", tile_idx, row_idx);
                end
            end
        end

        @(negedge clk);
        valid = 1'b0;
        path2_valid = 1'b0;
        $display("=== SOFTMAX PATH1 DONE ===");
    end
endtask

task check_path1_max_buffer;
    integer row_idx;
    real got_max;
    real max_loss;
    begin
        $display("=== PATH1 MAX BUFFER CHECK AGAINST TESTCASE SCORE ===");
        $display("row  max_buf       score_max     max_loss");

        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            got_max = q24_to_real(dut.max_buffer[row_idx]);
            max_loss = got_max - row_max_real[row_idx];
            $display("%2d   %0.8f   %0.8f   %0.8f",
                     row_idx, got_max, row_max_real[row_idx], max_loss);

            if (abs_real(max_loss) > 0.000001) begin
                error_count = error_count + 1;
                $display("ERROR: max_buffer does not match testcase score max at row=%0d", row_idx);
            end
        end
    end
endtask

task check_path2_output;
    input integer tile_idx;
    input integer row_idx;
    integer lane_idx;
    integer idx;
    reg [16:0] got_exp_q16;
    reg [16:0] got_recip_q16;
    real got_real;
    real golden_e_real;
    real golden_2_real;
    real loss_e;
    real abs_loss_e;
    real rel_loss_e_pct;
    real loss_2;
    real abs_loss_2;
    real rel_loss_2_pct;
    real loss_base;
    real abs_loss_base;
    real rel_loss_base_pct;
    begin
        if ((^dut.softmax_exp_debug_vec) === 1'bx) begin
            error_count = error_count + 1;
            $display("ERROR: X detected in softmax_exp_debug_vec at tile=%0d row=%0d", tile_idx, row_idx);
        end
        if ((^dut.softmax_reciprocal_debug) === 1'bx) begin
            error_count = error_count + 1;
            $display("ERROR: X detected in softmax_reciprocal_debug at tile=%0d row=%0d", tile_idx, row_idx);
        end

        for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
            idx = value_idx(row_idx, tile_idx, lane_idx);
            got_exp_q16 = dut.softmax_exp_debug_vec[lane_idx*17 +: 17];
            got_recip_q16 = dut.softmax_reciprocal_debug;
            got_real = q16_product_to_real(got_exp_q16, got_recip_q16);
            golden_e_real = golden_e_softmax[idx];
            golden_2_real = golden_2_softmax[idx];
            hw_softmax[idx] = got_real;

            loss_e = got_real - golden_e_real;
            abs_loss_e = abs_real(loss_e);
            if (golden_e_real > 1.0e-12)
                rel_loss_e_pct = abs_loss_e / golden_e_real * 100.0;
            else
                rel_loss_e_pct = 0.0;

            loss_2 = got_real - golden_2_real;
            abs_loss_2 = abs_real(loss_2);
            if (golden_2_real > 1.0e-12)
                rel_loss_2_pct = abs_loss_2 / golden_2_real * 100.0;
            else
                rel_loss_2_pct = 0.0;

            loss_base = golden_2_real - golden_e_real;
            abs_loss_base = abs_real(loss_base);
            if (golden_e_real > 1.0e-12)
                rel_loss_base_pct = abs_loss_base / golden_e_real * 100.0;
            else
                rel_loss_base_pct = 0.0;

            row_output_sum[row_idx] = row_output_sum[row_idx] + got_real;
            row_abs_loss_e_sum[row_idx] = row_abs_loss_e_sum[row_idx] + abs_loss_e;
            row_sq_loss_e_sum[row_idx] = row_sq_loss_e_sum[row_idx] + loss_e * loss_e;
            row_abs_loss_2_sum[row_idx] = row_abs_loss_2_sum[row_idx] + abs_loss_2;
            row_sq_loss_2_sum[row_idx] = row_sq_loss_2_sum[row_idx] + loss_2 * loss_2;
            row_abs_loss_base_sum[row_idx] = row_abs_loss_base_sum[row_idx] + abs_loss_base;
            row_sq_loss_base_sum[row_idx] = row_sq_loss_base_sum[row_idx] + loss_base * loss_base;
            total_abs_loss_e = total_abs_loss_e + abs_loss_e;
            total_sq_loss_e = total_sq_loss_e + loss_e * loss_e;
            total_rel_loss_pct_e = total_rel_loss_pct_e + rel_loss_e_pct;
            total_abs_loss_2 = total_abs_loss_2 + abs_loss_2;
            total_sq_loss_2 = total_sq_loss_2 + loss_2 * loss_2;
            total_rel_loss_pct_2 = total_rel_loss_pct_2 + rel_loss_2_pct;
            total_abs_loss_base = total_abs_loss_base + abs_loss_base;
            total_sq_loss_base = total_sq_loss_base + loss_base * loss_base;
            total_rel_loss_pct_base = total_rel_loss_pct_base + rel_loss_base_pct;
            output_count = output_count + 1;

            if (abs_loss_e > row_max_abs_loss_e[row_idx])
                row_max_abs_loss_e[row_idx] = abs_loss_e;
            if (abs_loss_2 > row_max_abs_loss_2[row_idx])
                row_max_abs_loss_2[row_idx] = abs_loss_2;
            if (abs_loss_base > row_max_abs_loss_base[row_idx])
                row_max_abs_loss_base[row_idx] = abs_loss_base;

            if (abs_loss_e > max_abs_loss_e) begin
                max_abs_loss_e = abs_loss_e;
                worst_e_row = row_idx;
                worst_e_tile = tile_idx;
                worst_e_lane = lane_idx;
                worst_e_golden = golden_e_real;
                worst_e_observed = got_real;
            end

            if (abs_loss_2 > max_abs_loss_2) begin
                max_abs_loss_2 = abs_loss_2;
                worst_2_row = row_idx;
                worst_2_tile = tile_idx;
                worst_2_lane = lane_idx;
                worst_2_golden = golden_2_real;
                worst_2_observed = got_real;
            end

            if (abs_loss_base > max_abs_loss_base) begin
                max_abs_loss_base = abs_loss_base;
                worst_base_row = row_idx;
                worst_base_tile = tile_idx;
                worst_base_lane = lane_idx;
                worst_base_e = golden_e_real;
                worst_base_2 = golden_2_real;
            end

            if (rel_loss_e_pct > max_rel_loss_pct_e)
                max_rel_loss_pct_e = rel_loss_e_pct;
            if (rel_loss_2_pct > max_rel_loss_pct_2)
                max_rel_loss_pct_2 = rel_loss_2_pct;
            if (rel_loss_base_pct > max_rel_loss_pct_base)
                max_rel_loss_pct_base = rel_loss_base_pct;

        end
    end
endtask

task run_path2;
    integer row_idx;
    integer tile_idx;
    begin
        $display("=== SOFTMAX PATH2 START: replay same 64 tiles x 16 rows ===");
        for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                @(negedge clk);
                drive_softmax_input(tile_idx, row_idx);
                valid = 1'b0;
                path2_valid = 1'b1;

                @(posedge clk);
                #1;
                if (softmax_valid !== 1'b1) begin
                    error_count = error_count + 1;
                    $display("ERROR: softmax_valid missing during path2 at tile=%0d row=%0d", tile_idx, row_idx);
                end
                check_path2_output(tile_idx, row_idx);
            end
        end

        @(negedge clk);
        valid = 1'b0;
        path2_valid = 1'b0;
        release dut.softmax_input;
        $display("=== SOFTMAX PATH2 DONE ===");
    end
endtask

task check_final_reset;
    integer row_idx;
    begin
        @(posedge clk);
        #1;
        $display("=== POST-PATH2 BUFFER RESET CHECK ===");
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            if (dut.max_buffer[row_idx] !== 40'sd0) begin
                error_count = error_count + 1;
                $display("ERROR: max_buffer[%0d] was not reset, value=%h", row_idx, dut.max_buffer[row_idx]);
            end
            if (dut.sum_buffer[row_idx] !== 28'd0) begin
                error_count = error_count + 1;
                $display("ERROR: sum_buffer[%0d] was not reset, value=%h", row_idx, dut.sum_buffer[row_idx]);
            end
        end
        $display("Post-path2 reset check complete");
    end
endtask

function integer is_in_top4;
    input integer value;
    input integer ref0;
    input integer ref1;
    input integer ref2;
    input integer ref3;
    begin
        is_in_top4 = ((value == ref0) || (value == ref1) ||
                      (value == ref2) || (value == ref3)) ? 1 : 0;
    end
endfunction

function integer top4_overlap;
    input integer a0;
    input integer a1;
    input integer a2;
    input integer a3;
    input integer b0;
    input integer b1;
    input integer b2;
    input integer b3;
    begin
        top4_overlap = is_in_top4(a0, b0, b1, b2, b3) +
                       is_in_top4(a1, b0, b1, b2, b3) +
                       is_in_top4(a2, b0, b1, b2, b3) +
                       is_in_top4(a3, b0, b1, b2, b3);
    end
endfunction

function integer top4_ordered_match;
    input integer a0;
    input integer a1;
    input integer a2;
    input integer a3;
    input integer b0;
    input integer b1;
    input integer b2;
    input integer b3;
    begin
        top4_ordered_match = ((a0 == b0) ? 1 : 0) +
                             ((a1 == b1) ? 1 : 0) +
                             ((a2 == b2) ? 1 : 0) +
                             ((a3 == b3) ? 1 : 0);
    end
endfunction

task print_one_worst_loss_case;
    input integer row_idx;
    input integer rank_idx;
    input integer pos;
    integer tile_idx;
    integer lane_idx;
    integer idx;
    real hw_value;
    real golden_e_value;
    real golden_2_value;
    real abs_hw_e;
    real abs_hw_2;
    real abs_base2_e;
    begin
        tile_idx = pos / LANES;
        lane_idx = pos % LANES;
        idx = value_idx(row_idx, tile_idx, lane_idx);
        hw_value = hw_softmax[idx];
        golden_e_value = golden_e_softmax[idx];
        golden_2_value = golden_2_softmax[idx];
        abs_hw_e = abs_real(hw_value - golden_e_value);
        abs_hw_2 = abs_real(hw_value - golden_2_value);
        abs_base2_e = abs_real(golden_2_value - golden_e_value);

        $display("row=%0d rank=%0d tile=%0d lane=%0d score=%0.8f hw=%0.8f golden_2=%0.8f golden_e=%0.8f abs_hw_2=%0.8f abs_hw_e=%0.8f abs_2_e=%0.8f",
                 row_idx, rank_idx, tile_idx, lane_idx, score_real[idx],
                 hw_value, golden_2_value, golden_e_value,
                 abs_hw_2, abs_hw_e, abs_base2_e);
    end
endtask

task print_worst5_loss_cases;
    integer row_idx;
    integer tile_idx;
    integer lane_idx;
    integer idx;
    integer pos;
    integer p0;
    integer p1;
    integer p2;
    integer p3;
    integer p4;
    real v0;
    real v1;
    real v2;
    real v3;
    real v4;
    real candidate;
    begin
        $display("=== WORST 5 HW_VS_BASE2 CASES PER ROW ===");
        $display("Ranked by abs(hw - ideal_base2). golden_e is shown only for reference.");

        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            p0 = -1; p1 = -1; p2 = -1; p3 = -1; p4 = -1;
            v0 = -1.0; v1 = -1.0; v2 = -1.0; v3 = -1.0; v4 = -1.0;

            for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
                for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
                    idx = value_idx(row_idx, tile_idx, lane_idx);
                    pos = tile_idx * LANES + lane_idx;
                    candidate = abs_real(hw_softmax[idx] - golden_2_softmax[idx]);

                    if (candidate > v0) begin
                        v4 = v3; p4 = p3;
                        v3 = v2; p3 = p2;
                        v2 = v1; p2 = p1;
                        v1 = v0; p1 = p0;
                        v0 = candidate; p0 = pos;
                    end
                    else if (candidate > v1) begin
                        v4 = v3; p4 = p3;
                        v3 = v2; p3 = p2;
                        v2 = v1; p2 = p1;
                        v1 = candidate; p1 = pos;
                    end
                    else if (candidate > v2) begin
                        v4 = v3; p4 = p3;
                        v3 = v2; p3 = p2;
                        v2 = candidate; p2 = pos;
                    end
                    else if (candidate > v3) begin
                        v4 = v3; p4 = p3;
                        v3 = candidate; p3 = pos;
                    end
                    else if (candidate > v4) begin
                        v4 = candidate; p4 = pos;
                    end
                end
            end

            if (WORST_LOSS_CASES_PER_ROW >= 1) print_one_worst_loss_case(row_idx, 1, p0);
            if (WORST_LOSS_CASES_PER_ROW >= 2) print_one_worst_loss_case(row_idx, 2, p1);
            if (WORST_LOSS_CASES_PER_ROW >= 3) print_one_worst_loss_case(row_idx, 3, p2);
            if (WORST_LOSS_CASES_PER_ROW >= 4) print_one_worst_loss_case(row_idx, 4, p3);
            if (WORST_LOSS_CASES_PER_ROW >= 5) print_one_worst_loss_case(row_idx, 5, p4);
        end
    end
endtask

task find_top4_for_row;
    input integer row_idx;
    input integer mode; // 0: hardware, 1: e golden, 2: ideal base-2 golden
    output integer pos0;
    output integer pos1;
    output integer pos2;
    output integer pos3;
    output real val0;
    output real val1;
    output real val2;
    output real val3;
    integer tile_idx;
    integer lane_idx;
    integer idx;
    integer pos;
    real candidate;
    begin
        pos0 = -1;
        pos1 = -1;
        pos2 = -1;
        pos3 = -1;
        val0 = -1.0;
        val1 = -1.0;
        val2 = -1.0;
        val3 = -1.0;

        for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
            for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
                idx = value_idx(row_idx, tile_idx, lane_idx);
                pos = tile_idx * LANES + lane_idx;

                if (mode == 0)
                    candidate = hw_softmax[idx];
                else if (mode == 1)
                    candidate = golden_e_softmax[idx];
                else
                    candidate = golden_2_softmax[idx];

                if (candidate > val0) begin
                    val3 = val2; pos3 = pos2;
                    val2 = val1; pos2 = pos1;
                    val1 = val0; pos1 = pos0;
                    val0 = candidate; pos0 = pos;
                end
                else if (candidate > val1) begin
                    val3 = val2; pos3 = pos2;
                    val2 = val1; pos2 = pos1;
                    val1 = candidate; pos1 = pos;
                end
                else if (candidate > val2) begin
                    val3 = val2; pos3 = pos2;
                    val2 = candidate; pos2 = pos;
                end
                else if (candidate > val3) begin
                    val3 = candidate; pos3 = pos;
                end
            end
        end
    end
endtask

task print_top4_summary;
    integer row_idx;
    integer e0;
    integer e1;
    integer e2;
    integer e3;
    integer b0;
    integer b1;
    integer b2;
    integer b3;
    integer h0;
    integer h1;
    integer h2;
    integer h3;
    integer overlap_e;
    integer overlap_2;
    integer ordered_e;
    integer ordered_2;
    integer total_overlap_e;
    integer total_overlap_2;
    integer total_ordered_e;
    integer total_ordered_2;
    real ev0;
    real ev1;
    real ev2;
    real ev3;
    real bv0;
    real bv1;
    real bv2;
    real bv3;
    real hv0;
    real hv1;
    real hv2;
    real hv3;
    begin
        total_overlap_e = 0;
        total_overlap_2 = 0;
        total_ordered_e = 0;
        total_ordered_2 = 0;

        $display("=== TOP4 RANK SUMMARY ===");
        $display("Format: position is tile:lane inside each 1024-value row");
        $display("overlap means same top4 set; ordered means same rank slot");
        $display("row  e_top4                            base2_top4                        hw_top4                           set_e set_2 ord_e ord_2");

        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            find_top4_for_row(row_idx, 1, e0, e1, e2, e3, ev0, ev1, ev2, ev3);
            find_top4_for_row(row_idx, 2, b0, b1, b2, b3, bv0, bv1, bv2, bv3);
            find_top4_for_row(row_idx, 0, h0, h1, h2, h3, hv0, hv1, hv2, hv3);

            overlap_e = top4_overlap(h0, h1, h2, h3, e0, e1, e2, e3);
            overlap_2 = top4_overlap(h0, h1, h2, h3, b0, b1, b2, b3);
            ordered_e = top4_ordered_match(h0, h1, h2, h3, e0, e1, e2, e3);
            ordered_2 = top4_ordered_match(h0, h1, h2, h3, b0, b1, b2, b3);
            total_overlap_e = total_overlap_e + overlap_e;
            total_overlap_2 = total_overlap_2 + overlap_2;
            total_ordered_e = total_ordered_e + ordered_e;
            total_ordered_2 = total_ordered_2 + ordered_2;

            $display("%2d   [%0d:%0d %0d:%0d %0d:%0d %0d:%0d]   [%0d:%0d %0d:%0d %0d:%0d %0d:%0d]   [%0d:%0d %0d:%0d %0d:%0d %0d:%0d]   %0d/4  %0d/4  %0d/4  %0d/4",
                     row_idx,
                     e0 / LANES, e0 % LANES, e1 / LANES, e1 % LANES,
                     e2 / LANES, e2 % LANES, e3 / LANES, e3 % LANES,
                     b0 / LANES, b0 % LANES, b1 / LANES, b1 % LANES,
                     b2 / LANES, b2 % LANES, b3 / LANES, b3 % LANES,
                     h0 / LANES, h0 % LANES, h1 / LANES, h1 % LANES,
                     h2 / LANES, h2 % LANES, h3 / LANES, h3 % LANES,
                     overlap_e, overlap_2, ordered_e, ordered_2);
        end

        $display("Top4 overlap total hw/e=%0d/%0d hw/base2=%0d/%0d",
                 total_overlap_e, ROWS * 4, total_overlap_2, ROWS * 4);
        $display("Top4 ordered total hw/e=%0d/%0d hw/base2=%0d/%0d",
                 total_ordered_e, ROWS * 4, total_ordered_2, ROWS * 4);
    end
endtask

function integer is_in_top8;
    input integer value;
    input integer ref0;
    input integer ref1;
    input integer ref2;
    input integer ref3;
    input integer ref4;
    input integer ref5;
    input integer ref6;
    input integer ref7;
    begin
        is_in_top8 = ((value == ref0) || (value == ref1) ||
                      (value == ref2) || (value == ref3) ||
                      (value == ref4) || (value == ref5) ||
                      (value == ref6) || (value == ref7)) ? 1 : 0;
    end
endfunction

function integer top8_overlap;
    input integer a0;
    input integer a1;
    input integer a2;
    input integer a3;
    input integer a4;
    input integer a5;
    input integer a6;
    input integer a7;
    input integer b0;
    input integer b1;
    input integer b2;
    input integer b3;
    input integer b4;
    input integer b5;
    input integer b6;
    input integer b7;
    begin
        top8_overlap = is_in_top8(a0, b0, b1, b2, b3, b4, b5, b6, b7) +
                       is_in_top8(a1, b0, b1, b2, b3, b4, b5, b6, b7) +
                       is_in_top8(a2, b0, b1, b2, b3, b4, b5, b6, b7) +
                       is_in_top8(a3, b0, b1, b2, b3, b4, b5, b6, b7) +
                       is_in_top8(a4, b0, b1, b2, b3, b4, b5, b6, b7) +
                       is_in_top8(a5, b0, b1, b2, b3, b4, b5, b6, b7) +
                       is_in_top8(a6, b0, b1, b2, b3, b4, b5, b6, b7) +
                       is_in_top8(a7, b0, b1, b2, b3, b4, b5, b6, b7);
    end
endfunction

function integer top8_ordered_match;
    input integer a0;
    input integer a1;
    input integer a2;
    input integer a3;
    input integer a4;
    input integer a5;
    input integer a6;
    input integer a7;
    input integer b0;
    input integer b1;
    input integer b2;
    input integer b3;
    input integer b4;
    input integer b5;
    input integer b6;
    input integer b7;
    begin
        top8_ordered_match = ((a0 == b0) ? 1 : 0) +
                             ((a1 == b1) ? 1 : 0) +
                             ((a2 == b2) ? 1 : 0) +
                             ((a3 == b3) ? 1 : 0) +
                             ((a4 == b4) ? 1 : 0) +
                             ((a5 == b5) ? 1 : 0) +
                             ((a6 == b6) ? 1 : 0) +
                             ((a7 == b7) ? 1 : 0);
    end
endfunction

task find_top8_for_row;
    input integer row_idx;
    input integer mode; // 0: hardware, 1: e golden, 2: ideal base-2 golden
    output integer pos0;
    output integer pos1;
    output integer pos2;
    output integer pos3;
    output integer pos4;
    output integer pos5;
    output integer pos6;
    output integer pos7;
    output real val0;
    output real val1;
    output real val2;
    output real val3;
    output real val4;
    output real val5;
    output real val6;
    output real val7;
    integer tile_idx;
    integer lane_idx;
    integer idx;
    integer pos;
    real candidate;
    begin
        pos0 = -1; pos1 = -1; pos2 = -1; pos3 = -1;
        pos4 = -1; pos5 = -1; pos6 = -1; pos7 = -1;
        val0 = -1.0; val1 = -1.0; val2 = -1.0; val3 = -1.0;
        val4 = -1.0; val5 = -1.0; val6 = -1.0; val7 = -1.0;

        for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
            for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
                idx = value_idx(row_idx, tile_idx, lane_idx);
                pos = tile_idx * LANES + lane_idx;

                if (mode == 0)
                    candidate = hw_softmax[idx];
                else if (mode == 1)
                    candidate = golden_e_softmax[idx];
                else
                    candidate = golden_2_softmax[idx];

                if (candidate > val0) begin
                    val7 = val6; pos7 = pos6;
                    val6 = val5; pos6 = pos5;
                    val5 = val4; pos5 = pos4;
                    val4 = val3; pos4 = pos3;
                    val3 = val2; pos3 = pos2;
                    val2 = val1; pos2 = pos1;
                    val1 = val0; pos1 = pos0;
                    val0 = candidate; pos0 = pos;
                end
                else if (candidate > val1) begin
                    val7 = val6; pos7 = pos6;
                    val6 = val5; pos6 = pos5;
                    val5 = val4; pos5 = pos4;
                    val4 = val3; pos4 = pos3;
                    val3 = val2; pos3 = pos2;
                    val2 = val1; pos2 = pos1;
                    val1 = candidate; pos1 = pos;
                end
                else if (candidate > val2) begin
                    val7 = val6; pos7 = pos6;
                    val6 = val5; pos6 = pos5;
                    val5 = val4; pos5 = pos4;
                    val4 = val3; pos4 = pos3;
                    val3 = val2; pos3 = pos2;
                    val2 = candidate; pos2 = pos;
                end
                else if (candidate > val3) begin
                    val7 = val6; pos7 = pos6;
                    val6 = val5; pos6 = pos5;
                    val5 = val4; pos5 = pos4;
                    val4 = val3; pos4 = pos3;
                    val3 = candidate; pos3 = pos;
                end
                else if (candidate > val4) begin
                    val7 = val6; pos7 = pos6;
                    val6 = val5; pos6 = pos5;
                    val5 = val4; pos5 = pos4;
                    val4 = candidate; pos4 = pos;
                end
                else if (candidate > val5) begin
                    val7 = val6; pos7 = pos6;
                    val6 = val5; pos6 = pos5;
                    val5 = candidate; pos5 = pos;
                end
                else if (candidate > val6) begin
                    val7 = val6; pos7 = pos6;
                    val6 = candidate; pos6 = pos;
                end
                else if (candidate > val7) begin
                    val7 = candidate; pos7 = pos;
                end
            end
        end
    end
endtask

task print_top8_summary;
    integer row_idx;
    integer e0; integer e1; integer e2; integer e3;
    integer e4; integer e5; integer e6; integer e7;
    integer b0; integer b1; integer b2; integer b3;
    integer b4; integer b5; integer b6; integer b7;
    integer h0; integer h1; integer h2; integer h3;
    integer h4; integer h5; integer h6; integer h7;
    integer overlap_e;
    integer overlap_2;
    integer ordered_e;
    integer ordered_2;
    integer total_overlap_e;
    integer total_overlap_2;
    integer total_ordered_e;
    integer total_ordered_2;
    real ev0; real ev1; real ev2; real ev3;
    real ev4; real ev5; real ev6; real ev7;
    real bv0; real bv1; real bv2; real bv3;
    real bv4; real bv5; real bv6; real bv7;
    real hv0; real hv1; real hv2; real hv3;
    real hv4; real hv5; real hv6; real hv7;
    begin
        total_overlap_e = 0;
        total_overlap_2 = 0;
        total_ordered_e = 0;
        total_ordered_2 = 0;

        $display("=== TOP8 RANK SUMMARY ===");
        $display("Format: position is tile:lane inside each 1024-value row");
        $display("overlap means same top8 set; ordered means same rank slot");
        $display("row  set_e set_2 ord_e ord_2  e_top8 positions                         base2_top8 positions                     hw_top8 positions");

        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            find_top8_for_row(row_idx, 1, e0, e1, e2, e3, e4, e5, e6, e7,
                              ev0, ev1, ev2, ev3, ev4, ev5, ev6, ev7);
            find_top8_for_row(row_idx, 2, b0, b1, b2, b3, b4, b5, b6, b7,
                              bv0, bv1, bv2, bv3, bv4, bv5, bv6, bv7);
            find_top8_for_row(row_idx, 0, h0, h1, h2, h3, h4, h5, h6, h7,
                              hv0, hv1, hv2, hv3, hv4, hv5, hv6, hv7);

            overlap_e = top8_overlap(h0, h1, h2, h3, h4, h5, h6, h7,
                                     e0, e1, e2, e3, e4, e5, e6, e7);
            overlap_2 = top8_overlap(h0, h1, h2, h3, h4, h5, h6, h7,
                                     b0, b1, b2, b3, b4, b5, b6, b7);
            ordered_e = top8_ordered_match(h0, h1, h2, h3, h4, h5, h6, h7,
                                           e0, e1, e2, e3, e4, e5, e6, e7);
            ordered_2 = top8_ordered_match(h0, h1, h2, h3, h4, h5, h6, h7,
                                           b0, b1, b2, b3, b4, b5, b6, b7);
            total_overlap_e = total_overlap_e + overlap_e;
            total_overlap_2 = total_overlap_2 + overlap_2;
            total_ordered_e = total_ordered_e + ordered_e;
            total_ordered_2 = total_ordered_2 + ordered_2;

            $display("%2d   %0d/8  %0d/8  %0d/8  %0d/8   [%0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d]   [%0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d]   [%0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d %0d:%0d]",
                     row_idx, overlap_e, overlap_2, ordered_e, ordered_2,
                     e0 / LANES, e0 % LANES, e1 / LANES, e1 % LANES,
                     e2 / LANES, e2 % LANES, e3 / LANES, e3 % LANES,
                     e4 / LANES, e4 % LANES, e5 / LANES, e5 % LANES,
                     e6 / LANES, e6 % LANES, e7 / LANES, e7 % LANES,
                     b0 / LANES, b0 % LANES, b1 / LANES, b1 % LANES,
                     b2 / LANES, b2 % LANES, b3 / LANES, b3 % LANES,
                     b4 / LANES, b4 % LANES, b5 / LANES, b5 % LANES,
                     b6 / LANES, b6 % LANES, b7 / LANES, b7 % LANES,
                     h0 / LANES, h0 % LANES, h1 / LANES, h1 % LANES,
                     h2 / LANES, h2 % LANES, h3 / LANES, h3 % LANES,
                     h4 / LANES, h4 % LANES, h5 / LANES, h5 % LANES,
                     h6 / LANES, h6 % LANES, h7 / LANES, h7 % LANES);
        end

        $display("Top8 overlap total hw/e=%0d/%0d hw/base2=%0d/%0d",
                 total_overlap_e, ROWS * 8, total_overlap_2, ROWS * 8);
        $display("Top8 ordered total hw/e=%0d/%0d hw/base2=%0d/%0d",
                 total_ordered_e, ROWS * 8, total_ordered_2, ROWS * 8);
    end
endtask

task print_one_base2_rank_mismatch;
    input integer row_idx;
    input integer rank_idx;
    input integer base2_pos;
    input integer hw_pos;
    integer base2_tile;
    integer base2_lane;
    integer hw_tile;
    integer hw_lane;
    integer base2_idx;
    integer hw_idx;
    real base2_at_base2_pos;
    real hw_at_base2_pos;
    real base2_at_hw_pos;
    real hw_at_hw_pos;
    begin
        base2_tile = base2_pos / LANES;
        base2_lane = base2_pos % LANES;
        hw_tile = hw_pos / LANES;
        hw_lane = hw_pos % LANES;
        base2_idx = value_idx(row_idx, base2_tile, base2_lane);
        hw_idx = value_idx(row_idx, hw_tile, hw_lane);

        base2_at_base2_pos = golden_2_softmax[base2_idx];
        hw_at_base2_pos = hw_softmax[base2_idx];
        base2_at_hw_pos = golden_2_softmax[hw_idx];
        hw_at_hw_pos = hw_softmax[hw_idx];

        $display("RANK_ORDER_MISMATCH row=%0d rank=%0d base2_pos=%0d:%0d hw_pos=%0d:%0d base2_at_base2=%0.8f hw_at_base2=%0.8f base2_at_hw=%0.8f hw_at_hw=%0.8f base2_margin=%0.8f hw_margin=%0.8f",
                 row_idx, rank_idx,
                 base2_tile, base2_lane, hw_tile, hw_lane,
                 base2_at_base2_pos, hw_at_base2_pos,
                 base2_at_hw_pos, hw_at_hw_pos,
                 base2_at_base2_pos - base2_at_hw_pos,
                 hw_at_base2_pos - hw_at_hw_pos);
    end
endtask

task print_top8_base2_order_mismatches;
    integer row_idx;
    integer b0; integer b1; integer b2; integer b3;
    integer b4; integer b5; integer b6; integer b7;
    integer h0; integer h1; integer h2; integer h3;
    integer h4; integer h5; integer h6; integer h7;
    integer mismatch_count;
    real bv0; real bv1; real bv2; real bv3;
    real bv4; real bv5; real bv6; real bv7;
    real hv0; real hv1; real hv2; real hv3;
    real hv4; real hv5; real hv6; real hv7;
    begin
        mismatch_count = 0;

        $display("=== TOP8 BASE2 ORDER MISMATCH DETAIL ===");
        $display("Each line compares the ideal base2 rank slot against the hardware rank slot.");

        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            find_top8_for_row(row_idx, 2, b0, b1, b2, b3, b4, b5, b6, b7,
                              bv0, bv1, bv2, bv3, bv4, bv5, bv6, bv7);
            find_top8_for_row(row_idx, 0, h0, h1, h2, h3, h4, h5, h6, h7,
                              hv0, hv1, hv2, hv3, hv4, hv5, hv6, hv7);

            if (b0 != h0) begin mismatch_count = mismatch_count + 1; print_one_base2_rank_mismatch(row_idx, 1, b0, h0); end
            if (b1 != h1) begin mismatch_count = mismatch_count + 1; print_one_base2_rank_mismatch(row_idx, 2, b1, h1); end
            if (b2 != h2) begin mismatch_count = mismatch_count + 1; print_one_base2_rank_mismatch(row_idx, 3, b2, h2); end
            if (b3 != h3) begin mismatch_count = mismatch_count + 1; print_one_base2_rank_mismatch(row_idx, 4, b3, h3); end
            if (b4 != h4) begin mismatch_count = mismatch_count + 1; print_one_base2_rank_mismatch(row_idx, 5, b4, h4); end
            if (b5 != h5) begin mismatch_count = mismatch_count + 1; print_one_base2_rank_mismatch(row_idx, 6, b5, h5); end
            if (b6 != h6) begin mismatch_count = mismatch_count + 1; print_one_base2_rank_mismatch(row_idx, 7, b6, h6); end
            if (b7 != h7) begin mismatch_count = mismatch_count + 1; print_one_base2_rank_mismatch(row_idx, 8, b7, h7); end
        end

        $display("Top8 base2 ordered rank-slot mismatches: %0d", mismatch_count);
        if (CHECK_RANK_ORDER && (mismatch_count != 0)) begin
            error_count = error_count + mismatch_count;
            $display("ERROR: top8 base2 ordered rank-slot mismatches detected: %0d",
                     mismatch_count);
        end
    end
endtask

task print_loss_summary;
    integer row_idx;
    real row_mean_abs_e;
    real row_rmse_e;
    real row_mean_abs_2;
    real row_rmse_2;
    real row_mean_abs_base;
    real row_rmse_base;
    real row_sum_loss;
    real mean_abs_e;
    real rmse_e;
    real mean_rel_pct_e;
    real mean_abs_2;
    real rmse_2;
    real mean_rel_pct_2;
    real mean_abs_base;
    real rmse_base;
    real mean_rel_pct_base;
    begin
        $display("=== SOFTMAX ROW LOSS SUMMARY ===");
        $display("hw_vs_e   : total observed loss against real e-softmax golden");
        $display("hw_vs_2   : hardware approximation/quantization loss against ideal base-2 softmax");
        $display("base2_vs_e: loss from choosing base-2 softmax instead of e-softmax");
        $display("row  out_sum      sum_loss     mean_abs(hw_e) mean_abs(hw_2) mean_abs(2_e) max_abs(hw_2)");
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            row_mean_abs_e = row_abs_loss_e_sum[row_idx] / (TILES * LANES);
            row_rmse_e = (row_sq_loss_e_sum[row_idx] / (TILES * LANES)) ** 0.5;
            row_mean_abs_2 = row_abs_loss_2_sum[row_idx] / (TILES * LANES);
            row_rmse_2 = (row_sq_loss_2_sum[row_idx] / (TILES * LANES)) ** 0.5;
            row_mean_abs_base = row_abs_loss_base_sum[row_idx] / (TILES * LANES);
            row_rmse_base = (row_sq_loss_base_sum[row_idx] / (TILES * LANES)) ** 0.5;
            row_sum_loss = row_output_sum[row_idx] - 1.0;

            $display("%2d   %0.8f   %0.8f   %0.8f     %0.8f     %0.8f     %0.8f",
                     row_idx, row_output_sum[row_idx], row_sum_loss,
                     row_mean_abs_e, row_mean_abs_2, row_mean_abs_base,
                     row_max_abs_loss_2[row_idx]);

            if (CHECK_LOSS_LIMITS && abs_real(row_sum_loss) > ROW_SUM_LOSS_LIMIT) begin
                error_count = error_count + 1;
                $display("ERROR: row %0d output sum loss %0.8f exceeds limit %0.8f",
                         row_idx, abs_real(row_sum_loss), ROW_SUM_LOSS_LIMIT);
            end
        end

        mean_abs_e = total_abs_loss_e / output_count;
        rmse_e = (total_sq_loss_e / output_count) ** 0.5;
        mean_rel_pct_e = total_rel_loss_pct_e / output_count;
        mean_abs_2 = total_abs_loss_2 / output_count;
        rmse_2 = (total_sq_loss_2 / output_count) ** 0.5;
        mean_rel_pct_2 = total_rel_loss_pct_2 / output_count;
        mean_abs_base = total_abs_loss_base / output_count;
        rmse_base = (total_sq_loss_base / output_count) ** 0.5;
        mean_rel_pct_base = total_rel_loss_pct_base / output_count;

        $display("=== SOFTMAX GLOBAL LOSS LAYERS ===");
        $display("outputs              : %0d", output_count);
        $display("layer       mean_abs_loss  max_abs_loss   rmse          mean_rel_pct  max_rel_pct");
        $display("hw_vs_e     %0.8f     %0.8f     %0.8f    %0.4f       %0.4f",
                 mean_abs_e, max_abs_loss_e, rmse_e, mean_rel_pct_e, max_rel_loss_pct_e);
        $display("hw_vs_2     %0.8f     %0.8f     %0.8f    %0.4f       %0.4f",
                 mean_abs_2, max_abs_loss_2, rmse_2, mean_rel_pct_2, max_rel_loss_pct_2);
        $display("base2_vs_e  %0.8f     %0.8f     %0.8f    %0.4f       %0.4f",
                 mean_abs_base, max_abs_loss_base, rmse_base, mean_rel_pct_base, max_rel_loss_pct_base);

        $display("Worst hw_vs_e    : row=%0d tile=%0d lane=%0d hw/e=%0.8f/%0.8f",
                 worst_e_row, worst_e_tile, worst_e_lane, worst_e_observed, worst_e_golden);
        $display("Worst hw_vs_2    : row=%0d tile=%0d lane=%0d hw/base2=%0.8f/%0.8f",
                 worst_2_row, worst_2_tile, worst_2_lane, worst_2_observed, worst_2_golden);
        $display("Worst base2_vs_e : row=%0d tile=%0d lane=%0d base2/e=%0.8f/%0.8f",
                 worst_base_row, worst_base_tile, worst_base_lane, worst_base_2, worst_base_e);

        if (CHECK_LOSS_LIMITS && max_abs_loss_2 > MAX_ABS_LOSS_LIMIT) begin
            error_count = error_count + 1;
            $display("ERROR: hw_vs_2 max_abs_loss %0.8f exceeds limit %0.8f",
                     max_abs_loss_2, MAX_ABS_LOSS_LIMIT);
        end
    end
endtask

initial begin
    error_count = 0;
    output_count = 0;
    total_abs_loss_e = 0.0;
    total_sq_loss_e = 0.0;
    total_rel_loss_pct_e = 0.0;
    max_abs_loss_e = 0.0;
    max_rel_loss_pct_e = 0.0;
    worst_e_row = 0;
    worst_e_tile = 0;
    worst_e_lane = 0;
    worst_e_golden = 0.0;
    worst_e_observed = 0.0;
    total_abs_loss_2 = 0.0;
    total_sq_loss_2 = 0.0;
    total_rel_loss_pct_2 = 0.0;
    max_abs_loss_2 = 0.0;
    max_rel_loss_pct_2 = 0.0;
    worst_2_row = 0;
    worst_2_tile = 0;
    worst_2_lane = 0;
    worst_2_golden = 0.0;
    worst_2_observed = 0.0;
    total_abs_loss_base = 0.0;
    total_sq_loss_base = 0.0;
    total_rel_loss_pct_base = 0.0;
    max_abs_loss_base = 0.0;
    max_rel_loss_pct_base = 0.0;
    worst_base_row = 0;
    worst_base_tile = 0;
    worst_base_lane = 0;
    worst_base_e = 0.0;
    worst_base_2 = 0.0;

    rst_n = 1'b0;
    valid = 1'b0;
    path2_valid = 1'b0;
    mac_result_vec = {16*24{1'b0}};
    bias = {16*8{1'b0}};
    score_input_vec = {16*40{1'b0}};

    load_testcase;

    $display("=== SOFTMAX-ONLY PPU TEST START ===");
    $display("Testcase file : testbench/testcase/softmax_cases.txt");
    $display("Columns       : row tile lane score_real golden_e_softmax golden_2_softmax");
    $display("Golden output : precomputed outside this testbench");
    $display("PMS/BA/ReLU   : ignored by forcing softmax_input directly");
    $display("Worst cases   : %0d max abs(hw-base2) entries per row",
             WORST_LOSS_CASES_PER_ROW);
    $display("Loaded deterministic vectors: rows=%0d tiles=%0d lanes=%0d outputs=%0d",
             ROWS, TILES, LANES, testcase_count);
    $display("CHECK_LOSS_LIMITS=%0d CHECK_RANK_ORDER=%0d",
             CHECK_LOSS_LIMITS, CHECK_RANK_ORDER);

    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    run_path1;
    check_path1_max_buffer;
    run_path2;
    check_final_reset;
    print_loss_summary;
    print_worst5_loss_cases;
    print_top4_summary;
    print_top8_summary;
    print_top8_base2_order_mismatches;

    if (error_count == 0)
        $display("RESULT: PASS");
    else
        $display("RESULT: FAIL errors=%0d", error_count);

    $finish;
end

endmodule

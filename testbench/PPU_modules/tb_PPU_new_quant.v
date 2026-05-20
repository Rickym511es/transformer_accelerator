`timescale 1ns/1ps
// Generate testcase first if needed:
// python testbench/case_generator/generate_ppu_cases.py
//
// Run example:
// iverilog -g2012 -o tb_PPU_new_quant.vvp PPU/PPU_modules.v PPU/softmax_modules.v PPU/PPU.v testbench/PPU_modules/tb_PPU_new_quant.v
// vvp tb_PPU_new_quant.vvp

module tb_PPU_new_quant;

parameter ROWS = 16;
parameter TILES = 64;
parameter LANES = 16;
parameter TOTAL_VALUES = ROWS * TILES * LANES;
parameter ROUND_Q16 = 32768;

reg clk;
reg rst_n;
reg valid;
reg signed [16*24-1:0] mac_result_vec;
reg signed [16*8-1:0] bias;
reg signed [16*40-1:0] score_input_vec;

wire softmax_valid;
wire [16*8-1:0] softmax_result_vec;
wire [23:0] softmax_scale;

real score_real [0:TOTAL_VALUES-1];
integer golden_quant [0:TOTAL_VALUES-1];

integer error_count;
integer testcase_count;
integer output_count;
integer quant_mismatch_count;
integer formula_mismatch_count;
integer scale_mismatch_count;
integer max_abs_diff;
integer formula_max_abs_diff;
integer worst_row;
integer worst_tile;
integer worst_lane;
integer worst_golden;
integer worst_got;
integer worst_formula;
real worst_score;

integer row_quant_mismatch [0:ROWS-1];
integer row_formula_mismatch [0:ROWS-1];
integer row_max_abs_diff [0:ROWS-1];

PPU dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .valid             (valid),
    .mac_result_vec    (mac_result_vec),
    .bias              (bias),
    .softmax_valid     (softmax_valid),
    .softmax_result_vec(softmax_result_vec),
    .softmax_scale     (softmax_scale)
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

function signed [39:0] real_to_q24;
    input real value;
    begin
        real_to_q24 = $rtoi(value * 65536.0);
    end
endfunction

function integer abs_int;
    input integer value;
    begin
        if (value < 0)
            abs_int = -value;
        else
            abs_int = value;
    end
endfunction

function integer quant_shift_minus_one;
    input [16:0] exp_q16;
    integer full_value;
    begin
        full_value = (({7'd0, exp_q16} << 7) - {7'd0, exp_q16}) + ROUND_Q16;
        quant_shift_minus_one = (full_value >> 16) & 8'hff;
    end
endfunction

task init_arrays;
    integer row_idx;
    integer idx;
    begin
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            row_quant_mismatch[row_idx] = 0;
            row_formula_mismatch[row_idx] = 0;
            row_max_abs_diff[row_idx] = 0;
        end

        for (idx = 0; idx < TOTAL_VALUES; idx = idx + 1) begin
            score_real[idx] = 0.0;
            golden_quant[idx] = 0;
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
    integer golden_quant_value;
    begin
        testcase_count = 0;
        init_arrays;

        fd = $fopen("testbench/testcase/ppu_quant_cases.txt", "r");
        if (fd == 0)
            fd = $fopen("testcase/ppu_quant_cases.txt", "r");
        if (fd == 0)
            fd = $fopen("testbench/case_generator/testcase/ppu_quant_cases.txt", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open ppu_quant_cases.txt");
            $display("Tried testbench/testcase and testbench/case_generator/testcase.");
            $finish;
        end

        while (!$feof(fd)) begin
            scan_count = $fscanf(fd, "%d %d %d %f %d\n",
                                 row_idx, tile_idx, lane_idx,
                                 score_value, golden_quant_value);
            if (scan_count == 5) begin
                if ((row_idx < 0) || (row_idx >= ROWS) ||
                    (tile_idx < 0) || (tile_idx >= TILES) ||
                    (lane_idx < 0) || (lane_idx >= LANES)) begin
                    $display("ERROR: testcase index out of range row=%0d tile=%0d lane=%0d",
                             row_idx, tile_idx, lane_idx);
                    $finish;
                end

                idx = value_idx(row_idx, tile_idx, lane_idx);
                score_real[idx] = score_value;
                golden_quant[idx] = golden_quant_value;
                testcase_count = testcase_count + 1;
            end
            else if (scan_count != -1) begin
                $display("ERROR: testcase format mismatch. Expected columns:");
                $display("row tile lane score_real golden_quant_int8");
                $finish;
            end
        end

        $fclose(fd);

        if (testcase_count != TOTAL_VALUES) begin
            $display("ERROR: testcase count mismatch, got=%0d expected=%0d",
                     testcase_count, TOTAL_VALUES);
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

        // Same softmax-only style as tb_PPUquant: bypass PMS/BA/ReLU.
        force dut.softmax_input = score_input_vec;
    end
endtask

task run_path1;
    integer row_idx;
    integer tile_idx;
    begin
        $display("=== NEW PPU QUANT PATH1 START: collect max/sum buffers ===");
        for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                @(negedge clk);
                drive_softmax_input(tile_idx, row_idx);
                valid = 1'b1;

                @(posedge clk);
                #1;
                if (softmax_valid !== 1'b0) begin
                    error_count = error_count + 1;
                    $display("ERROR: softmax_valid asserted during path1 tile=%0d row=%0d",
                             tile_idx, row_idx);
                end
            end
        end

        @(negedge clk);
        valid = 1'b0;
        $display("=== NEW PPU QUANT PATH1 INPUT DONE ===");
    end
endtask

task wait_for_path2_ready;
    integer wait_count;
    begin
        wait_count = 0;
        while (dut.path1_buffers_done !== 1'b1) begin
            @(posedge clk);
            #1;
            wait_count = wait_count + 1;
            if (wait_count > 16) begin
                error_count = error_count + 1;
                $display("ERROR: timeout waiting for path1_buffers_done");
                $finish;
            end
        end
        $display("=== NEW PPU QUANT PATH2 READY after %0d cycle(s) ===", wait_count);
    end
endtask

task check_quant_output;
    input integer tile_idx;
    input integer row_idx;
    input [16*17-1:0] expected_exp_vec;
    input [23:0] expected_scale;
    integer lane_idx;
    integer idx;
    integer got_quant;
    integer got_formula;
    integer golden;
    integer quant_abs_diff;
    integer formula_abs_diff;
    reg [16:0] exp_q16;
    begin
        if (softmax_valid !== 1'b1) begin
            error_count = error_count + 1;
            $display("ERROR: softmax_valid missing for path2 output tile=%0d row=%0d",
                     tile_idx, row_idx);
        end

        if ((^softmax_result_vec) === 1'bx) begin
            error_count = error_count + 1;
            $display("ERROR: X detected in softmax_result_vec tile=%0d row=%0d",
                     tile_idx, row_idx);
        end

        if ((^softmax_scale) === 1'bx) begin
            error_count = error_count + 1;
            $display("ERROR: X detected in softmax_scale tile=%0d row=%0d",
                     tile_idx, row_idx);
        end
        else if (softmax_scale !== expected_scale) begin
            scale_mismatch_count = scale_mismatch_count + 1;
            error_count = error_count + 1;
            $display("ERROR: softmax_scale mismatch tile=%0d row=%0d got=%0d expected=%0d",
                     tile_idx, row_idx, softmax_scale, expected_scale);
        end

        for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
            idx = value_idx(row_idx, tile_idx, lane_idx);
            got_quant = softmax_result_vec[lane_idx*8 +: 8];
            exp_q16 = expected_exp_vec[lane_idx*17 +: 17];
            got_formula = quant_shift_minus_one(exp_q16);
            golden = golden_quant[idx];

            quant_abs_diff = abs_int(got_quant - golden);
            formula_abs_diff = abs_int(got_quant - got_formula);

            if (quant_abs_diff > row_max_abs_diff[row_idx])
                row_max_abs_diff[row_idx] = quant_abs_diff;
            if (quant_abs_diff > max_abs_diff) begin
                max_abs_diff = quant_abs_diff;
                worst_row = row_idx;
                worst_tile = tile_idx;
                worst_lane = lane_idx;
                worst_golden = golden;
                worst_got = got_quant;
                worst_formula = got_formula;
                worst_score = score_real[idx];
            end
            if (formula_abs_diff > formula_max_abs_diff)
                formula_max_abs_diff = formula_abs_diff;

            if (got_quant != golden) begin
                quant_mismatch_count = quant_mismatch_count + 1;
                row_quant_mismatch[row_idx] = row_quant_mismatch[row_idx] + 1;
            end

            if (got_quant != got_formula) begin
                formula_mismatch_count = formula_mismatch_count + 1;
                row_formula_mismatch[row_idx] = row_formula_mismatch[row_idx] + 1;
                error_count = error_count + 1;
                $display("ERROR: quant formula mismatch row=%0d tile=%0d lane=%0d exp_q16=%0d got=%0d formula=%0d",
                         row_idx, tile_idx, lane_idx, exp_q16, got_quant, got_formula);
            end

            output_count = output_count + 1;
        end
    end
endtask

task run_path2_and_check;
    integer row_idx;
    integer tile_idx;
    integer prev_row;
    integer prev_tile;
    integer prev_valid;
    reg [16*17-1:0] expected_exp_vec;
    reg [23:0] expected_scale;
    begin
        $display("=== NEW PPU QUANT PATH2 START: replay input and check int8 ===");
        prev_valid = 0;
        prev_row = 0;
        prev_tile = 0;
        expected_exp_vec = {16*17{1'b0}};
        expected_scale = 24'd0;

        for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                @(negedge clk);
                drive_softmax_input(tile_idx, row_idx);
                valid = 1'b1;
                if (prev_valid) begin
                    expected_exp_vec = dut.shared_exp_result_vec;
                    expected_scale = dut.path2_scale_comb;
                end

                @(posedge clk);
                #1;
                if (prev_valid)
                    check_quant_output(prev_tile, prev_row, expected_exp_vec, expected_scale);
                else if (softmax_valid !== 1'b0) begin
                    error_count = error_count + 1;
                    $display("ERROR: unexpected first-cycle softmax_valid at path2 start");
                end

                prev_valid = 1;
                prev_row = row_idx;
                prev_tile = tile_idx;
            end
        end

        @(negedge clk);
        valid = 1'b0;
        if (prev_valid) begin
            expected_exp_vec = dut.shared_exp_result_vec;
            expected_scale = dut.path2_scale_comb;
        end

        @(posedge clk);
        #1;
        if (prev_valid)
            check_quant_output(prev_tile, prev_row, expected_exp_vec, expected_scale);

        release dut.softmax_input;
        $display("=== NEW PPU QUANT PATH2 DONE ===");
    end
endtask

task check_final_reset;
    integer row_idx;
    begin
        @(posedge clk);
        #1;
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            if (dut.max_buffer[row_idx] !== 40'sd0) begin
                error_count = error_count + 1;
                $display("ERROR: max_buffer[%0d] not reset after softmax, value=%h",
                         row_idx, dut.max_buffer[row_idx]);
            end
            if (dut.sum_buffer[row_idx] !== 28'd0) begin
                error_count = error_count + 1;
                $display("ERROR: sum_buffer[%0d] not reset after softmax, value=%h",
                         row_idx, dut.sum_buffer[row_idx]);
            end
        end
    end
endtask

task print_summary;
    integer row_idx;
    begin
        $display("=== NEW PPU QUANT SUMMARY ===");
        $display("golden : ppu_quant_cases.txt, ideal base-2 exp normalized to row max then *127");
        $display("dut    : softmax_result_vec from PPU/PPU.v");
        $display("formula: ((LPW_exp << 7) - LPW_exp + 2^15) >> 16");
        $display("outputs=%0d", output_count);
        $display("dut_vs_golden    total_mismatch=%0d max_diff=%0d",
                 quant_mismatch_count, max_abs_diff);
        $display("dut_vs_formula   total_mismatch=%0d max_diff=%0d",
                 formula_mismatch_count, formula_max_abs_diff);
        $display("scale_mismatch   total=%0d", scale_mismatch_count);
        $display("Worst dut/golden diff: row=%0d tile=%0d lane=%0d score=%0.8f golden=%0d dut=%0d formula=%0d",
                 worst_row, worst_tile, worst_lane, worst_score,
                 worst_golden, worst_got, worst_formula);

        $display("row  quant_mismatch  formula_mismatch  max_abs_diff");
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            $display("%2d   %5d           %5d             %3d",
                     row_idx,
                     row_quant_mismatch[row_idx],
                     row_formula_mismatch[row_idx],
                     row_max_abs_diff[row_idx]);
        end
    end
endtask

initial begin
    error_count = 0;
    output_count = 0;
    quant_mismatch_count = 0;
    formula_mismatch_count = 0;
    scale_mismatch_count = 0;
    max_abs_diff = 0;
    formula_max_abs_diff = 0;
    worst_row = 0;
    worst_tile = 0;
    worst_lane = 0;
    worst_golden = 0;
    worst_got = 0;
    worst_formula = 0;
    worst_score = 0.0;

    rst_n = 1'b0;
    valid = 1'b0;
    mac_result_vec = {16*24{1'b0}};
    bias = {16*8{1'b0}};
    score_input_vec = {16*40{1'b0}};

    load_testcase;

    $display("=== NEW PPU QUANT TEST START ===");
    $display("Loaded deterministic vectors: rows=%0d tiles=%0d lanes=%0d outputs=%0d",
             ROWS, TILES, LANES, testcase_count);

    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    run_path1;
    wait_for_path2_ready;
    run_path2_and_check;
    check_final_reset;
    print_summary;

    if (error_count == 0)
        $display("RESULT: PASS protocol/formula_errors=0");
    else
        $display("RESULT: FAIL protocol/formula_errors=%0d", error_count);

    $finish;
end

endmodule

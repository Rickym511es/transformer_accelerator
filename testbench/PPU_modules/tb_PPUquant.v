`timescale 1ns/1ps
// Generate testcase first:
// python testbench/generate_ppu_cases.py
//
// Run example:
// iverilog -g2012 -o tb_PPUquant.vvp PPU_modules.v softmax_modules.v PPU.v testbench/tb_PPUquant.v
// vvp tb_PPUquant.vvp

module tb_PPUquant;

parameter ROWS = 16;
parameter TILES = 64;
parameter LANES = 16;
parameter TOTAL_VALUES = ROWS * TILES * LANES;

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
integer golden_quant [0:TOTAL_VALUES-1];

integer error_count;
integer testcase_count;
integer output_count;
integer normal_mismatch_count;
integer shift_mismatch_count;
integer normal_shift_diff_count;
integer normal_max_abs_diff;
integer shift_max_abs_diff;
integer normal_shift_max_abs_diff;
integer better_normal_count;
integer better_shift_count;
integer equal_error_count;
integer worst_normal_row;
integer worst_normal_tile;
integer worst_normal_lane;
integer worst_normal_golden;
integer worst_normal_value;
integer worst_normal_shift_value;
real worst_normal_score;
integer worst_shift_row;
integer worst_shift_tile;
integer worst_shift_lane;
integer worst_shift_golden;
integer worst_shift_normal_value;
integer worst_shift_value;
real worst_shift_score;

integer row_normal_mismatch [0:ROWS-1];
integer row_shift_mismatch [0:ROWS-1];
integer row_normal_shift_diff [0:ROWS-1];
integer row_normal_max_abs_diff [0:ROWS-1];
integer row_shift_max_abs_diff [0:ROWS-1];
integer row_normal_shift_max_abs_diff [0:ROWS-1];

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

task init_arrays;
    integer row_idx;
    integer idx;
    begin
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            row_normal_mismatch[row_idx] = 0;
            row_shift_mismatch[row_idx] = 0;
            row_normal_shift_diff[row_idx] = 0;
            row_normal_max_abs_diff[row_idx] = 0;
            row_shift_max_abs_diff[row_idx] = 0;
            row_normal_shift_max_abs_diff[row_idx] = 0;
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
        if (fd == 0) begin
            $display("ERROR: cannot open testbench/testcase/ppu_quant_cases.txt");
            $display("Run: python testbench/generate_ppu_cases.py");
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

        force dut.softmax_input = score_input_vec;
    end
endtask

task run_path1;
    integer row_idx;
    integer tile_idx;
    begin
        $display("=== QUANT PATH1 START: collect row max/sum ===");
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
        $display("=== QUANT PATH1 DONE ===");
    end
endtask

task check_path2_quant_output;
    input integer tile_idx;
    input integer row_idx;
    integer lane_idx;
    integer idx;
    integer got_normal;
    integer got_shift;
    integer golden;
    integer normal_abs_diff;
    integer shift_abs_diff;
    integer normal_shift_abs_diff;
    begin
        if ((^softmax_result_vec) === 1'bx) begin
            error_count = error_count + 1;
            $display("ERROR: X detected in softmax_result_vec at tile=%0d row=%0d", tile_idx, row_idx);
        end
        if ((^dut.softmax_shift_debug_vec) === 1'bx) begin
            error_count = error_count + 1;
            $display("ERROR: X detected in internal softmax_shift_debug_vec at tile=%0d row=%0d", tile_idx, row_idx);
        end

        for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
            idx = value_idx(row_idx, tile_idx, lane_idx);
            got_normal = softmax_result_vec[lane_idx*8 +: 8];
            got_shift = dut.softmax_shift_debug_vec[lane_idx*8 +: 8];
            golden = golden_quant[idx];

            normal_abs_diff = abs_int(got_normal - golden);
            shift_abs_diff = abs_int(got_shift - golden);
            normal_shift_abs_diff = abs_int(got_normal - got_shift);

            if (normal_abs_diff > row_normal_max_abs_diff[row_idx])
                row_normal_max_abs_diff[row_idx] = normal_abs_diff;
            if (shift_abs_diff > row_shift_max_abs_diff[row_idx])
                row_shift_max_abs_diff[row_idx] = shift_abs_diff;
            if (normal_shift_abs_diff > row_normal_shift_max_abs_diff[row_idx])
                row_normal_shift_max_abs_diff[row_idx] = normal_shift_abs_diff;

            if (normal_abs_diff > normal_max_abs_diff) begin
                normal_max_abs_diff = normal_abs_diff;
                worst_normal_row = row_idx;
                worst_normal_tile = tile_idx;
                worst_normal_lane = lane_idx;
                worst_normal_golden = golden;
                worst_normal_value = got_normal;
                worst_normal_shift_value = got_shift;
                worst_normal_score = score_real[idx];
            end
            if (shift_abs_diff > shift_max_abs_diff) begin
                shift_max_abs_diff = shift_abs_diff;
                worst_shift_row = row_idx;
                worst_shift_tile = tile_idx;
                worst_shift_lane = lane_idx;
                worst_shift_golden = golden;
                worst_shift_normal_value = got_normal;
                worst_shift_value = got_shift;
                worst_shift_score = score_real[idx];
            end
            if (normal_shift_abs_diff > normal_shift_max_abs_diff)
                normal_shift_max_abs_diff = normal_shift_abs_diff;

            if (got_normal != golden) begin
                normal_mismatch_count = normal_mismatch_count + 1;
                row_normal_mismatch[row_idx] = row_normal_mismatch[row_idx] + 1;
            end

            if (got_shift != golden) begin
                shift_mismatch_count = shift_mismatch_count + 1;
                row_shift_mismatch[row_idx] = row_shift_mismatch[row_idx] + 1;
            end

            if (got_normal != got_shift) begin
                normal_shift_diff_count = normal_shift_diff_count + 1;
                row_normal_shift_diff[row_idx] = row_normal_shift_diff[row_idx] + 1;
            end

            if (normal_abs_diff < shift_abs_diff)
                better_normal_count = better_normal_count + 1;
            else if (shift_abs_diff < normal_abs_diff)
                better_shift_count = better_shift_count + 1;
            else
                equal_error_count = equal_error_count + 1;

            output_count = output_count + 1;
        end
    end
endtask

task run_path2;
    integer row_idx;
    integer tile_idx;
    begin
        $display("=== QUANT PATH2 START: emit normal and shift int8 ===");
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
                check_path2_quant_output(tile_idx, row_idx);
            end
        end

        @(negedge clk);
        valid = 1'b0;
        path2_valid = 1'b0;
        release dut.softmax_input;
        $display("=== QUANT PATH2 DONE ===");
    end
endtask

task print_summary;
    integer row_idx;
    begin
        $display("=== QUANT COMPARISON SETUP ===");
        $display("golden : ideal base-2 softmax, normal int8 quantization, read from ppu_quant_cases.txt");
        $display("normal : PPU output, round(LPW_exp * 127)");
        $display("shift  : internal candidate, floor(LPW_exp * 128), clipped to [0,127]");

        $display("=== QUANT TOTAL MISMATCH / MAX DIFF SUMMARY ===");
        $display("outputs=%0d", output_count);
        $display("normal_vs_golden total_mismatch=%0d max_diff=%0d",
                 normal_mismatch_count, normal_max_abs_diff);
        $display("shift_vs_golden  total_mismatch=%0d max_diff=%0d",
                 shift_mismatch_count, shift_max_abs_diff);
        $display("normal_vs_shift  total_mismatch=%0d max_diff=%0d",
                 normal_shift_diff_count, normal_shift_max_abs_diff);
        $display("closer_to_golden : normal=%0d shift=%0d equal=%0d",
                 better_normal_count, better_shift_count, equal_error_count);

        $display("Worst normal diff: row=%0d tile=%0d lane=%0d score=%0.8f golden=%0d normal=%0d shift=%0d",
                 worst_normal_row, worst_normal_tile, worst_normal_lane,
                 worst_normal_score, worst_normal_golden,
                 worst_normal_value, worst_normal_shift_value);
        $display("Worst shift diff : row=%0d tile=%0d lane=%0d score=%0.8f golden=%0d normal=%0d shift=%0d",
                 worst_shift_row, worst_shift_tile, worst_shift_lane,
                 worst_shift_score, worst_shift_golden,
                 worst_shift_normal_value, worst_shift_value);

        $display("=== QUANT ROW MISMATCH / MAX DIFF SUMMARY ===");
        $display("row normal_mismatch normal_max shift_mismatch shift_max normal_shift_mismatch normal_shift_max");
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            $display("%2d  %4d            %2d         %4d          %2d        %4d                  %2d",
                     row_idx,
                     row_normal_mismatch[row_idx],
                     row_normal_max_abs_diff[row_idx],
                     row_shift_mismatch[row_idx],
                     row_shift_max_abs_diff[row_idx],
                     row_normal_shift_diff[row_idx],
                     row_normal_shift_max_abs_diff[row_idx]);
        end
    end
endtask

initial begin
    error_count = 0;
    output_count = 0;
    normal_mismatch_count = 0;
    shift_mismatch_count = 0;
    normal_shift_diff_count = 0;
    normal_max_abs_diff = 0;
    shift_max_abs_diff = 0;
    normal_shift_max_abs_diff = 0;
    better_normal_count = 0;
    better_shift_count = 0;
    equal_error_count = 0;
    worst_normal_row = 0;
    worst_normal_tile = 0;
    worst_normal_lane = 0;
    worst_normal_golden = 0;
    worst_normal_value = 0;
    worst_normal_shift_value = 0;
    worst_normal_score = 0.0;
    worst_shift_row = 0;
    worst_shift_tile = 0;
    worst_shift_lane = 0;
    worst_shift_golden = 0;
    worst_shift_normal_value = 0;
    worst_shift_value = 0;
    worst_shift_score = 0.0;

    rst_n = 1'b0;
    valid = 1'b0;
    path2_valid = 1'b0;
    mac_result_vec = {16*24{1'b0}};
    bias = {16*8{1'b0}};
    score_input_vec = {16*40{1'b0}};

    load_testcase;

    $display("=== PPU QUANT COMPARISON TEST START ===");
    $display("Testcase file : testbench/testcase/ppu_quant_cases.txt");
    $display("Loaded deterministic vectors: rows=%0d tiles=%0d lanes=%0d outputs=%0d",
             ROWS, TILES, LANES, testcase_count);

    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    run_path1;
    run_path2;
    print_summary;

    if (error_count == 0)
        $display("RESULT: PASS protocol_errors=0");
    else
        $display("RESULT: FAIL protocol_errors=%0d", error_count);

    $finish;
end

endmodule

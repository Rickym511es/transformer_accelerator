`timescale 1ns/1ps
// Generate testcase first if needed:
// python testbench/case_generator/generate_ppu_cases.py
//
// PPU.v-only quantization bench.
// It uses the same ppu_quant_cases.txt score data as the PPU_flow quant tests.
// For quantization-loss comparison, the internal PPU.v softmax_input is forced
// from score_real exactly like the old PPU_flow quant bench. mac_result_vec is
// still filled as round(score * 8) so the external input shape is realistic.
//
// Run from the repo root:
// iverilog -g2012 -I. -o tb_PPU_new_quant.vvp RTL/PPU/PPU_modules.v RTL/PPU/softmax_modules.v RTL/PPU/PPU.v testbench/PPU/modules/tb_PPU_new_quant.v
// vvp tb_PPU_new_quant.vvp

module tb_PPU_new_quant;

parameter ROWS = 16;
parameter TILES = 64;
parameter LANES = 16;
parameter TOTAL_VALUES = ROWS * TILES * LANES;
parameter EXPECTED_PASS_CYCLES = TILES * ROWS * 2;

reg clk;
reg rst_n;
reg valid;
reg signed [16*24-1:0] mac_result_vec;
reg signed [16*40-1:0] score_input_vec;

wire softmax_valid;
wire [16*8-1:0] softmax_result_vec;
wire [23:0] softmax_scale;

real score_real [0:TOTAL_VALUES-1];
integer golden_quant [0:TOTAL_VALUES-1];
reg signed [23:0] qk_transpose_mac [0:TILES-1][0:ROWS-1][0:LANES-1];

integer testcase_count;
integer error_count;
integer output_count;
integer mismatch_count;
integer max_abs_diff;
integer worst_row;
integer worst_tile;
integer worst_lane;
integer worst_golden;
integer worst_value;
real worst_score;

integer row_mismatch [0:ROWS-1];
integer row_max_abs_diff [0:ROWS-1];

integer cycle_count;
integer path1_start_cycle;
integer path1_end_cycle;
integer path2_start_cycle;
integer path2_end_cycle;

PPU dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .valid             (valid),
    .mac_result_vec    (mac_result_vec),
    .softmax_valid     (softmax_valid),
    .softmax_result_vec(softmax_result_vec),
    .softmax_scale     (softmax_scale)
);

initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
end

initial begin
    cycle_count = 0;
end

always @(posedge clk) begin
    cycle_count = cycle_count + 1;
end

function integer value_idx;
    input integer row_idx;
    input integer tile_idx;
    input integer lane_idx;
    begin
        value_idx = ((row_idx * TILES) + tile_idx) * LANES + lane_idx;
    end
endfunction

function integer round_real_to_int;
    input real value;
    begin
        if (value >= 0.0)
            round_real_to_int = $rtoi(value + 0.5);
        else
            round_real_to_int = $rtoi(value - 0.5);
    end
endfunction

function signed [23:0] score_to_mac24;
    input real value;
    integer rounded;
    begin
        rounded = round_real_to_int(value * 8.0);
        score_to_mac24 = rounded[23:0];
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
    integer tile_idx;
    integer lane_idx;
    integer idx;
    begin
        for (idx = 0; idx < TOTAL_VALUES; idx = idx + 1) begin
            score_real[idx] = 0.0;
            golden_quant[idx] = 0;
        end

        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            row_mismatch[row_idx] = 0;
            row_max_abs_diff[row_idx] = 0;
        end

        for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
                    qk_transpose_mac[tile_idx][row_idx][lane_idx] = 24'sd0;
                end
            end
        end
    end
endtask

task build_mac_rows;
    integer row_idx;
    integer tile_idx;
    integer lane_idx;
    integer idx;
    begin
        for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
                    idx = value_idx(row_idx, tile_idx, lane_idx);
                    qk_transpose_mac[tile_idx][row_idx][lane_idx] = score_to_mac24(score_real[idx]);
                end
            end
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
            $display("Tried testbench/testcase, testcase, and testbench/case_generator/testcase.");
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

        build_mac_rows;
    end
endtask

task drive_qk_transpose_row;
    input integer tile_idx;
    input integer row_idx;
    integer lane_idx;
    begin
        mac_result_vec = {16*24{1'b0}};
        for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
            mac_result_vec[lane_idx*24 +: 24] = qk_transpose_mac[tile_idx][row_idx][lane_idx];
        end
    end
endtask

task drive_softmax_row;
    input integer tile_idx;
    input integer row_idx;
    integer lane_idx;
    integer idx;
    begin
        drive_qk_transpose_row(tile_idx, row_idx);
        score_input_vec = {16*40{1'b0}};
        for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
            idx = value_idx(row_idx, tile_idx, lane_idx);
            score_input_vec[lane_idx*40 +: 40] = real_to_q24(score_real[idx]);
        end
        force dut.softmax_input = score_input_vec;
    end
endtask

task drive_idle;
    begin
        valid = 1'b0;
        mac_result_vec = {16*24{1'b0}};
    end
endtask

task reset_dut;
    begin
        rst_n = 1'b0;
        drive_idle;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end
endtask

task check_no_output;
    input [8*96-1:0] tag;
    input integer tile_idx;
    input integer row_idx;
    begin
        if (softmax_valid !== 1'b0) begin
            error_count = error_count + 1;
            $display("ERROR: softmax_valid asserted during %0s tile=%0d row=%0d",
                     tag, tile_idx, row_idx);
        end
    end
endtask

task run_path1;
    integer row_idx;
    integer tile_idx;
    begin
        $display("=== PPU.V PASS1 START: 64 tiles, 32 cycles/tile ===");
        path1_start_cycle = -1;

        for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                @(negedge clk);
                if ((tile_idx == 0) && (row_idx == 0))
                    path1_start_cycle = cycle_count;
                drive_softmax_row(tile_idx, row_idx);
                valid = 1'b1;

                @(posedge clk);
                #1;
                check_no_output("pass1 low half", tile_idx, row_idx);

                @(negedge clk);
                drive_idle;

                @(posedge clk);
                #1;
                check_no_output("pass1 high half", tile_idx, row_idx);
            end
        end

        path1_end_cycle = cycle_count;
        if (dut.path2_mode !== 1'b1) begin
            error_count = error_count + 1;
            $display("ERROR: DUT did not enter pass2 after pass1");
        end
        $display("=== PPU.V PASS1 DONE ===");
    end
endtask

task check_path2_output;
    input integer tile_idx;
    input integer row_idx;
    integer lane_idx;
    integer idx;
    integer got;
    integer golden;
    integer abs_diff;
    begin
        if (softmax_valid !== 1'b1) begin
            error_count = error_count + 1;
            $display("ERROR: softmax_valid missing during pass2 tile=%0d row=%0d",
                     tile_idx, row_idx);
        end
        if ((^softmax_result_vec) === 1'bx) begin
            error_count = error_count + 1;
            $display("ERROR: X detected in softmax_result_vec tile=%0d row=%0d",
                     tile_idx, row_idx);
        end

        for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
            idx = value_idx(row_idx, tile_idx, lane_idx);
            got = softmax_result_vec[lane_idx*8 +: 8];
            golden = golden_quant[idx];
            abs_diff = abs_int(got - golden);

            if (abs_diff > row_max_abs_diff[row_idx])
                row_max_abs_diff[row_idx] = abs_diff;

            if (abs_diff > max_abs_diff) begin
                max_abs_diff = abs_diff;
                worst_row = row_idx;
                worst_tile = tile_idx;
                worst_lane = lane_idx;
                worst_golden = golden;
                worst_value = got;
                worst_score = score_real[idx];
            end

            if (got != golden) begin
                mismatch_count = mismatch_count + 1;
                row_mismatch[row_idx] = row_mismatch[row_idx] + 1;
            end

            output_count = output_count + 1;
        end
    end
endtask

task run_path2;
    integer row_idx;
    integer tile_idx;
    begin
        $display("=== PPU.V PASS2 START: replay same 64 tiles, 32 cycles/tile ===");
        path2_start_cycle = cycle_count;

        for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                @(negedge clk);
                drive_softmax_row(tile_idx, row_idx);
                valid = 1'b1;

                @(posedge clk);
                #1;
                check_no_output("pass2 low half", tile_idx, row_idx);

                @(negedge clk);
                drive_idle;

                @(posedge clk);
                #1;
                check_path2_output(tile_idx, row_idx);
            end
        end

        path2_end_cycle = cycle_count;
        if (dut.path2_mode !== 1'b0) begin
            error_count = error_count + 1;
            $display("ERROR: DUT did not leave pass2 after final tile/row");
        end
        release dut.softmax_input;
        $display("=== PPU.V PASS2 DONE ===");
    end
endtask

task print_summary;
    integer row_idx;
    integer path1_cycles;
    integer path2_cycles;
    begin
        path1_cycles = path1_end_cycle - path1_start_cycle;
        path2_cycles = path2_end_cycle - path2_start_cycle;

        $display("=== PPU.V QUANT COMPARISON SETUP ===");
        $display("golden : ideal base-2 softmax quantization from ppu_quant_cases.txt");
        $display("input  : dut.softmax_input forced from score_real Q24.16, same as PPU_flow quant bench");
        $display("mac    : mac_result_vec also filled as round(score_real * 8)");
        $display("timing : valid row on low half, internal folded LPW high half");

        $display("=== PPU.V TIMING SUMMARY ===");
        $display("path1_cycles=%0d expected=%0d cycles_per_tile=%0d",
                 path1_cycles, EXPECTED_PASS_CYCLES, path1_cycles / TILES);
        $display("path2_cycles=%0d expected=%0d cycles_per_tile=%0d",
                 path2_cycles, EXPECTED_PASS_CYCLES, path2_cycles / TILES);

        if (path1_cycles != EXPECTED_PASS_CYCLES) begin
            error_count = error_count + 1;
            $display("ERROR: pass1 cycle count mismatch");
        end
        if (path2_cycles != EXPECTED_PASS_CYCLES) begin
            error_count = error_count + 1;
            $display("ERROR: pass2 cycle count mismatch");
        end

        $display("=== PPU.V QUANT MISMATCH / MAX DIFF SUMMARY ===");
        $display("outputs=%0d expected=%0d", output_count, TOTAL_VALUES);
        $display("normal_vs_golden total_mismatch=%0d max_diff=%0d",
                 mismatch_count, max_abs_diff);
        $display("Worst diff: row=%0d tile=%0d lane=%0d score=%0.8f golden=%0d got=%0d",
                 worst_row, worst_tile, worst_lane, worst_score, worst_golden, worst_value);

        $display("row mismatch max_diff");
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            $display("%2d  %6d   %3d",
                     row_idx,
                     row_mismatch[row_idx],
                     row_max_abs_diff[row_idx]);
        end
    end
endtask

initial begin
    error_count = 0;
    output_count = 0;
    mismatch_count = 0;
    max_abs_diff = 0;
    worst_row = 0;
    worst_tile = 0;
    worst_lane = 0;
    worst_golden = 0;
    worst_value = 0;
    worst_score = 0.0;
    path1_start_cycle = 0;
    path1_end_cycle = 0;
    path2_start_cycle = 0;
    path2_end_cycle = 0;
    rst_n = 1'b0;
    valid = 1'b0;
    mac_result_vec = {16*24{1'b0}};
    score_input_vec = {16*40{1'b0}};

    load_testcase;

    $display("=== PPU.V NEW QUANT TEST START ===");
    $display("Testcase file : testbench/testcase/ppu_quant_cases.txt");
    $display("Rows=%0d tiles=%0d lanes=%0d values=%0d", ROWS, TILES, LANES, testcase_count);

    reset_dut;
    run_path1;
    run_path2;
    @(negedge clk);
    drive_idle;
    print_summary;

    if ((error_count == 0) && (output_count == TOTAL_VALUES))
        $display("RESULT: PASS protocol_errors=0");
    else
        $display("RESULT: FAIL protocol_errors=%0d outputs=%0d expected=%0d",
                 error_count, output_count, TOTAL_VALUES);

    $finish;
end

endmodule

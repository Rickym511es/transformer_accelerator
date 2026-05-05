`timescale 1ns/1ps
// Generate testcase first:
// python testbench/generate_ppu_cases.py
//
// Run example:
// iverilog -g2012 -o tb_PPU.vvp PPU_modules.v softmax_modules.v PPU.v testbench/tb_PPU.v
// vvp tb_PPU.vvp

module tb_PPU;

parameter ROWS = 16;
parameter TILES = 64;
parameter LANES = 16;
parameter TOTAL_VALUES = ROWS * TILES * LANES;
parameter PRINT_EVERY_RESULT = 0;
parameter CHECK_LOSS_LIMITS = 1;
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
wire [16*17-1:0] softmax_result_vec;

real score_real [0:TOTAL_VALUES-1];
real golden_softmax [0:TOTAL_VALUES-1];
real row_max_real [0:ROWS-1];
real row_output_sum [0:ROWS-1];
real row_abs_loss_sum [0:ROWS-1];
real row_sq_loss_sum [0:ROWS-1];
real row_max_abs_loss [0:ROWS-1];

integer error_count;
integer output_count;
integer testcase_count;
integer worst_row;
integer worst_tile;
integer worst_lane;
real total_abs_loss;
real total_sq_loss;
real total_rel_loss_pct;
real max_abs_loss;
real max_rel_loss_pct;
real worst_golden;
real worst_observed;

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

function real q16_to_real;
    input [16:0] value;
    begin
        q16_to_real = value / 65536.0;
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
            row_abs_loss_sum[row_idx] = 0.0;
            row_sq_loss_sum[row_idx] = 0.0;
            row_max_abs_loss[row_idx] = 0.0;
        end

        for (idx = 0; idx < TOTAL_VALUES; idx = idx + 1) begin
            score_real[idx] = 0.0;
            golden_softmax[idx] = 0.0;
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
    real golden_value;
    begin
        testcase_count = 0;
        init_arrays;

        fd = $fopen("testbench/testcase/ppu_cases.txt", "r");
        if (fd == 0)
            fd = $fopen("testcase/ppu_cases.txt", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open testbench/testcase/ppu_cases.txt");
            $display("Run: python testbench/generate_ppu_cases.py");
            $finish;
        end

        while (!$feof(fd)) begin
            scan_count = $fscanf(fd, "%d %d %d %f %f\n",
                                 row_idx, tile_idx, lane_idx,
                                 score_value, golden_value);
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
                golden_softmax[idx] = golden_value;
                testcase_count = testcase_count + 1;

                if (score_value > row_max_real[row_idx])
                    row_max_real[row_idx] = score_value;
            end
        end

        $fclose(fd);

        if (testcase_count != TOTAL_VALUES) begin
            $display("ERROR: testcase count mismatch, got=%0d expected=%0d", testcase_count, TOTAL_VALUES);
            $finish;
        end
    end
endtask

task drive_score_input;
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

        // This testbench is softmax-only. PMS/BA/ReLU are bypassed here.
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
                drive_score_input(tile_idx, row_idx);
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
    reg [16:0] got_q16;
    real got_real;
    real golden_real;
    real loss;
    real abs_loss;
    real rel_loss_pct;
    begin
        if ((^softmax_result_vec) === 1'bx) begin
            error_count = error_count + 1;
            $display("ERROR: X detected in softmax_result_vec at tile=%0d row=%0d", tile_idx, row_idx);
        end

        for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
            idx = value_idx(row_idx, tile_idx, lane_idx);
            got_q16 = softmax_result_vec[lane_idx*17 +: 17];
            got_real = q16_to_real(got_q16);
            golden_real = golden_softmax[idx];
            loss = got_real - golden_real;
            abs_loss = abs_real(loss);

            if (golden_real > 1.0e-12)
                rel_loss_pct = abs_loss / golden_real * 100.0;
            else
                rel_loss_pct = 0.0;

            row_output_sum[row_idx] = row_output_sum[row_idx] + got_real;
            row_abs_loss_sum[row_idx] = row_abs_loss_sum[row_idx] + abs_loss;
            row_sq_loss_sum[row_idx] = row_sq_loss_sum[row_idx] + loss * loss;
            total_abs_loss = total_abs_loss + abs_loss;
            total_sq_loss = total_sq_loss + loss * loss;
            total_rel_loss_pct = total_rel_loss_pct + rel_loss_pct;
            output_count = output_count + 1;

            if (abs_loss > row_max_abs_loss[row_idx])
                row_max_abs_loss[row_idx] = abs_loss;

            if (abs_loss > max_abs_loss) begin
                max_abs_loss = abs_loss;
                worst_row = row_idx;
                worst_tile = tile_idx;
                worst_lane = lane_idx;
                worst_golden = golden_real;
                worst_observed = got_real;
            end

            if (rel_loss_pct > max_rel_loss_pct)
                max_rel_loss_pct = rel_loss_pct;

            if (PRINT_EVERY_RESULT) begin
                $display("SOFTMAX_RESULT tile=%0d row=%0d lane=%0d score=%0.8f q16=%05h got=%0.8f golden=%0.8f loss=%0.8f abs_loss=%0.8f rel_loss_pct=%0.4f",
                         tile_idx, row_idx, lane_idx, score_real[idx], got_q16,
                         got_real, golden_real, loss, abs_loss, rel_loss_pct);
            end
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
                drive_score_input(tile_idx, row_idx);
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

task print_loss_summary;
    integer row_idx;
    real row_mean_abs;
    real row_rmse;
    real row_sum_loss;
    real mean_abs;
    real rmse;
    real mean_rel_pct;
    begin
        $display("=== SOFTMAX ROW LOSS SUMMARY AGAINST TESTCASE GOLDEN ===");
        $display("row  out_sum      sum_loss     mean_abs_loss  max_abs_loss   rmse");
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            row_mean_abs = row_abs_loss_sum[row_idx] / (TILES * LANES);
            row_rmse = (row_sq_loss_sum[row_idx] / (TILES * LANES)) ** 0.5;
            row_sum_loss = row_output_sum[row_idx] - 1.0;

            $display("%2d   %0.8f   %0.8f   %0.8f     %0.8f     %0.8f",
                     row_idx, row_output_sum[row_idx], row_sum_loss,
                     row_mean_abs, row_max_abs_loss[row_idx], row_rmse);

            if (CHECK_LOSS_LIMITS && abs_real(row_sum_loss) > ROW_SUM_LOSS_LIMIT) begin
                error_count = error_count + 1;
                $display("ERROR: row %0d output sum loss %0.8f exceeds limit %0.8f",
                         row_idx, abs_real(row_sum_loss), ROW_SUM_LOSS_LIMIT);
            end
        end

        mean_abs = total_abs_loss / output_count;
        rmse = (total_sq_loss / output_count) ** 0.5;
        mean_rel_pct = total_rel_loss_pct / output_count;

        $display("=== SOFTMAX GLOBAL LOSS SUMMARY AGAINST TESTCASE GOLDEN ===");
        $display("outputs              : %0d", output_count);
        $display("mean_abs_loss        : %0.8f", mean_abs);
        $display("max_abs_loss         : %0.8f", max_abs_loss);
        $display("rmse                 : %0.8f", rmse);
        $display("mean_rel_loss_pct    : %0.4f", mean_rel_pct);
        $display("max_rel_loss_pct     : %0.4f", max_rel_loss_pct);
        $display("worst_location       : row=%0d tile=%0d lane=%0d", worst_row, worst_tile, worst_lane);
        $display("worst_observed/golden: %0.8f / %0.8f", worst_observed, worst_golden);

        if (CHECK_LOSS_LIMITS && max_abs_loss > MAX_ABS_LOSS_LIMIT) begin
            error_count = error_count + 1;
            $display("ERROR: max_abs_loss %0.8f exceeds limit %0.8f", max_abs_loss, MAX_ABS_LOSS_LIMIT);
        end
    end
endtask

initial begin
    error_count = 0;
    output_count = 0;
    total_abs_loss = 0.0;
    total_sq_loss = 0.0;
    total_rel_loss_pct = 0.0;
    max_abs_loss = 0.0;
    max_rel_loss_pct = 0.0;
    worst_row = 0;
    worst_tile = 0;
    worst_lane = 0;
    worst_golden = 0.0;
    worst_observed = 0.0;

    rst_n = 1'b0;
    valid = 1'b0;
    path2_valid = 1'b0;
    mac_result_vec = {16*24{1'b0}};
    bias = {16*8{1'b0}};
    score_input_vec = {16*40{1'b0}};

    load_testcase;

    $display("=== SOFTMAX-ONLY PPU TEST START ===");
    $display("Testcase file : testbench/testcase/ppu_cases.txt");
    $display("Columns       : row tile lane score_real golden_softmax");
    $display("Golden output : precomputed outside this testbench");
    $display("PMS/BA/ReLU   : bypassed in this softmax-loss test");
    $display("Loaded deterministic vectors: rows=%0d tiles=%0d lanes=%0d outputs=%0d",
             ROWS, TILES, LANES, testcase_count);
    $display("PRINT_EVERY_RESULT=%0d CHECK_LOSS_LIMITS=%0d", PRINT_EVERY_RESULT, CHECK_LOSS_LIMITS);

    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    run_path1;
    check_path1_max_buffer;
    run_path2;
    check_final_reset;
    print_loss_summary;

    if (error_count == 0)
        $display("RESULT: PASS");
    else
        $display("RESULT: FAIL errors=%0d", error_count);

    $finish;
end

endmodule

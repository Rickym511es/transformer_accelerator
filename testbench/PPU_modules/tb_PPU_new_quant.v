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
real row_score_max [0:ROWS-1];
real row_sum_exp2 [0:ROWS-1];
real golden_scale_real [0:ROWS-1];
real row_scale_abs_loss_sum [0:ROWS-1];
real row_scale_max_abs_loss [0:ROWS-1];
integer golden_quant [0:TOTAL_VALUES-1];

integer error_count;
integer testcase_count;
integer output_count;
integer quant_mismatch_count;
integer scale_output_count;
integer max_abs_diff;
integer worst_row;
integer worst_tile;
integer worst_lane;
integer worst_golden;
integer worst_got;
real worst_score;
integer worst_scale_row;
integer worst_scale_tile;
real worst_scale_got;
real worst_scale_golden;
real worst_scale_loss;
real worst_scale_rel_pct;
real scale_abs_loss_sum;
real scale_sq_loss_sum;
real scale_max_abs_loss;
real scale_max_rel_loss_pct;

integer row_quant_mismatch [0:ROWS-1];
integer row_max_abs_diff [0:ROWS-1];

integer cycle_count;
integer path1_first_cycle;
integer path1_last_cycle;
integer path2_ready_cycle;
integer path2_first_input_cycle;
integer path2_last_input_cycle;
integer first_output_cycle;
integer last_output_cycle;
integer path1_input_count;
integer path2_input_count;

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

function signed [39:0] real_to_q24;
    input real value;
    begin
        real_to_q24 = $rtoi(value * 65536.0);
    end
endfunction

function real q24_scale_to_real;
    input [23:0] value;
    begin
        q24_scale_to_real = value / 16777216.0;
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
            row_quant_mismatch[row_idx] = 0;
            row_max_abs_diff[row_idx] = 0;
            row_score_max[row_idx] = -1.0e30;
            row_sum_exp2[row_idx] = 0.0;
            golden_scale_real[row_idx] = 0.0;
            row_scale_abs_loss_sum[row_idx] = 0.0;
            row_scale_max_abs_loss[row_idx] = 0.0;
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

                if (score_value > row_score_max[row_idx])
                    row_score_max[row_idx] = score_value;
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

        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            row_sum_exp2[row_idx] = 0.0;
            for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
                for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
                    idx = value_idx(row_idx, tile_idx, lane_idx);
                    row_sum_exp2[row_idx] = row_sum_exp2[row_idx] +
                                            (2.0 ** (score_real[idx] - row_score_max[row_idx]));
                end
            end

            if (row_sum_exp2[row_idx] != 0.0)
                golden_scale_real[row_idx] = 1.0 / (127.0 * row_sum_exp2[row_idx]);
            else
                golden_scale_real[row_idx] = 0.0;
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
                if (path1_input_count == 0)
                    path1_first_cycle = cycle_count;
                path1_last_cycle = cycle_count;
                path1_input_count = path1_input_count + 1;
                if (softmax_valid !== 1'b0) begin
                    error_count = error_count + 1;
                    $display("ERROR: softmax_valid asserted during path1 tile=%0d row=%0d",
                             tile_idx, row_idx);
                end
            end
        end

        @(negedge clk);
        valid = 1'b0;
        $display("=== NEW PPU QUANT PATH1 INPUT DONE: wait for path1 buffer drain ===");
    end
endtask

task wait_for_path2_ready;
    integer wait_count;
    begin
        wait_count = 0;
        while (dut.path2_mode !== 1'b1) begin
            @(posedge clk);
            #1;
            wait_count = wait_count + 1;
            if (wait_count > 16) begin
                error_count = error_count + 1;
                $display("ERROR: timeout waiting for serialized path2 start");
                $finish;
            end
        end

        path2_ready_cycle = cycle_count;
        $display("=== NEW PPU QUANT PATH2 READY after %0d drain cycle(s) ===", wait_count);
    end
endtask

task check_quant_output;
    input integer tile_idx;
    input integer row_idx;
    integer lane_idx;
    integer idx;
    integer got_quant;
    integer golden;
    integer quant_abs_diff;
    real scale_got_real;
    real scale_golden_real;
    real scale_loss;
    real scale_abs_loss;
    real scale_rel_loss_pct;
    begin
        if (softmax_valid !== 1'b1) begin
            error_count = error_count + 1;
            $display("ERROR: softmax_valid missing for path2 output tile=%0d row=%0d",
                     tile_idx, row_idx);
        end

        if (output_count == 0)
            first_output_cycle = cycle_count;
        last_output_cycle = cycle_count;

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
        else begin
            scale_got_real = q24_scale_to_real(softmax_scale);
            scale_golden_real = golden_scale_real[row_idx];
            scale_loss = scale_got_real - scale_golden_real;
            scale_abs_loss = scale_loss;
            if (scale_abs_loss < 0.0)
                scale_abs_loss = -scale_abs_loss;

            if (scale_golden_real != 0.0)
                scale_rel_loss_pct = (scale_abs_loss / scale_golden_real) * 100.0;
            else
                scale_rel_loss_pct = 0.0;

            scale_output_count = scale_output_count + 1;
            scale_abs_loss_sum = scale_abs_loss_sum + scale_abs_loss;
            scale_sq_loss_sum = scale_sq_loss_sum + scale_loss * scale_loss;
            row_scale_abs_loss_sum[row_idx] = row_scale_abs_loss_sum[row_idx] + scale_abs_loss;
            if (scale_abs_loss > row_scale_max_abs_loss[row_idx])
                row_scale_max_abs_loss[row_idx] = scale_abs_loss;

            if (scale_abs_loss > scale_max_abs_loss) begin
                scale_max_abs_loss = scale_abs_loss;
                worst_scale_row = row_idx;
                worst_scale_tile = tile_idx;
                worst_scale_got = scale_got_real;
                worst_scale_golden = scale_golden_real;
                worst_scale_loss = scale_loss;
                worst_scale_rel_pct = scale_rel_loss_pct;
            end
            if (scale_rel_loss_pct > scale_max_rel_loss_pct)
                scale_max_rel_loss_pct = scale_rel_loss_pct;
        end

        for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
            idx = value_idx(row_idx, tile_idx, lane_idx);
            got_quant = softmax_result_vec[lane_idx*8 +: 8];
            golden = golden_quant[idx];

            quant_abs_diff = abs_int(got_quant - golden);

            if (quant_abs_diff > row_max_abs_diff[row_idx])
                row_max_abs_diff[row_idx] = quant_abs_diff;
            if (quant_abs_diff > max_abs_diff) begin
                max_abs_diff = quant_abs_diff;
                worst_row = row_idx;
                worst_tile = tile_idx;
                worst_lane = lane_idx;
                worst_golden = golden;
                worst_got = got_quant;
                worst_score = score_real[idx];
            end

            if (got_quant != golden) begin
                quant_mismatch_count = quant_mismatch_count + 1;
                row_quant_mismatch[row_idx] = row_quant_mismatch[row_idx] + 1;
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
    integer flush_i;
    begin
        $display("=== NEW PPU QUANT PATH2 START: serialized replay stream and check int8 ===");
        prev_valid = 0;
        prev_row = 0;
        prev_tile = 0;

        for (tile_idx = 0; tile_idx < TILES; tile_idx = tile_idx + 1) begin
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                @(negedge clk);
                drive_softmax_input(tile_idx, row_idx);
                valid = 1'b1;

                @(posedge clk);
                #1;
                if (path2_input_count == 0)
                    path2_first_input_cycle = cycle_count;
                path2_last_input_cycle = cycle_count;
                path2_input_count = path2_input_count + 1;

                if (prev_valid)
                    check_quant_output(prev_tile, prev_row);
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

        for (flush_i = 0; flush_i < 2; flush_i = flush_i + 1) begin
            @(posedge clk);
            #1;

            if (prev_valid)
                check_quant_output(prev_tile, prev_row);
            else if (softmax_valid !== 1'b0) begin
                error_count = error_count + 1;
                $display("ERROR: unexpected softmax_valid during path2 flush");
            end

            prev_valid = 0;
        end

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
    real scale_mean_abs_loss;
    real scale_rmse;
    real row_scale_mean_abs_loss;
    begin
        scale_mean_abs_loss = 0.0;
        scale_rmse = 0.0;
        if (scale_output_count > 0) begin
            scale_mean_abs_loss = scale_abs_loss_sum / scale_output_count;
            scale_rmse = (scale_sq_loss_sum / scale_output_count) ** 0.5;
        end

        $display("=== NEW PPU TIMING SUMMARY ===");
        $display("PPU_flow reference beats: path1=%0d path2=%0d total_input_beats=%0d",
                 TILES * ROWS, TILES * ROWS, TILES * ROWS * 2);
        $display("PPU.v path1_input_count=%0d first_cycle=%0d last_cycle=%0d",
                 path1_input_count, path1_first_cycle, path1_last_cycle);
        $display("PPU.v path2_ready_cycle=%0d wait_after_path1=%0d",
                 path2_ready_cycle, path2_ready_cycle - path1_last_cycle);
        $display("PPU.v path2_input_count=%0d first_cycle=%0d last_cycle=%0d",
                 path2_input_count, path2_first_input_cycle, path2_last_input_cycle);
        $display("PPU.v output first_cycle=%0d last_cycle=%0d tail_after_last_path2_input=%0d",
                 first_output_cycle, last_output_cycle, last_output_cycle - path2_last_input_cycle);
        $display("PPU.v active_total_cycles=%0d",
                 last_output_cycle - path1_first_cycle + 1);

        $display("=== NEW PPU QUANT SUMMARY ===");
        $display("golden : ppu_quant_cases.txt, ideal base-2 exp normalized to row max then *127");
        $display("dut    : softmax_result_vec from PPU/PPU.v");
        $display("mode   : PMS/BA/ReLU bypassed; force dut.softmax_input for quantize-only check");
        $display("outputs=%0d", output_count);
        $display("quant_mismatch total=%0d max_diff=%0d",
                 quant_mismatch_count, max_abs_diff);
        $display("Worst quant diff: row=%0d tile=%0d lane=%0d score=%0.8f golden=%0d dut=%0d",
                 worst_row, worst_tile, worst_lane, worst_score,
                 worst_golden, worst_got);

        $display("row  quant_mismatch  max_abs_diff");
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            $display("%2d   %5d           %3d",
                     row_idx,
                     row_quant_mismatch[row_idx],
                     row_max_abs_diff[row_idx]);
        end

        $display("=== NEW PPU SCALE LOSS SUMMARY ===");
        $display("scale format : UQ0.24, expected ideal = 1 / (127 * sum(2^(score-row_max)))");
        $display("scale outputs=%0d mean_abs=%0.10f max_abs=%0.10f rmse=%0.10f max_rel_pct=%0.4f",
                 scale_output_count, scale_mean_abs_loss, scale_max_abs_loss,
                 scale_rmse, scale_max_rel_loss_pct);
        $display("Worst scale loss: row=%0d tile=%0d got=%0.10f golden=%0.10f loss=%0.10f rel_pct=%0.4f",
                 worst_scale_row, worst_scale_tile, worst_scale_got,
                 worst_scale_golden, worst_scale_loss, worst_scale_rel_pct);

        $display("row  scale_mean_abs  scale_max_abs");
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            row_scale_mean_abs_loss = row_scale_abs_loss_sum[row_idx] / TILES;
            $display("%2d   %0.10f      %0.10f",
                     row_idx, row_scale_mean_abs_loss, row_scale_max_abs_loss[row_idx]);
        end
    end
endtask

initial begin
    error_count = 0;
    output_count = 0;
    quant_mismatch_count = 0;
    scale_output_count = 0;
    max_abs_diff = 0;
    worst_row = 0;
    worst_tile = 0;
    worst_lane = 0;
    worst_golden = 0;
    worst_got = 0;
    worst_score = 0.0;
    worst_scale_row = 0;
    worst_scale_tile = 0;
    worst_scale_got = 0.0;
    worst_scale_golden = 0.0;
    worst_scale_loss = 0.0;
    worst_scale_rel_pct = 0.0;
    scale_abs_loss_sum = 0.0;
    scale_sq_loss_sum = 0.0;
    scale_max_abs_loss = 0.0;
    scale_max_rel_loss_pct = 0.0;
    path1_first_cycle = -1;
    path1_last_cycle = -1;
    path2_ready_cycle = -1;
    path2_first_input_cycle = -1;
    path2_last_input_cycle = -1;
    first_output_cycle = -1;
    last_output_cycle = -1;
    path1_input_count = 0;
    path2_input_count = 0;

    rst_n = 1'b0;
    valid = 1'b0;
    mac_result_vec = {16*24{1'b0}};
    bias = {16*8{1'b0}};
    score_input_vec = {16*40{1'b0}};

    load_testcase;

    $display("=== NEW PPU QUANT TEST START ===");
    $display("PMS/BA/ReLU bypassed by force; this TB checks quantized softmax output and scale loss.");
    $display("Flow         : serialized path1 stream, drain, then path2 replay stream.");
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

    if ((error_count == 0) && (quant_mismatch_count == 0))
        $display("RESULT: PASS quant_mismatch=0");
    else
        $display("RESULT: FAIL protocol_errors=%0d quant_mismatch=%0d",
                 error_count, quant_mismatch_count);

    $finish;
end

endmodule

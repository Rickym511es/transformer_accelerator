`timescale 1ns/1ps
//
// PPU quantization mismatch test for the MAC -> PPU testcase.
//
// This bench does not instantiate MAC.  It reads the Python-generated
// MAC result matrix and base-2 softmax quant golden, feeds PPU in the same
// two-pass / 16-row-group order, then reports hardware quantization mismatch.
//
// Generate testcase first:
//   python testbench/case_generator/generate_mac_ppu_cases.py
//
// Run example from the repo root:
//   iverilog -g2012 -I. -o tb_MAC_PPU_quant_compare.vvp \
//       PPU/softmax_modules.v PPU/PPU.v \
//       testbench/tb_MAC_PPU_quant_compare.v
//   vvp tb_MAC_PPU_quant_compare.vvp

module tb_MAC_PPU_quant_compare;

parameter real CYCLE = 10.0;
parameter integer MAT_M = 1024;
parameter integer MAT_N = 1024;
parameter integer VL = 16;
parameter integer AD = 16;
parameter integer M_TILE_NUM = MAT_M / VL;
parameter integer N_TILE_NUM = MAT_N / AD;
parameter integer TOTAL_OUTPUTS = MAT_M * MAT_N;
parameter integer PPU_CYCLES_PER_TILE = VL * 2;
parameter integer QUANT_TOLERANCE = 0;
parameter integer FAIL_ON_QUANT_MISMATCH = 0;
parameter integer END_CYCLE = 500000;

reg clk;
reg rst_n;
reg valid;
reg signed [16*24-1:0] mac_result_vec;

wire softmax_valid;
wire [16*8-1:0] softmax_result_vec;
wire [23:0] softmax_scale;

integer mac_score_file [0:MAT_M-1][0:MAT_N-1];
integer golden_quant_file [0:MAT_M-1][0:MAT_N-1];
integer row_mismatch [0:MAT_M-1];
integer row_max_abs_diff [0:MAT_M-1];

integer cycle_count;
integer ppu_tile_count;
integer ppu_cycle_count;
integer output_count;
integer protocol_error_count;
integer quant_mismatch_count;
integer quant_fail_count;
integer max_abs_diff;
integer first_fail_seen;
integer first_fail_global_row;
integer first_fail_col;
integer first_fail_got;
integer first_fail_expected;
integer worst_global_row;
integer worst_col;
integer worst_got;
integer worst_expected;
integer worst_mac_score;

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
    forever #(CYCLE / 2.0) clk = ~clk;
end

initial begin
    cycle_count = 0;
end

always @(posedge clk) begin
    cycle_count = cycle_count + 1;
end

function integer abs_int;
    input integer value;
    begin
        if (value < 0)
            abs_int = -value;
        else
            abs_int = value;
    end
endfunction

task clear_input;
    begin
        valid = 1'b0;
        mac_result_vec = {16*24{1'b0}};
    end
endtask

task open_case_file;
    input [256*8-1:0] primary_path;
    input [256*8-1:0] fallback_path;
    output integer fd;
    begin
        fd = $fopen(primary_path, "r");
        if (fd == 0)
            fd = $fopen(fallback_path, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open testcase file:");
            $display("  %0s", primary_path);
            $display("  %0s", fallback_path);
            $display("Generate it with:");
            $display("  python testbench/case_generator/generate_mac_ppu_cases.py");
            $finish;
        end
    end
endtask

task read_mac_score_file;
    integer fd;
    integer row_idx;
    integer col_idx;
    integer scan_count;
    integer value;
    begin
        open_case_file("testbench/testcase/mac_ppu/pat0/mac_score_int24.txt",
                       "testcase/mac_ppu/pat0/mac_score_int24.txt",
                       fd);
        for (row_idx = 0; row_idx < MAT_M; row_idx = row_idx + 1) begin
            for (col_idx = 0; col_idx < MAT_N; col_idx = col_idx + 1) begin
                scan_count = $fscanf(fd, "%d", value);
                if (scan_count != 1) begin
                    $display("ERROR: mac_score_int24.txt ended early at row=%0d col=%0d",
                             row_idx, col_idx);
                    $finish;
                end
                mac_score_file[row_idx][col_idx] = value;
            end
        end
        $fclose(fd);
    end
endtask

task read_golden_quant_file;
    integer fd;
    integer row_idx;
    integer col_idx;
    integer scan_count;
    integer value;
    begin
        open_case_file("testbench/testcase/mac_ppu/pat0/base2_softmax_quant.txt",
                       "testcase/mac_ppu/pat0/base2_softmax_quant.txt",
                       fd);
        for (row_idx = 0; row_idx < MAT_M; row_idx = row_idx + 1) begin
            for (col_idx = 0; col_idx < MAT_N; col_idx = col_idx + 1) begin
                scan_count = $fscanf(fd, "%d", value);
                if (scan_count != 1) begin
                    $display("ERROR: base2_softmax_quant.txt ended early at row=%0d col=%0d",
                             row_idx, col_idx);
                    $finish;
                end
                golden_quant_file[row_idx][col_idx] = value;
            end
        end
        $fclose(fd);
    end
endtask

task load_testcase;
    begin
        $display("=== LOADING MAC -> PPU QUANT TESTCASE ===");
        $display("Path: testbench/testcase/mac_ppu/pat0");
        read_mac_score_file;
        read_golden_quant_file;
        $display("Loaded mac_score_int24.txt and base2_softmax_quant.txt");
    end
endtask

task reset_dut;
    begin
        rst_n = 1'b0;
        clear_input;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end
endtask

task init_scoreboards;
    integer row_idx;
    begin
        ppu_tile_count = 0;
        ppu_cycle_count = 0;
        output_count = 0;
        protocol_error_count = 0;
        quant_mismatch_count = 0;
        quant_fail_count = 0;
        max_abs_diff = 0;
        first_fail_seen = 0;
        worst_global_row = 0;
        worst_col = 0;
        worst_got = 0;
        worst_expected = 0;
        worst_mac_score = 0;

        for (row_idx = 0; row_idx < MAT_M; row_idx = row_idx + 1) begin
            row_mismatch[row_idx] = 0;
            row_max_abs_diff[row_idx] = 0;
        end
    end
endtask

task drive_mac_score_row;
    input integer m_tile_idx;
    input integer n_tile_idx;
    input integer row_lane;
    integer lane_idx;
    integer global_row;
    integer global_col;
    begin
        global_row = (m_tile_idx * VL) + row_lane;
        mac_result_vec = {16*24{1'b0}};
        for (lane_idx = 0; lane_idx < AD; lane_idx = lane_idx + 1) begin
            global_col = (n_tile_idx * AD) + lane_idx;
            mac_result_vec[lane_idx*24 +: 24] =
                mac_score_file[global_row][global_col];
        end
    end
endtask

task check_no_output;
    input integer pass_idx;
    input integer m_tile_idx;
    input integer n_tile_idx;
    input integer row_lane;
    begin
        if (softmax_valid !== 1'b0) begin
            protocol_error_count = protocol_error_count + 1;
            $display("ERROR: unexpected softmax_valid pass=%0d m_tile=%0d n_tile=%0d row=%0d",
                     pass_idx, m_tile_idx, n_tile_idx, row_lane);
        end
    end
endtask

task check_output;
    input integer m_tile_idx;
    input integer n_tile_idx;
    input integer row_lane;
    integer lane_idx;
    integer global_row;
    integer global_col;
    integer got;
    integer expected;
    integer abs_diff;
    begin
        if (softmax_valid !== 1'b1) begin
            protocol_error_count = protocol_error_count + 1;
            $display("ERROR: missing softmax_valid m_tile=%0d n_tile=%0d row=%0d",
                     m_tile_idx, n_tile_idx, row_lane);
        end

        if ((^softmax_result_vec) === 1'bx) begin
            protocol_error_count = protocol_error_count + 1;
            $display("ERROR: X detected in softmax_result_vec m_tile=%0d n_tile=%0d row=%0d",
                     m_tile_idx, n_tile_idx, row_lane);
        end

        global_row = (m_tile_idx * VL) + row_lane;
        for (lane_idx = 0; lane_idx < AD; lane_idx = lane_idx + 1) begin
            global_col = (n_tile_idx * AD) + lane_idx;
            got = softmax_result_vec[lane_idx*8 +: 8];
            expected = golden_quant_file[global_row][global_col];
            abs_diff = abs_int(got - expected);

            if (abs_diff > max_abs_diff) begin
                max_abs_diff = abs_diff;
                worst_global_row = global_row;
                worst_col = global_col;
                worst_got = got;
                worst_expected = expected;
                worst_mac_score = mac_score_file[global_row][global_col];
            end

            if (abs_diff > row_max_abs_diff[global_row])
                row_max_abs_diff[global_row] = abs_diff;

            if (abs_diff > QUANT_TOLERANCE) begin
                quant_mismatch_count = quant_mismatch_count + 1;
                row_mismatch[global_row] = row_mismatch[global_row] + 1;
                if (!first_fail_seen) begin
                    first_fail_seen = 1;
                    first_fail_global_row = global_row;
                    first_fail_col = global_col;
                    first_fail_got = got;
                    first_fail_expected = expected;
                end
                if (FAIL_ON_QUANT_MISMATCH)
                    quant_fail_count = quant_fail_count + 1;
            end

            output_count = output_count + 1;
        end
    end
endtask

task run_ppu_tile;
    input integer pass_idx;
    input integer m_tile_idx;
    input integer n_tile_idx;
    integer row_lane;
    integer start_cycle;
    integer elapsed_cycles;
    begin
        start_cycle = cycle_count;

        for (row_lane = 0; row_lane < VL; row_lane = row_lane + 1) begin
            @(negedge clk);
            drive_mac_score_row(m_tile_idx, n_tile_idx, row_lane);
            valid = 1'b1;

            @(posedge clk);
            #1;
            check_no_output(pass_idx, m_tile_idx, n_tile_idx, row_lane);

            @(negedge clk);
            clear_input;

            @(posedge clk);
            #1;
            if (pass_idx == 0)
                check_no_output(pass_idx, m_tile_idx, n_tile_idx, row_lane);
            else
                check_output(m_tile_idx, n_tile_idx, row_lane);
        end

        elapsed_cycles = cycle_count - start_cycle;
        ppu_cycle_count = ppu_cycle_count + elapsed_cycles;
        ppu_tile_count = ppu_tile_count + 1;

        if (elapsed_cycles != PPU_CYCLES_PER_TILE) begin
            protocol_error_count = protocol_error_count + 1;
            $display("ERROR: PPU tile cycles pass=%0d m_tile=%0d n_tile=%0d got=%0d expected=%0d",
                     pass_idx, m_tile_idx, n_tile_idx, elapsed_cycles,
                     PPU_CYCLES_PER_TILE);
        end
    end
endtask

task run_row_group;
    input integer m_tile_idx;
    integer pass_idx;
    integer n_tile_idx;
    begin
        $display("=== QUANT ROW GROUP %0d/%0d START ===",
                 m_tile_idx + 1, M_TILE_NUM);

        for (pass_idx = 0; pass_idx < 2; pass_idx = pass_idx + 1) begin
            for (n_tile_idx = 0; n_tile_idx < N_TILE_NUM; n_tile_idx = n_tile_idx + 1) begin
                run_ppu_tile(pass_idx, m_tile_idx, n_tile_idx);
            end

            if ((pass_idx == 0) && (dut.path2_mode !== 1'b1)) begin
                protocol_error_count = protocol_error_count + 1;
                $display("ERROR: PPU did not enter path2 after row group %0d pass 0",
                         m_tile_idx);
            end
        end

        if (dut.path2_mode !== 1'b0) begin
            protocol_error_count = protocol_error_count + 1;
            $display("ERROR: PPU did not leave path2 after row group %0d pass 1",
                     m_tile_idx);
        end

        @(negedge clk);
        clear_input;
        $display("=== QUANT ROW GROUP %0d DONE ===", m_tile_idx + 1);
    end
endtask

task print_summary;
    integer row_idx;
    integer printed_rows;
    integer total_errors;
    begin
        total_errors = protocol_error_count + quant_fail_count;

        $display("============================================================");
        $display("MAC -> PPU QUANTIZATION COMPARE SUMMARY");
        $display("Input : Python mac_score_int24.txt, fed into PPU in two-pass order");
        $display("Golden: Python normal base-2 softmax quant, scales ignored");
        $display("Quant : q = round((softmax / max_softmax) * 127)");
        $display("Timing: PPU cycles/tile=%0d observed=%0d over %0d tiles",
                 PPU_CYCLES_PER_TILE,
                 (ppu_tile_count == 0) ? 0 : (ppu_cycle_count / ppu_tile_count),
                 ppu_tile_count);
        $display("protocol_errors=%0d", protocol_error_count);
        $display("outputs=%0d expected=%0d", output_count, TOTAL_OUTPUTS);
        $display("quant_mismatch_count=%0d tolerance=%0d fail_on_mismatch=%0d",
                 quant_mismatch_count, QUANT_TOLERANCE, FAIL_ON_QUANT_MISMATCH);
        $display("max_abs_diff=%0d at row=%0d col=%0d mac_score=%0d got=%0d expected=%0d",
                 max_abs_diff, worst_global_row, worst_col, worst_mac_score,
                 worst_got, worst_expected);

        if (first_fail_seen) begin
            $display("first quant diff: row=%0d col=%0d got=%0d expected=%0d",
                     first_fail_global_row, first_fail_col,
                     first_fail_got, first_fail_expected);
        end

        $display("Rows with quant diffs (first 16 nonzero rows):");
        printed_rows = 0;
        for (row_idx = 0; row_idx < MAT_M; row_idx = row_idx + 1) begin
            if ((row_mismatch[row_idx] != 0) && (printed_rows < 16)) begin
                $display("  row=%0d mismatches=%0d max_abs_diff=%0d",
                         row_idx, row_mismatch[row_idx],
                         row_max_abs_diff[row_idx]);
                printed_rows = printed_rows + 1;
            end
        end
        if (printed_rows == 0)
            $display("  none");

        if ((total_errors == 0) && (output_count == TOTAL_OUTPUTS))
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL total_errors=%0d outputs=%0d expected=%0d",
                     total_errors, output_count, TOTAL_OUTPUTS);
        $display("============================================================");
    end
endtask

integer m_tile_idx;

initial begin
    init_scoreboards;
    rst_n = 1'b0;
    clear_input;

    $display("=== MAC -> PPU QUANTIZATION COMPARE TEST START ===");
    $display("Testcase path: testbench/testcase/mac_ppu/pat0");
    $display("FAIL_ON_QUANT_MISMATCH=%0d, QUANT_TOLERANCE=%0d",
             FAIL_ON_QUANT_MISMATCH, QUANT_TOLERANCE);

    load_testcase;
    reset_dut;

    for (m_tile_idx = 0; m_tile_idx < M_TILE_NUM; m_tile_idx = m_tile_idx + 1) begin
        run_row_group(m_tile_idx);
    end

    print_summary;
    $finish;
end

initial begin
    #(END_CYCLE * CYCLE);
    $display("ERROR: timeout at cycle %0d", cycle_count);
    $finish;
end

endmodule

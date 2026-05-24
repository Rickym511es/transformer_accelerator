`timescale 1ns/1ps
//
// PPU-only gate-level testbench.
//
// Drives ONLY the PPU top-level ports (clk, rst_n, valid, mac_result_vec).
// No hierarchical references into the DUT, so it works on the post-synthesis
// flattened netlist.
//
// Stimulus comes from the existing mac_ppu testcase:
//   testbench/testcase/mac_ppu/pat0/mac_score_int24.txt   (signed int24)
//   testbench/testcase/mac_ppu/pat0/base2_softmax_quant.txt (int8 golden)
//
// Protocol (one tile = 16 rows, each row = 2 half-cycles):
//   For each of 16 rows:
//     low  half: ppu_valid = 1, mac_result_vec = row data
//     high half: ppu_valid = 0
//   Pass 0 walks all 64 N-tiles to build PPU's max/sum state (path1).
//   Pass 1 walks all 64 N-tiles and checks the int8 softmax output (path2).
//
// Workload scoped to 1 M row-group by default to keep gate-sim runtime sane.
// Override M_TILE_LIMIT via +define if you want more rows.
//
// RTL run example (sanity check before gate sim):
//   iverilog -g2012 -I. -o tb_PPU_gate.vvp \
//       PPU/softmax_modules.v PPU/PPU_modules.v PPU/PPU.v \
//       testbench/PPU_gate/tb_PPU_gate.v
//   vvp tb_PPU_gate.vvp
//
// Gate sim is driven by GATE/PPU/gate.f.

module tb_PPU_gate;

parameter real    CYCLE      = 10.0;
parameter integer MAT_M      = 1024;
parameter integer MAT_N      = 1024;
parameter integer VL         = 16;
parameter integer AD         = 16;
parameter integer M_TILE_NUM = MAT_M / VL;
parameter integer N_TILE_NUM = MAT_N / AD;
parameter integer END_CYCLE  = 2000000;

`ifndef M_TILE_LIMIT
  `define M_TILE_LIMIT 1
`endif

reg clk;
reg rst_n;
reg ppu_valid;
reg signed [16*24-1:0] ppu_mac_result_vec;
wire ppu_softmax_valid;
wire [16*8-1:0] ppu_softmax_result_vec;
wire [23:0] ppu_softmax_scale;

PPU ppu_dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .valid             (ppu_valid),
    .mac_result_vec    (ppu_mac_result_vec),
    .softmax_valid     (ppu_softmax_valid),
    .softmax_result_vec(ppu_softmax_result_vec),
    .softmax_scale     (ppu_softmax_scale)
);

integer mac_score_file    [0:MAT_M-1][0:MAT_N-1];
integer golden_quant_file [0:MAT_M-1][0:MAT_N-1];

integer cycle_count;
integer ppu_output_count;
integer protocol_error_count;
integer quant_mismatch_count;
integer max_quant_abs_diff;
integer first_quant_fail_seen;
integer first_quant_fail_m_tile;
integer first_quant_fail_n_tile;
integer first_quant_fail_row;
integer first_quant_fail_lane;
integer first_quant_fail_got;
integer first_quant_fail_expected;

initial begin
    clk = 1'b0;
    forever #(CYCLE / 2.0) clk = ~clk;
end

initial cycle_count = 0;
always @(posedge clk) cycle_count = cycle_count + 1;

function integer abs_int;
    input integer value;
    begin
        abs_int = (value < 0) ? -value : value;
    end
endfunction

task clear_ppu_input;
    begin
        ppu_valid = 1'b0;
        ppu_mac_result_vec = {16*24{1'b0}};
    end
endtask

task reset_dut;
    begin
        rst_n = 1'b0;
        clear_ppu_input;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end
endtask

task open_case_file;
    input  [256*8-1:0] primary_path;
    input  [256*8-1:0] fallback_path;
    output integer     fd;
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
                       "../../testbench/testcase/mac_ppu/pat0/mac_score_int24.txt",
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
                       "../../testbench/testcase/mac_ppu/pat0/base2_softmax_quant.txt",
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

task drive_ppu_row;
    input integer m_tile_idx;
    input integer n_tile_idx;
    input integer row_lane;
    integer lane_idx;
    integer global_row;
    integer global_col;
    integer score_val;
    begin
        global_row = (m_tile_idx * VL) + row_lane;
        ppu_mac_result_vec = {16*24{1'b0}};
        for (lane_idx = 0; lane_idx < AD; lane_idx = lane_idx + 1) begin
            global_col = (n_tile_idx * AD) + lane_idx;
            score_val = mac_score_file[global_row][global_col];
            ppu_mac_result_vec[lane_idx*24 +: 24] = score_val[23:0];
        end
    end
endtask

task check_no_ppu_output;
    input integer pass_idx;
    input integer m_tile_idx;
    input integer n_tile_idx;
    input integer row_lane;
    begin
        if (ppu_softmax_valid !== 1'b0) begin
            protocol_error_count = protocol_error_count + 1;
            $display("ERROR: unexpected softmax_valid pass=%0d m_tile=%0d n_tile=%0d row=%0d",
                     pass_idx, m_tile_idx, n_tile_idx, row_lane);
        end
    end
endtask

task check_ppu_output;
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
        if (ppu_softmax_valid !== 1'b1) begin
            protocol_error_count = protocol_error_count + 1;
            $display("ERROR: missing softmax_valid m_tile=%0d n_tile=%0d row=%0d",
                     m_tile_idx, n_tile_idx, row_lane);
        end
        if ((^ppu_softmax_result_vec) === 1'bx) begin
            protocol_error_count = protocol_error_count + 1;
            $display("ERROR: X detected in softmax_result_vec m_tile=%0d n_tile=%0d row=%0d",
                     m_tile_idx, n_tile_idx, row_lane);
        end

        global_row = (m_tile_idx * VL) + row_lane;
        for (lane_idx = 0; lane_idx < AD; lane_idx = lane_idx + 1) begin
            global_col = (n_tile_idx * AD) + lane_idx;
            got = ppu_softmax_result_vec[lane_idx*8 +: 8];
            expected = golden_quant_file[global_row][global_col];
            abs_diff = abs_int(got - expected);
            if (abs_diff > max_quant_abs_diff)
                max_quant_abs_diff = abs_diff;
            if (abs_diff != 0) begin
                quant_mismatch_count = quant_mismatch_count + 1;
                if (!first_quant_fail_seen) begin
                    first_quant_fail_seen        = 1;
                    first_quant_fail_m_tile      = m_tile_idx;
                    first_quant_fail_n_tile      = n_tile_idx;
                    first_quant_fail_row         = row_lane;
                    first_quant_fail_lane        = lane_idx;
                    first_quant_fail_got         = got;
                    first_quant_fail_expected    = expected;
                end
            end
            ppu_output_count = ppu_output_count + 1;
        end
    end
endtask

task run_ppu_tile;
    input integer pass_idx;
    input integer m_tile_idx;
    input integer n_tile_idx;
    integer row_lane;
    begin
        for (row_lane = 0; row_lane < VL; row_lane = row_lane + 1) begin
            @(negedge clk);
            drive_ppu_row(m_tile_idx, n_tile_idx, row_lane);
            ppu_valid = 1'b1;

            @(posedge clk);
            #1;
            check_no_ppu_output(pass_idx, m_tile_idx, n_tile_idx, row_lane);

            @(negedge clk);
            clear_ppu_input;

            @(posedge clk);
            #1;
            if (pass_idx == 0)
                check_no_ppu_output(pass_idx, m_tile_idx, n_tile_idx, row_lane);
            else
                check_ppu_output(m_tile_idx, n_tile_idx, row_lane);
        end
    end
endtask

task run_row_group;
    input integer m_tile_idx;
    integer pass_idx;
    integer n_tile_idx;
    begin
        $display("=== ROW GROUP %0d: global rows %0d..%0d ===",
                 m_tile_idx,
                 m_tile_idx * VL, (m_tile_idx * VL) + VL - 1);
        for (pass_idx = 0; pass_idx < 2; pass_idx = pass_idx + 1) begin
            if (pass_idx == 0)
                $display("  pass 0: feed all %0d N-tiles, expect no PPU output",
                         N_TILE_NUM);
            else
                $display("  pass 1: feed all %0d N-tiles, check quantized output",
                         N_TILE_NUM);
            for (n_tile_idx = 0; n_tile_idx < N_TILE_NUM; n_tile_idx = n_tile_idx + 1)
                run_ppu_tile(pass_idx, m_tile_idx, n_tile_idx);
        end
    end
endtask

integer m_tile_idx;

initial begin
    $display("=== PPU-only gate testbench ===");
    $display("M_TILE_LIMIT = %0d (out of %0d possible)", `M_TILE_LIMIT, M_TILE_NUM);

    ppu_output_count        = 0;
    protocol_error_count    = 0;
    quant_mismatch_count    = 0;
    max_quant_abs_diff      = 0;
    first_quant_fail_seen   = 0;

    clear_ppu_input;
    rst_n = 1'b0;

    $display("=== LOADING MAC -> PPU TESTCASE ===");
    read_mac_score_file;
    read_golden_quant_file;
    $display("Loaded mac_score_int24.txt and base2_softmax_quant.txt");

    reset_dut;

    for (m_tile_idx = 0; m_tile_idx < `M_TILE_LIMIT; m_tile_idx = m_tile_idx + 1)
        run_row_group(m_tile_idx);

    @(posedge clk);

    $display("=== PPU gate-sim summary ===");
    $display("  rows checked         : %0d", `M_TILE_LIMIT * VL);
    $display("  PPU outputs compared : %0d", ppu_output_count);
    $display("  protocol errors      : %0d", protocol_error_count);
    $display("  quant mismatches     : %0d", quant_mismatch_count);
    $display("  worst |got-expected| : %0d", max_quant_abs_diff);
    if (first_quant_fail_seen)
        $display("  first quant fail     : m_tile=%0d n_tile=%0d row=%0d lane=%0d got=%0d expected=%0d",
                 first_quant_fail_m_tile, first_quant_fail_n_tile,
                 first_quant_fail_row, first_quant_fail_lane,
                 first_quant_fail_got, first_quant_fail_expected);

    if ((protocol_error_count == 0) && (quant_mismatch_count == 0))
        $display("=== PASS ===");
    else
        $display("=== FAIL ===");

    $finish;
end

initial begin
    #(CYCLE * END_CYCLE);
    $display("ERROR: simulation timeout at %0t", $time);
    $finish;
end

`ifdef DUMP_VCD
initial begin
    $dumpfile("tb_PPU_gate.vcd");
    $dumpvars(0, tb_PPU_gate);
end
`endif

endmodule

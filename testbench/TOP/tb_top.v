`timescale 1ns/1ps
//
// Top-level integration testbench.
//
// Drives only the MAC operand interface of `top` (vecA, vecB, start,
// tile_done) using the same negedge-build / posedge-wait pattern as
// tb_MAC_PPU_hw_flow.v's run_mac_tile.  Top handles the MAC->PPU
// hand-off internally; bench just sinks softmax_valid pulses and
// compares them against base2_softmax_quant.txt.
//
// Stimulus from the existing mac_ppu testcase:
//   testbench/testcase/mac_ppu/pat0/query_int8.txt
//   testbench/testcase/mac_ppu/pat0/key_int8.txt
//   testbench/testcase/mac_ppu/pat0/base2_softmax_quant.txt
//
// One row group = 2 passes x 64 N-tiles = 128 MAC tiles fed to top.
// PPU manages path1/path2 mode internally; pass 0 produces no PPU
// output, pass 1 emits 16 valid pulses per tile = 16*64 = 1024 per
// row group.
//
// Workload defaults to 1 row group to keep gate-sim runtime sane.
// Override with `+define+M_TILE_LIMIT=N` for more.
//
// RTL sanity check (before gate sim):
//   iverilog -g2012 -I. -o tb_top.vvp \
//       RTL/MAC/MAC.v RTL/MAC/tile.v \
//       RTL/PPU/softmax_modules.v RTL/PPU/PPU_modules.v RTL/PPU/PPU.v \
//       RTL/TOP/top.v testbench/TOP/tb_top.v
//   vvp tb_top.vvp
//
// Gate sim driven by SYN/SYN_TOP/top_gls.f.

`ifndef M_TILE_LIMIT
  `define M_TILE_LIMIT 1
`endif

`ifndef CYCLE
  `define CYCLE 10.0
`endif

module tb_top;

parameter real    CYCLE       = `CYCLE;
parameter integer MAT_M       = 1024;
parameter integer MAT_K       = 64;
parameter integer MAT_N       = 1024;
parameter integer VL          = 16;
parameter integer VS          = 32;
parameter integer AD          = 16;
parameter integer M_TILE_NUM  = MAT_M / VL;
parameter integer K_TILE_NUM  = MAT_K / VS;
parameter integer N_TILE_NUM  = MAT_N / AD;
parameter integer END_CYCLE   = 5000000;
parameter integer INT8_MIN    = -128;
parameter integer INT8_MAX    = 127;
parameter integer CAPTURE_DEPTH = `M_TILE_LIMIT * VL * N_TILE_NUM;

reg                    clk;
reg                    rst_n;
reg [16*256-1:0]       vecA;
reg [255:0]            vecB;
reg                    start;
reg                    tile_done;

wire                   softmax_valid;
wire [16*8-1:0]        softmax_result_vec;
wire [23:0]            softmax_scale;

top dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .vecA              (vecA),
    .vecB              (vecB),
    .start             (start),
    .tile_done         (tile_done),
    .softmax_valid     (softmax_valid),
    .softmax_result_vec(softmax_result_vec),
    .softmax_scale     (softmax_scale)
);

initial begin
    clk = 1'b0;
    forever #(CYCLE / 2.0) clk = ~clk;
    $sdf_annotate("top_syn.sdf", dut);
end

integer cycle_count;
initial cycle_count = 0;
always @(posedge clk) cycle_count = cycle_count + 1;

// ------------------------------------------------------------------
// Testcase storage
// ------------------------------------------------------------------
integer query_mem         [0:MAT_M-1][0:MAT_K-1];
integer key_mem           [0:MAT_K-1][0:MAT_N-1];
integer golden_quant_file [0:MAT_M-1][0:MAT_N-1];

// ------------------------------------------------------------------
// PPU output capture
// ------------------------------------------------------------------
reg [16*8-1:0] captured_result [0:CAPTURE_DEPTH-1];
integer        capture_idx;

always @(posedge clk) begin
    if (rst_n && softmax_valid) begin
        if (capture_idx < CAPTURE_DEPTH) begin
            captured_result[capture_idx] = softmax_result_vec;
        end
        capture_idx = capture_idx + 1;
    end
end

// ------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------
function [7:0] int8_bits;
    input integer value;
    begin
        int8_bits = value[7:0];
    end
endfunction

function integer abs_int;
    input integer value;
    begin
        abs_int = (value < 0) ? -value : value;
    end
endfunction

task open_case_file;
    input  [256*8-1:0] primary;
    input  [256*8-1:0] fallback;
    output integer     fd;
    begin
        fd = $fopen(primary, "r");
        if (fd == 0)
            fd = $fopen(fallback, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open testcase file:");
            $display("  %0s", primary);
            $display("  %0s", fallback);
            $display("Generate with: python testbench/case_generator/generate_mac_ppu_cases.py");
            $finish;
        end
    end
endtask

task read_int_matrix;
    input  [256*8-1:0] primary_path;
    input  [256*8-1:0] fallback_path;
    input  integer     rows;
    input  integer     cols;
    input  integer     check_int8_range;
    output integer     loaded;  // dummy, just to keep task signature consistent
    integer fd, r, c, scan_count, value;
    begin
        open_case_file(primary_path, fallback_path, fd);
        loaded = 0;
        for (r = 0; r < rows; r = r + 1) begin
            for (c = 0; c < cols; c = c + 1) begin
                scan_count = $fscanf(fd, "%d", value);
                if (scan_count != 1) begin
                    $display("ERROR: file ended early at r=%0d c=%0d", r, c);
                    $finish;
                end
                if (check_int8_range && ((value < INT8_MIN) || (value > INT8_MAX))) begin
                    $display("ERROR: value out of int8 range at r=%0d c=%0d value=%0d",
                             r, c, value);
                    $finish;
                end
                // store into the right matrix based on dims (caller-side responsibility)
                // -- we can't do that here generically in plain Verilog, so this task
                // is just a placeholder; real loads done inline below.
            end
        end
        $fclose(fd);
    end
endtask

task load_testcase;
    integer fd, r, c, scan_count, value;
    begin
        $display("=== LOADING MAC -> PPU TESTCASE ===");

        // query_int8.txt: MAT_M x MAT_K
        open_case_file("testbench/testcase/mac_ppu/pat0/query_int8.txt",
                       "../../testbench/testcase/mac_ppu/pat0/query_int8.txt",
                       fd);
        for (r = 0; r < MAT_M; r = r + 1) begin
            for (c = 0; c < MAT_K; c = c + 1) begin
                scan_count = $fscanf(fd, "%d", value);
                if (scan_count != 1) begin
                    $display("ERROR: query_int8.txt ended early r=%0d c=%0d", r, c);
                    $finish;
                end
                query_mem[r][c] = value;
            end
        end
        $fclose(fd);

        // key_int8.txt: MAT_K x MAT_N
        open_case_file("testbench/testcase/mac_ppu/pat0/key_int8.txt",
                       "../../testbench/testcase/mac_ppu/pat0/key_int8.txt",
                       fd);
        for (r = 0; r < MAT_K; r = r + 1) begin
            for (c = 0; c < MAT_N; c = c + 1) begin
                scan_count = $fscanf(fd, "%d", value);
                if (scan_count != 1) begin
                    $display("ERROR: key_int8.txt ended early r=%0d c=%0d", r, c);
                    $finish;
                end
                key_mem[r][c] = value;
            end
        end
        $fclose(fd);

        // base2_softmax_quant.txt: MAT_M x MAT_N (int8 golden)
        open_case_file("testbench/testcase/mac_ppu/pat0/base2_softmax_quant.txt",
                       "../../testbench/testcase/mac_ppu/pat0/base2_softmax_quant.txt",
                       fd);
        for (r = 0; r < MAT_M; r = r + 1) begin
            for (c = 0; c < MAT_N; c = c + 1) begin
                scan_count = $fscanf(fd, "%d", value);
                if (scan_count != 1) begin
                    $display("ERROR: base2_softmax_quant.txt ended early r=%0d c=%0d", r, c);
                    $finish;
                end
                golden_quant_file[r][c] = value;
            end
        end
        $fclose(fd);

        $display("Loaded query_int8.txt, key_int8.txt, base2_softmax_quant.txt");
    end
endtask

// ------------------------------------------------------------------
// Build packed vecA / vecB for one (m_tile, n_tile, k_tile, col_lane).
// Same packing as tb_MAC_PPU_hw_flow.v's build_mac_operands but writes
// to the flat 4096-bit vecA bus that top.v exposes.
// ------------------------------------------------------------------
task build_mac_operands;
    input integer m_tile_idx;
    input integer n_tile_idx;
    input integer k_tile_idx;
    input integer col_lane;
    integer row_lane, k_lane, global_row, global_k, global_col;
    reg [16*256-1:0] vecA_packed;
    reg [255:0]      vecB_packed;
    begin
        global_col  = (n_tile_idx * AD) + col_lane;
        vecA_packed = {16*256{1'b0}};

        for (row_lane = 0; row_lane < VL; row_lane = row_lane + 1) begin
            global_row = (m_tile_idx * VL) + row_lane;
            for (k_lane = 0; k_lane < VS; k_lane = k_lane + 1) begin
                global_k = (k_tile_idx * VS) + k_lane;
                vecA_packed[row_lane*256 + k_lane*8 +: 8] =
                    int8_bits(query_mem[global_row][global_k]);
            end
        end

        vecB_packed = {VS*8{1'b0}};
        for (k_lane = 0; k_lane < VS; k_lane = k_lane + 1) begin
            global_k = (k_tile_idx * VS) + k_lane;
            vecB_packed[k_lane*8 +: 8] =
                int8_bits(key_mem[global_k][global_col]);
        end

        vecA = vecA_packed;
        vecB = vecB_packed;
    end
endtask

// ------------------------------------------------------------------
// Drive one MAC tile through `top`.  35 cycles between tile_done events
// (1 cycle for start-up + 17 cyc K=0 + 17 cyc K=1, then a tile_done
// pulse on the cycle after).
// ------------------------------------------------------------------
task drive_mac_tile;
    input integer m_tile_idx;
    input integer n_tile_idx;
    integer k_tile, col;
    begin
        @(negedge clk);
        start     = 1'b1;
        tile_done = 1'b0;

        for (k_tile = 0; k_tile < K_TILE_NUM; k_tile = k_tile + 1) begin
            // K-iter pre-fill (counter 0 -> 1 at this posedge, no write)
            build_mac_operands(m_tile_idx, n_tile_idx, k_tile, 0);
            @(posedge clk);
            #1;
            // 16 column streams (each posedge writes collector[*][col_lane])
            for (col = 0; col < AD; col = col + 1) begin
                @(negedge clk);
                build_mac_operands(m_tile_idx, n_tile_idx, k_tile, col);
                @(posedge clk);
                #1;
            end
        end

        // tile_done pulse: 1 cycle high.  Tile.v commits latch_array
        // at this posedge; top's row-feeder FSM picks it up next cycle.
        @(negedge clk);
        start     = 1'b0;
        tile_done = 1'b1;
        vecA      = {16*256{1'b0}};
        vecB      = {256{1'b0}};
        @(posedge clk);
        #1;
        tile_done = 1'b0;
    end
endtask

task reset_dut;
    begin
        rst_n     = 1'b0;
        start     = 1'b0;
        tile_done = 1'b0;
        vecA      = {16*256{1'b0}};
        vecB      = {256{1'b0}};
        capture_idx = 0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        // start stays 0; drive_mac_tile asserts it.
    end
endtask

// ------------------------------------------------------------------
// Check captured PPU outputs for one row group against golden.
// ------------------------------------------------------------------
task check_results;
    input integer m_tile_idx;
    integer pulse_idx, base_idx;
    integer n_tile, row_in_tile, lane;
    integer global_row, global_col;
    integer got, expected, abs_diff, max_diff;
    integer mismatches, pulses_per_group;
    integer first_fail_seen;
    integer first_fail_n_tile, first_fail_row, first_fail_lane;
    integer first_fail_got, first_fail_expected;
    begin
        pulses_per_group = VL * N_TILE_NUM;
        base_idx         = m_tile_idx * pulses_per_group;
        mismatches       = 0;
        first_fail_seen  = 0;
        max_diff         = 0;

        $display("--- Row group %0d results ---", m_tile_idx);
        $display("  expected pulses: %0d", pulses_per_group);
        $display("  pulses captured so far (total): %0d", capture_idx);

        if (capture_idx < base_idx + pulses_per_group) begin
            $display("ERROR: missing PPU output pulses (got %0d, need %0d)",
                     capture_idx, base_idx + pulses_per_group);
        end

        for (pulse_idx = 0; pulse_idx < pulses_per_group; pulse_idx = pulse_idx + 1) begin
            n_tile      = pulse_idx / VL;
            row_in_tile = pulse_idx % VL;
            global_row  = (m_tile_idx * VL) + row_in_tile;

            for (lane = 0; lane < AD; lane = lane + 1) begin
                global_col = (n_tile * AD) + lane;
                got      = captured_result[base_idx + pulse_idx][lane*8 +: 8];
                expected = golden_quant_file[global_row][global_col];
                abs_diff = abs_int(got - expected);
                if (abs_diff > max_diff) max_diff = abs_diff;
                if (got !== expected) begin
                    mismatches = mismatches + 1;
                    if (!first_fail_seen) begin
                        first_fail_seen     = 1;
                        first_fail_n_tile   = n_tile;
                        first_fail_row      = row_in_tile;
                        first_fail_lane     = lane;
                        first_fail_got      = got;
                        first_fail_expected = expected;
                    end
                end
            end
        end

        $display("  mismatches=%0d  worst |diff|=%0d", mismatches, max_diff);
        if (first_fail_seen)
            $display("  first mismatch: n_tile=%0d row=%0d lane=%0d got=%0d expected=%0d",
                     first_fail_n_tile, first_fail_row, first_fail_lane,
                     first_fail_got, first_fail_expected);
    end
endtask

// ------------------------------------------------------------------
// Main
// ------------------------------------------------------------------
integer m_tile_loop, pass_loop, n_tile_loop;
integer total_mismatches;

initial begin
    $display("=== TOP integration testbench (M_TILE_LIMIT=%0d) ===", `M_TILE_LIMIT);
    capture_idx = 0;
    total_mismatches = 0;

    load_testcase;
    reset_dut;

    for (m_tile_loop = 0; m_tile_loop < `M_TILE_LIMIT; m_tile_loop = m_tile_loop + 1) begin
        $display("=== ROW GROUP %0d/%0d (global rows %0d..%0d) ===",
                 m_tile_loop + 1, `M_TILE_LIMIT,
                 m_tile_loop * VL, (m_tile_loop * VL) + VL - 1);

        // 2 passes of 64 N-tiles each.  PPU toggles path1->path2 internally
        // after the 64th tile, so we just feed 128 tiles in order.
        for (pass_loop = 0; pass_loop < 2; pass_loop = pass_loop + 1) begin
            $display("  pass %0d (PPU path%0d)", pass_loop, pass_loop + 1);
            for (n_tile_loop = 0; n_tile_loop < N_TILE_NUM; n_tile_loop = n_tile_loop + 1) begin
                drive_mac_tile(m_tile_loop, n_tile_loop);
            end
        end

        // Drain: last PPU consume finishes ~34 cycles after final tile_done.
        repeat (40) @(posedge clk);
        check_results(m_tile_loop);
    end

    $display("=== DONE ===");
    $display("total pulses captured: %0d", capture_idx);
    $finish;
end

initial begin
    #(CYCLE * END_CYCLE);
    $display("TIMEOUT at %0t", $time);
    $finish;
end

`ifdef DUMP_VCD
initial begin
    $dumpfile("tb_top.vcd");
    $dumpvars(0, tb_top);
end
`endif

endmodule

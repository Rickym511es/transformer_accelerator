`timescale 1ns/1ps
//
// End-to-end MAC tile -> PPU hardware-flow test.
//
// This bench exercises Q(1024x64) * K^T(64x1024) with signed int8 data.
// The 1024 rows are processed as 64 groups of 16 rows.  For each row group,
// the MAC tile is run twice over all 64 output tiles:
//   pass 0 feeds PPU path1 to build row max/sum state
//   pass 1 feeds PPU path2 and checks quantized int8 output
//
// Generate testcase first:
//   python testbench/case_generator/generate_mac_ppu_cases.py
//
// Run example from the repo root:
//   iverilog -g2012 -I. -o tb_MAC_PPU_hw_flow.vvp \
//       RTL/MAC/MAC.v RTL/MAC/tile.v \
//       RTL/PPU/softmax_modules.v RTL/PPU/PPU_modules.v RTL/PPU/PPU.v \
//       testbench/tb_MAC_PPU_hw_flow.v
//   vvp tb_MAC_PPU_hw_flow.vvp

module tb_MAC_PPU_hw_flow;

parameter real CYCLE = 10.0;
parameter integer MAT_M = 1024;
parameter integer MAT_K = 64;
parameter integer MAT_N = 1024;
parameter integer VL = 16;
parameter integer VS = 32;
parameter integer AD = 16;
parameter integer M_TILE_NUM = MAT_M / VL;
parameter integer K_TILE_NUM = MAT_K / VS;
parameter integer N_TILE_NUM = MAT_N / AD;
parameter integer TOTAL_OUTPUTS = MAT_M * MAT_N;
parameter integer INT8_MIN = -128;
parameter integer INT8_MAX = 127;

// PPU.v converts a signed 24-bit MAC result to Q24.16 with <<< 13,
// so the real score seen by softmax is mac_result / 8.0.
// Query/key dequant scales are intentionally not applied here.
parameter real PPU_MAC_SCORE_DIVISOR = 8.0;

parameter integer MAC_USEFUL_CYCLES_PER_TILE = K_TILE_NUM * AD;
parameter integer PPU_CYCLES_PER_TILE = VL * 2;

// Current tile.v has a counter bubble before each 16-column K chunk and a
// separate tile_done commit cycle.  Keep this visible in the timing summary
// while still checking the intended 32 useful MAC feed cycles per tile.
parameter integer TILE_V_CURRENT_WALL_CYCLES = (K_TILE_NUM * (AD + 1)) + 1;

parameter integer QUANT_TOLERANCE = 0;
parameter integer FAIL_ON_QUANT_MISMATCH = 0;
parameter integer END_CYCLE = 2000000;

reg clk;
reg rst_n;

reg [255:0] mac_vecA [0:VL-1];
reg [255:0] mac_vecB;
reg mac_start;
reg mac_tile_done;
wire [23:0] mac_latch_array [0:VL-1][0:AD-1];

// tile.v is now pure Verilog-2001 with flat packed ports.
// Pack mac_vecA into one bus and unpack the flat latch_array back into
// the 2-D view the existing compare code uses.
wire [VL*256-1:0]    mac_vecA_flat;
wire [VL*AD*24-1:0]  mac_latch_array_flat;

genvar gva;
generate
    for (gva = 0; gva < VL; gva = gva + 1) begin : g_pack_mac_vecA
        assign mac_vecA_flat[gva*256 +: 256] = mac_vecA[gva];
    end
endgenerate

genvar gli, glj;
generate
    for (gli = 0; gli < VL; gli = gli + 1) begin : g_unpack_la_row
        for (glj = 0; glj < AD; glj = glj + 1) begin : g_unpack_la_col
            assign mac_latch_array[gli][glj] =
                mac_latch_array_flat[(gli*AD + glj)*24 +: 24];
        end
    end
endgenerate

reg ppu_valid;
reg signed [16*24-1:0] ppu_mac_result_vec;
wire ppu_softmax_valid;
wire [16*8-1:0] ppu_softmax_result_vec;
wire [23:0] ppu_softmax_scale;

integer mac_score [0:VL-1][0:MAT_N-1];
integer golden_quant [0:VL-1][0:MAT_N-1];
integer query_mem [0:MAT_M-1][0:MAT_K-1];
integer key_mem [0:MAT_K-1][0:MAT_N-1];
integer mac_score_file [0:MAT_M-1][0:MAT_N-1];
integer golden_quant_file [0:MAT_M-1][0:MAT_N-1];
integer global_row_mismatch [0:MAT_M-1];
integer global_row_max_diff [0:MAT_M-1];

integer cycle_count;
integer mac_tile_count;
integer ppu_tile_count;
integer ppu_output_count;
integer mac_feed_cycle_count;
integer mac_wall_cycle_count;
integer ppu_cycle_count;
integer protocol_error_count;
integer mac_error_count;
integer golden_file_mismatch_count;
integer quant_mismatch_count;
integer quant_fail_count;
integer max_quant_abs_diff;
integer first_golden_file_fail_seen;
integer first_golden_file_fail_row;
integer first_golden_file_fail_col;
integer first_golden_file_fail_got;
integer first_golden_file_fail_expected;
integer first_mac_fail_seen;
integer first_mac_fail_pass;
integer first_mac_fail_m_tile;
integer first_mac_fail_n_tile;
integer first_mac_fail_row;
integer first_mac_fail_lane;
integer first_mac_fail_got;
integer first_mac_fail_expected;
integer first_quant_fail_seen;
integer first_quant_fail_m_tile;
integer first_quant_fail_n_tile;
integer first_quant_fail_row;
integer first_quant_fail_lane;
integer first_quant_fail_got;
integer first_quant_fail_expected;
integer worst_quant_m_tile;
integer worst_quant_n_tile;
integer worst_quant_row;
integer worst_quant_lane;
integer worst_quant_got;
integer worst_quant_expected;
integer worst_quant_mac_score;

tile mac_dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .vecA       (mac_vecA_flat),
    .vecB       (mac_vecB),
    .tile_done  (mac_tile_done),
    .latch_array(mac_latch_array_flat),
    .start      (mac_start)
);

PPU ppu_dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .valid             (ppu_valid),
    .mac_result_vec    (ppu_mac_result_vec),
    .softmax_valid     (ppu_softmax_valid),
    .softmax_result_vec(ppu_softmax_result_vec),
    .softmax_scale     (ppu_softmax_scale)
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

function integer matrix_q;
    input integer row_idx;
    input integer k_idx;
    begin
        matrix_q = query_mem[row_idx][k_idx];
    end
endfunction

function integer matrix_k;
    input integer k_idx;
    input integer col_idx;
    begin
        matrix_k = key_mem[k_idx][col_idx];
    end
endfunction

function [7:0] int8_bits;
    input integer value;
    begin
        int8_bits = value[7:0];
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

function integer round_real_to_int;
    input real value;
    begin
        if (value >= 0.0)
            round_real_to_int = $rtoi(value + 0.5);
        else
            round_real_to_int = $rtoi(value - 0.5);
    end
endfunction

function integer clamp_quant;
    input integer value;
    begin
        if (value < 0)
            clamp_quant = 0;
        else if (value > 127)
            clamp_quant = 127;
        else
            clamp_quant = value;
    end
endfunction

function real mac_score_to_real;
    input integer value;
    begin
        mac_score_to_real = value / PPU_MAC_SCORE_DIVISOR;
    end
endfunction

function integer matmul_element;
    input integer row_idx;
    input integer col_idx;
    integer k_idx;
    integer acc;
    begin
        acc = 0;
        for (k_idx = 0; k_idx < MAT_K; k_idx = k_idx + 1) begin
            acc = acc + (matrix_q(row_idx, k_idx) * matrix_k(k_idx, col_idx));
        end
        matmul_element = acc;
    end
endfunction

task clear_mac_inputs;
    integer row_lane;
    begin
        for (row_lane = 0; row_lane < VL; row_lane = row_lane + 1) begin
            mac_vecA[row_lane] = {VS*8{1'b0}};
        end
        mac_vecB = {VS*8{1'b0}};
    end
endtask

task clear_ppu_input;
    begin
        ppu_valid = 1'b0;
        ppu_mac_result_vec = {16*24{1'b0}};
    end
endtask

task build_mac_operands;
    input integer m_tile_idx;
    input integer n_tile_idx;
    input integer k_tile_idx;
    input integer col_lane;
    integer row_lane;
    integer k_lane;
    integer global_row;
    integer global_k;
    integer global_col;
    begin
        global_col = (n_tile_idx * AD) + col_lane;
        for (row_lane = 0; row_lane < VL; row_lane = row_lane + 1) begin
            global_row = (m_tile_idx * VL) + row_lane;
            mac_vecA[row_lane] = {VS*8{1'b0}};
            for (k_lane = 0; k_lane < VS; k_lane = k_lane + 1) begin
                global_k = (k_tile_idx * VS) + k_lane;
                mac_vecA[row_lane][k_lane*8 +: 8] =
                    int8_bits(matrix_q(global_row, global_k));
            end
        end

        mac_vecB = {VS*8{1'b0}};
        for (k_lane = 0; k_lane < VS; k_lane = k_lane + 1) begin
            global_k = (k_tile_idx * VS) + k_lane;
            mac_vecB[k_lane*8 +: 8] =
                int8_bits(matrix_k(global_k, global_col));
        end
    end
endtask

task reset_duts;
    begin
        rst_n = 1'b0;
        mac_start = 1'b0;
        mac_tile_done = 1'b0;
        clear_mac_inputs;
        clear_ppu_input;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
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

task read_query_file;
    integer fd;
    integer row_idx;
    integer k_idx;
    integer scan_count;
    integer value;
    begin
        open_case_file("testbench/testcase/mac_ppu/pat0/query_int8.txt",
                       "testcase/mac_ppu/pat0/query_int8.txt",
                       fd);
        for (row_idx = 0; row_idx < MAT_M; row_idx = row_idx + 1) begin
            for (k_idx = 0; k_idx < MAT_K; k_idx = k_idx + 1) begin
                scan_count = $fscanf(fd, "%d", value);
                if (scan_count != 1) begin
                    $display("ERROR: query_int8.txt ended early at row=%0d k=%0d",
                             row_idx, k_idx);
                    $finish;
                end
                if ((value < INT8_MIN) || (value > INT8_MAX)) begin
                    $display("ERROR: query value out of int8 range row=%0d k=%0d value=%0d",
                             row_idx, k_idx, value);
                    $finish;
                end
                query_mem[row_idx][k_idx] = value;
            end
        end
        $fclose(fd);
    end
endtask

task read_key_file;
    integer fd;
    integer k_idx;
    integer col_idx;
    integer scan_count;
    integer value;
    begin
        open_case_file("testbench/testcase/mac_ppu/pat0/key_int8.txt",
                       "testcase/mac_ppu/pat0/key_int8.txt",
                       fd);
        for (k_idx = 0; k_idx < MAT_K; k_idx = k_idx + 1) begin
            for (col_idx = 0; col_idx < MAT_N; col_idx = col_idx + 1) begin
                scan_count = $fscanf(fd, "%d", value);
                if (scan_count != 1) begin
                    $display("ERROR: key_int8.txt ended early at k=%0d col=%0d",
                             k_idx, col_idx);
                    $finish;
                end
                if ((value < INT8_MIN) || (value > INT8_MAX)) begin
                    $display("ERROR: key value out of int8 range k=%0d col=%0d value=%0d",
                             k_idx, col_idx, value);
                    $finish;
                end
                key_mem[k_idx][col_idx] = value;
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
                if ((value < 0) || (value > 127)) begin
                    $display("ERROR: golden quant out of uint7 range row=%0d col=%0d value=%0d",
                             row_idx, col_idx, value);
                    $finish;
                end
                golden_quant_file[row_idx][col_idx] = value;
            end
        end
        $fclose(fd);
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

task load_testcase;
    begin
        $display("=== LOADING MAC -> PPU TESTCASE ===");
        $display("Path: testbench/testcase/mac_ppu/pat0");
        read_query_file;
        read_key_file;
        read_mac_score_file;
        read_golden_quant_file;
        $display("Loaded query_int8.txt, key_int8.txt, mac_score_int24.txt, base2_softmax_quant.txt");
    end
endtask

task init_scoreboards;
    integer row_idx;
    begin
        mac_tile_count = 0;
        ppu_tile_count = 0;
        ppu_output_count = 0;
        mac_feed_cycle_count = 0;
        mac_wall_cycle_count = 0;
        ppu_cycle_count = 0;
        protocol_error_count = 0;
        mac_error_count = 0;
        golden_file_mismatch_count = 0;
        quant_mismatch_count = 0;
        quant_fail_count = 0;
        max_quant_abs_diff = 0;
        first_golden_file_fail_seen = 0;
        first_mac_fail_seen = 0;
        first_quant_fail_seen = 0;
        worst_quant_m_tile = 0;
        worst_quant_n_tile = 0;
        worst_quant_row = 0;
        worst_quant_lane = 0;
        worst_quant_got = 0;
        worst_quant_expected = 0;
        worst_quant_mac_score = 0;

        for (row_idx = 0; row_idx < MAT_M; row_idx = row_idx + 1) begin
            global_row_mismatch[row_idx] = 0;
            global_row_max_diff[row_idx] = 0;
        end
    end
endtask

task build_group_golden;
    input integer m_tile_idx;
    integer row_lane;
    integer global_row;
    integer col_idx;
    integer quant_value;
    real row_max;
    real exp_sum;
    real exp_value;
    real probability;
    real max_probability;
    real score_value;
    begin
        for (row_lane = 0; row_lane < VL; row_lane = row_lane + 1) begin
            global_row = (m_tile_idx * VL) + row_lane;
            row_max = -1.0e30;

            for (col_idx = 0; col_idx < MAT_N; col_idx = col_idx + 1) begin
                mac_score[row_lane][col_idx] = mac_score_file[global_row][col_idx];
                score_value = mac_score_to_real(mac_score[row_lane][col_idx]);
                if (score_value > row_max)
                    row_max = score_value;
            end

            exp_sum = 0.0;
            for (col_idx = 0; col_idx < MAT_N; col_idx = col_idx + 1) begin
                score_value = mac_score_to_real(mac_score[row_lane][col_idx]);
                exp_sum = exp_sum + (2.0 ** (score_value - row_max));
            end

            max_probability = 1.0 / exp_sum;
            for (col_idx = 0; col_idx < MAT_N; col_idx = col_idx + 1) begin
                score_value = mac_score_to_real(mac_score[row_lane][col_idx]);
                exp_value = 2.0 ** (score_value - row_max);
                probability = exp_value / exp_sum;
                quant_value = round_real_to_int((probability / max_probability) * 127.0);
                golden_quant[row_lane][col_idx] = clamp_quant(quant_value);

                if (golden_quant[row_lane][col_idx] !==
                    golden_quant_file[global_row][col_idx]) begin
                    golden_file_mismatch_count = golden_file_mismatch_count + 1;
                    if (!first_golden_file_fail_seen) begin
                        first_golden_file_fail_seen = 1;
                        first_golden_file_fail_row = global_row;
                        first_golden_file_fail_col = col_idx;
                        first_golden_file_fail_got =
                            golden_quant_file[global_row][col_idx];
                        first_golden_file_fail_expected =
                            golden_quant[row_lane][col_idx];
                    end
                end
            end
        end
    end
endtask

task check_mac_tile;
    input integer pass_idx;
    input integer m_tile_idx;
    input integer n_tile_idx;
    integer row_lane;
    integer col_lane;
    integer global_col;
    integer got;
    integer expected;
    begin
        for (row_lane = 0; row_lane < VL; row_lane = row_lane + 1) begin
            for (col_lane = 0; col_lane < AD; col_lane = col_lane + 1) begin
                global_col = (n_tile_idx * AD) + col_lane;
                got = $signed(mac_latch_array[row_lane][col_lane]);
                expected = mac_score[row_lane][global_col];
                if (got !== expected) begin
                    mac_error_count = mac_error_count + 1;
                    if (!first_mac_fail_seen) begin
                        first_mac_fail_seen = 1;
                        first_mac_fail_pass = pass_idx;
                        first_mac_fail_m_tile = m_tile_idx;
                        first_mac_fail_n_tile = n_tile_idx;
                        first_mac_fail_row = row_lane;
                        first_mac_fail_lane = col_lane;
                        first_mac_fail_got = got;
                        first_mac_fail_expected = expected;
                    end
                end
            end
        end
    end
endtask

task run_mac_tile;
    input integer pass_idx;
    input integer m_tile_idx;
    input integer n_tile_idx;
    integer k_tile_idx;
    integer col_lane;
    integer start_cycle;
    integer wall_cycles;
    begin
        // Align start with operand setup.  If start is asserted before this
        // negedge, tile.v can see an extra posedge with stale inputs and shift
        // the first tile's columns by one.
        @(negedge clk);
        start_cycle = cycle_count;
        mac_start = 1'b1;
        mac_tile_done = 1'b0;

        for (k_tile_idx = 0; k_tile_idx < K_TILE_NUM; k_tile_idx = k_tile_idx + 1) begin
            build_mac_operands(m_tile_idx, n_tile_idx, k_tile_idx, 0);
            @(posedge clk);
            #1;

            for (col_lane = 0; col_lane < AD; col_lane = col_lane + 1) begin
                @(negedge clk);
                build_mac_operands(m_tile_idx, n_tile_idx, k_tile_idx, col_lane);
                @(posedge clk);
                #1;
                mac_feed_cycle_count = mac_feed_cycle_count + 1;
            end
        end

        @(negedge clk);
        mac_start = 1'b0;
        mac_tile_done = 1'b1;
        clear_mac_inputs;
        @(posedge clk);
        #1;
        mac_tile_done = 1'b0;

        wall_cycles = cycle_count - start_cycle;
        mac_wall_cycle_count = mac_wall_cycle_count + wall_cycles;
        mac_tile_count = mac_tile_count + 1;

        if (wall_cycles != TILE_V_CURRENT_WALL_CYCLES) begin
            protocol_error_count = protocol_error_count + 1;
            $display("ERROR: tile.v wall cycles pass=%0d m_tile=%0d n_tile=%0d got=%0d expected_current_tile_v=%0d",
                     pass_idx, m_tile_idx, n_tile_idx, wall_cycles,
                     TILE_V_CURRENT_WALL_CYCLES);
        end

        check_mac_tile(pass_idx, m_tile_idx, n_tile_idx);
    end
endtask

task drive_ppu_row_from_latch;
    input integer row_lane;
    integer lane_idx;
    begin
        ppu_mac_result_vec = {16*24{1'b0}};
        for (lane_idx = 0; lane_idx < AD; lane_idx = lane_idx + 1) begin
            ppu_mac_result_vec[lane_idx*24 +: 24] =
                mac_latch_array[row_lane][lane_idx];
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
            expected = golden_quant[row_lane][global_col];
            abs_diff = abs_int(got - expected);

            if (abs_diff > max_quant_abs_diff) begin
                max_quant_abs_diff = abs_diff;
                worst_quant_m_tile = m_tile_idx;
                worst_quant_n_tile = n_tile_idx;
                worst_quant_row = row_lane;
                worst_quant_lane = lane_idx;
                worst_quant_got = got;
                worst_quant_expected = expected;
                worst_quant_mac_score = mac_score[row_lane][global_col];
            end

            if (abs_diff > global_row_max_diff[global_row])
                global_row_max_diff[global_row] = abs_diff;

            if (abs_diff > QUANT_TOLERANCE) begin
                quant_mismatch_count = quant_mismatch_count + 1;
                global_row_mismatch[global_row] =
                    global_row_mismatch[global_row] + 1;
                if (!first_quant_fail_seen) begin
                    first_quant_fail_seen = 1;
                    first_quant_fail_m_tile = m_tile_idx;
                    first_quant_fail_n_tile = n_tile_idx;
                    first_quant_fail_row = row_lane;
                    first_quant_fail_lane = lane_idx;
                    first_quant_fail_got = got;
                    first_quant_fail_expected = expected;
                end
                if (FAIL_ON_QUANT_MISMATCH)
                    quant_fail_count = quant_fail_count + 1;
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
    integer start_cycle;
    integer elapsed_cycles;
    begin
        start_cycle = cycle_count;

        for (row_lane = 0; row_lane < VL; row_lane = row_lane + 1) begin
            @(negedge clk);
            drive_ppu_row_from_latch(row_lane);
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
        $display("=== ROW GROUP %0d/%0d START: global rows %0d..%0d ===",
                 m_tile_idx + 1, M_TILE_NUM,
                 m_tile_idx * VL, (m_tile_idx * VL) + VL - 1);

        build_group_golden(m_tile_idx);

        for (pass_idx = 0; pass_idx < 2; pass_idx = pass_idx + 1) begin
            if (pass_idx == 0)
                $display("  pass %0d: MAC recomputes 64 tiles, PPU builds max/sum",
                         pass_idx);
            else
                $display("  pass %0d: MAC recomputes 64 tiles, PPU outputs quant",
                         pass_idx);

            for (n_tile_idx = 0; n_tile_idx < N_TILE_NUM; n_tile_idx = n_tile_idx + 1) begin
                run_mac_tile(pass_idx, m_tile_idx, n_tile_idx);
                run_ppu_tile(pass_idx, m_tile_idx, n_tile_idx);
            end

            if ((pass_idx == 0) && (ppu_dut.path2_mode !== 1'b1)) begin
                protocol_error_count = protocol_error_count + 1;
                $display("ERROR: PPU did not enter path2 after row group %0d pass 0",
                         m_tile_idx);
            end
        end

        if (ppu_dut.path2_mode !== 1'b0) begin
            protocol_error_count = protocol_error_count + 1;
            $display("ERROR: PPU did not leave path2 after row group %0d pass 1",
                     m_tile_idx);
        end

        @(negedge clk);
        clear_ppu_input;
        mac_start = 1'b0;
        mac_tile_done = 1'b0;
        clear_mac_inputs;

        $display("=== ROW GROUP %0d DONE ===", m_tile_idx + 1);
    end
endtask

task print_summary;
    integer row_idx;
    integer printed_rows;
    integer total_errors;
    begin
        total_errors = protocol_error_count + mac_error_count +
                       golden_file_mismatch_count + quant_fail_count;

        $display("============================================================");
        $display("MAC -> PPU HARDWARE FLOW SUMMARY");
        $display("Matrix: Q(%0dx%0d) * K^T(%0dx%0d), signed int8 deterministic data",
                 MAT_M, MAT_K, MAT_K, MAT_N);
        $display("Groups: %0d groups x 16 rows, each group MAC-computed twice", M_TILE_NUM);
        $display("MAC golden: Python mac_score_int24.txt");
        $display("Quant side report: ideal base-2 softmax, no external query/key scale; PPU MAC score = C / %0.1f",
                 PPU_MAC_SCORE_DIVISOR);
        $display("Quant : q = round((softmax / row_max_softmax) * 127)");
        $display("");
        $display("Timing:");
        $display("  MAC useful feed cycles/tile=%0d, observed useful feed cycles=%0d over %0d tiles",
                 MAC_USEFUL_CYCLES_PER_TILE, mac_feed_cycle_count, mac_tile_count);
        $display("  tile.v current wall cycles/tile=%0d, observed wall cycles=%0d",
                 TILE_V_CURRENT_WALL_CYCLES,
                 (mac_tile_count == 0) ? 0 : (mac_wall_cycle_count / mac_tile_count));
        $display("  PPU cycles/tile=%0d, observed cycles=%0d over %0d tiles",
                 PPU_CYCLES_PER_TILE,
                 (ppu_tile_count == 0) ? 0 : (ppu_cycle_count / ppu_tile_count),
                 ppu_tile_count);
        $display("");
        $display("Checks:");
        $display("  protocol_errors=%0d", protocol_error_count);
        $display("  mac_exact_errors=%0d", mac_error_count);
        $display("  golden_file_mismatches=%0d", golden_file_mismatch_count);
        $display("  ppu_outputs=%0d expected=%0d", ppu_output_count, TOTAL_OUTPUTS);
        $display("  quant_mismatch_count=%0d tolerance=%0d fail_on_mismatch=%0d",
                 quant_mismatch_count, QUANT_TOLERANCE, FAIL_ON_QUANT_MISMATCH);
        $display("  quant_max_abs_diff=%0d at m_tile=%0d n_tile=%0d row_lane=%0d lane=%0d mac_score=%0d got=%0d expected=%0d",
                 max_quant_abs_diff, worst_quant_m_tile, worst_quant_n_tile,
                 worst_quant_row, worst_quant_lane, worst_quant_mac_score,
                 worst_quant_got, worst_quant_expected);

        if (first_mac_fail_seen) begin
            $display("  first MAC mismatch: pass=%0d m_tile=%0d n_tile=%0d row=%0d lane=%0d got=%0d expected=%0d",
                     first_mac_fail_pass, first_mac_fail_m_tile,
                     first_mac_fail_n_tile, first_mac_fail_row,
                     first_mac_fail_lane, first_mac_fail_got,
                     first_mac_fail_expected);
        end

        if (first_golden_file_fail_seen) begin
            $display("  first golden file mismatch: row=%0d col=%0d file=%0d tb_base2=%0d",
                     first_golden_file_fail_row, first_golden_file_fail_col,
                     first_golden_file_fail_got,
                     first_golden_file_fail_expected);
        end

        if (first_quant_fail_seen) begin
            $display("  first quant diff: m_tile=%0d n_tile=%0d row=%0d lane=%0d got=%0d expected=%0d",
                     first_quant_fail_m_tile, first_quant_fail_n_tile,
                     first_quant_fail_row, first_quant_fail_lane,
                     first_quant_fail_got, first_quant_fail_expected);
        end

        $display("");
        $display("Rows with quant diffs (first 16 nonzero rows):");
        printed_rows = 0;
        for (row_idx = 0; row_idx < MAT_M; row_idx = row_idx + 1) begin
            if ((global_row_mismatch[row_idx] != 0) && (printed_rows < 16)) begin
                $display("  row=%0d mismatches=%0d max_abs_diff=%0d",
                         row_idx, global_row_mismatch[row_idx],
                         global_row_max_diff[row_idx]);
                printed_rows = printed_rows + 1;
            end
        end
        if (printed_rows == 0)
            $display("  none");

        if ((total_errors == 0) && (ppu_output_count == TOTAL_OUTPUTS))
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL total_errors=%0d outputs=%0d expected=%0d",
                     total_errors, ppu_output_count, TOTAL_OUTPUTS);
        $display("============================================================");
    end
endtask

integer m_tile_idx;

initial begin
    init_scoreboards;
    rst_n = 1'b0;
    mac_start = 1'b0;
    mac_tile_done = 1'b0;
    ppu_valid = 1'b0;
    ppu_mac_result_vec = {16*24{1'b0}};
    clear_mac_inputs;

    $display("=== MAC -> PPU MATMUL SOFTMAX TEST START ===");
    $display("Testcase path: testbench/testcase/mac_ppu/pat0");
    $display("FAIL_ON_QUANT_MISMATCH=%0d, QUANT_TOLERANCE=%0d",
             FAIL_ON_QUANT_MISMATCH, QUANT_TOLERANCE);

    load_testcase;

    reset_duts;

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

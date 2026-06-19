`timescale 1ns/10ps
//
// MAC (tile) gate-level testbench.
//
// Same load logic and compare flow as testbench/MAC/modules/tb_MAC.v.
// Only difference: the post-synthesis netlist has `tile`'s unpacked-array
// ports flattened to packed buses, so this bench connects through flat
// buses and packs/unpacks at the boundary.
//
//   vecA:        unpacked [255:0] [0:15]   -> flat [4095:0]
//   latch_array: unpacked [23:0]  [0:15][0:15] -> flat [6143:0]
//
// RTL sanity check (before gate sim):
//   iverilog -g2012 -I. -o tb_MAC_gate.vvp \
//       RTL/MAC/MAC.v RTL/MAC/tile.v testbench/MAC/gate/tb_MAC_gate.v
//   vvp tb_MAC_gate.vvp
//
// Gate sim is driven by GLS/MAC/gate.f.

`define CYCLE       10.0
`define PAT_NUM     1
`define End_CYCLE   1000000
`define MAT_M       1024
`define MAT_K       64
`define MAT_N       1024
`define VL          16
`define VS          32
`define AD          16
`define M_TILE_NUM  (`MAT_M/`VL)
`define K_TILE_NUM  (`MAT_K/`VS)
`define N_TILE_NUM  (`MAT_N/`AD)

module testbench;
reg clk;
reg rst_n;

reg [255:0] Amem [0:15];
reg [255:0] Bmem [0:15];
reg [255:0] vecB;
reg tile_done;
reg start;

// Flat ports to the gate-level netlist (synthesis flattened the unpacked arrays).
wire [16*256-1:0] vecA_flat;          // 4096 bits
wire [16*16*24-1:0] latch_array_flat; // 6144 bits

// Pack the unpacked Amem [0:15] into one 4096-bit bus.
genvar gi;
generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : g_pack_vecA
        assign vecA_flat[gi*256 +: 256] = Amem[gi];
    end
endgenerate

tile uut (
    .clk        (clk),
    .rst_n      (rst_n),
    .vecA       (vecA_flat),
    .vecB       (vecB),
    .tile_done  (tile_done),
    .latch_array(latch_array_flat),
    .start      (start)
);

// Unpack latch_array_flat into a 2D array for the existing compare loop.
// Layout follows tile.v: latch_array[row][col], 24 bits per element,
// flattened in row-major order: bit index = (row*16 + col)*24.
reg [23:0] latch_array [0:15][0:15];
integer ui, uj;
always @(*) begin
    for (ui = 0; ui < 16; ui = ui + 1) begin
        for (uj = 0; uj < 16; uj = uj + 1) begin
            latch_array[ui][uj] =
                latch_array_flat[(ui*16 + uj)*24 +: 24];
        end
    end
end

initial clk = 0;
always #(`CYCLE/2) clk = ~clk;

integer cycle_count;
initial begin
   cycle_count = 0;
   @(negedge clk);
   while (1) begin
      cycle_count = cycle_count + 1;
      @(negedge clk);
   end
end

reg [23:0] golden [0:15][0:15];
integer i, j;
integer p;
localparam integer A_TILE_WORDS = `M_TILE_NUM * `K_TILE_NUM * `VL;
localparam integer B_TILE_WORDS = `N_TILE_NUM * `K_TILE_NUM * `AD;
localparam integer G_TILE_WORDS = `M_TILE_NUM * `N_TILE_NUM * `VL * `AD;
reg [255:0] A_tiles [0:A_TILE_WORDS-1];
reg [255:0] B_streams [0:B_TILE_WORDS-1];
reg [23:0]  G_tiles [0:G_TILE_WORDS-1];

integer err;
integer pass;
integer ERR;
integer first_fail_seen;
integer first_fail_pat;
integer first_fail_m_tile;
integer first_fail_n_tile;
integer first_fail_lane;
integer first_fail_col;
reg signed [23:0] first_fail_got;
reg signed [23:0] first_fail_golden;
reg [256*8-1:0] pathA;
reg [256*8-1:0] pathB;
reg [256*8-1:0] pathG;
reg [256*8-1:0] path_primary;
reg [256*8-1:0] path_fallback;
integer a_base;
integer b_base;
integer g_base;

task find_case_file;
    input  [256*8-1:0] primary;
    input  [256*8-1:0] fallback;
    output [256*8-1:0] selected;
    integer open_fd;
    begin
        selected = primary;
        open_fd = $fopen(primary, "r");
        if (open_fd == 0) begin
            selected = fallback;
            open_fd = $fopen(fallback, "r");
        end
        if (open_fd == 0) begin
            $display("ERROR: cannot open testcase file:");
            $display("  %0s", primary);
            $display("  %0s", fallback);
            $finish;
        end
        $fclose(open_fd);
    end
endtask

task load_pattern_files;
    input integer pat_idx;
    begin
        $sformat(path_primary, "testbench/testcase/mac/pat%0d/vecA_tiles.txt", pat_idx);
        $sformat(path_fallback, "testcase/mac/pat%0d/vecA_tiles.txt", pat_idx);
        find_case_file(path_primary, path_fallback, pathA);
        $readmemb(pathA, A_tiles);

        $sformat(path_primary, "testbench/testcase/mac/pat%0d/vecB_streams.txt", pat_idx);
        $sformat(path_fallback, "testcase/mac/pat%0d/vecB_streams.txt", pat_idx);
        find_case_file(path_primary, path_fallback, pathB);
        $readmemb(pathB, B_streams);

        $sformat(path_primary, "testbench/testcase/mac/pat%0d/C_golden_tiles.txt", pat_idx);
        $sformat(path_fallback, "testcase/mac/pat%0d/C_golden_tiles.txt", pat_idx);
        find_case_file(path_primary, path_fallback, pathG);
        $readmemb(pathG, G_tiles);
    end
endtask

initial begin
    $fsdbDumpfile("tile_gate.fsdb");
    $fsdbDumpvars;
    $fsdbDumpMDA;
end

integer step2;
integer step3;
integer step4;

initial begin
    err = 0;
    pass = 0;
    first_fail_seen = 0;

    vecB      = 0;
    tile_done = 0;
    rst_n     = 0;
    start     = 0;

    for (p = 0; p < `PAT_NUM; p = p + 1) begin
        $display("================================");
        $display("Start pat %0d", p);
        load_pattern_files(p);

        rst_n = 0;
        @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        start = 1;

        for (step4 = 1 ; step4 <= `M_TILE_NUM; step4 = step4 + 1) begin
            for (step3 = 1; step3 <= `N_TILE_NUM; step3 = step3 + 1) begin

                rst_n = 0;
                @(posedge clk);
                rst_n = 1;
                start = 1;

                g_base = (((step4 - 1) * `N_TILE_NUM) + (step3 - 1)) * `VL * `AD;
                for (i = 0; i < 16; i = i + 1) begin
                    for (j = 0; j < 16; j = j + 1) begin
                        golden[i][j] = G_tiles[g_base + (i * `AD) + j];
                    end
                end

                for (step2 = 1; step2 <= `K_TILE_NUM; step2 = step2 + 1) begin
                    a_base = (((step4 - 1) * `K_TILE_NUM) + (step2 - 1)) * `VL;
                    b_base = (((step3 - 1) * `K_TILE_NUM) + (step2 - 1)) * `AD;
                    for (i = 0; i < 16; i = i + 1) begin
                        Amem[i] = A_tiles[a_base + i];
                        Bmem[i] = B_streams[b_base + i];
                    end

                    for (i = 0; i < 16; i = i + 1) begin
                        vecB <= Bmem[i];
                        @(posedge clk);
                    end
                    @(posedge clk);
                end
                start <= 0;
                tile_done <= 1'b1;
                @(posedge clk);
                tile_done <= 1'b0;
                @(posedge clk);

                // ---------- compare ----------
                ERR = 0;
                for (i = 0; i < 16; i = i + 1) begin
                    for (j = 0; j < 16; j = j + 1) begin
                        if ($signed(latch_array[i][j]) !== golden[i][j]) begin
                            ERR = 1;
                            if (!first_fail_seen) begin
                                first_fail_seen = 1;
                                first_fail_pat = p;
                                first_fail_m_tile = step4;
                                first_fail_n_tile = step3;
                                first_fail_lane = i;
                                first_fail_col = j;
                                first_fail_got = latch_array[i][j];
                                first_fail_golden = golden[i][j];
                            end
                        end
                    end
                end
                if (ERR == 0) pass = pass + 1;
                else          err  = err  + 1;
            end
        end
    end

    if (err == 0) begin
        $display("Congratulations! All data have been generated successfully!\n");
        $display("Pass:   %0d \n", pass);
        $display("Error:  %0d \n", err);
        $display("Total cost time: %10.2f ns", cycle_count*(`CYCLE));
        $display("-------------------------PASS------------------------\n");
    end
    else begin
        $display("Final Simulation Result as below: \n");
        $display("-----------------------------------------------------\n");
        $display("Pass:   %0d \n", pass);
        $display("Error:  %0d \n", err);
        if (first_fail_seen) begin
            $display("First mismatch: pat=%0d tile=%0d-%0d lane=%0d col=%0d got=%0d golden=%0d",
                     first_fail_pat, first_fail_m_tile, first_fail_n_tile,
                     first_fail_lane, first_fail_col,
                     first_fail_got, first_fail_golden);
        end
        $display("-----------------------------------------------------\n");
    end

    $finish;
end

initial begin
    #(`End_CYCLE*(`CYCLE));
    $display("-----------------------------------------------------\n");
    $display("Error!!! There is something wrong with your code ...!\n");
    $display("------The test result is .....FAIL ------------------\n");
    $display("-----------------------------------------------------\n");
    $finish;
end

endmodule

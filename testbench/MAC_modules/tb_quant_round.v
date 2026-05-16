`timescale 1ns/10ps

module tb_quant_round;

// ─── DUT parameters ───────────────────────────────────────────────────────────
localparam ROWS  = 1024;
localparam COLS  = 64;
localparam IN_W  = 16;
localparam OUT_W = 8;

// ─── Clock / reset ────────────────────────────────────────────────────────────
reg clk, rst_n;
initial clk = 0;
always #5 clk = ~clk;   // 100 MHz

// ─── DUT ports ────────────────────────────────────────────────────────────────
reg                    start;
reg                    valid_in;
reg  signed [IN_W-1:0] data_in  [0:COLS-1];

wire [IN_W-1:0]         scale;
wire                    scale_valid;
wire                    valid_out;
wire signed [OUT_W-1:0] quant_out [0:COLS-1];

quant_round #(
    .ROWS (ROWS),
    .COLS (COLS),
    .IN_W (IN_W),
    .OUT_W(OUT_W)
) dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .start      (start),
    .valid_in   (valid_in),
    .data_in    (data_in),
    .scale      (scale),
    .scale_valid(scale_valid),
    .valid_out  (valid_out),
    .quant_out  (quant_out)
);

// ─── Reference model ──────────────────────────────────────────────────────────
integer r, c;
reg signed [IN_W-1:0]  ref_data   [0:ROWS-1][0:COLS-1];
reg        [IN_W-1:0]  ref_max;
reg        [IN_W-1:0]  ref_scale;
reg signed [OUT_W-1:0] ref_quant  [0:ROWS-1][0:COLS-1];

task compute_reference;
    integer rr, cc;
    reg [IN_W-1:0]  absv;
    reg signed [IN_W:0] dv;
    begin
        // find global absolute max
        ref_max = 0;
        for (rr = 0; rr < ROWS; rr = rr+1)
            for (cc = 0; cc < COLS; cc = cc+1) begin
                absv = ref_data[rr][cc][IN_W-1]
                     ? (~ref_data[rr][cc] + 1'b1)
                     : ref_data[rr][cc];
                if (absv > ref_max) ref_max = absv;
            end

        ref_scale = ref_max >> 7;

        // quantize
        for (rr = 0; rr < ROWS; rr = rr+1)
            for (cc = 0; cc < COLS; cc = cc+1) begin
                if (ref_scale == 0)
                    dv = {{1{ref_data[rr][cc][IN_W-1]}}, ref_data[rr][cc]};
                else
                    dv = {{1{ref_data[rr][cc][IN_W-1]}}, ref_data[rr][cc]}
                       / $signed({1'b0, ref_scale});
                if (dv > 17'sd127)       ref_quant[rr][cc] =  8'h7F;
                else if (dv < -17'sd128) ref_quant[rr][cc] =  8'h80;
                else                     ref_quant[rr][cc] =  dv[OUT_W-1:0];
            end
    end
endtask

// ─── Test stimulus ────────────────────────────────────────────────────────────
integer seed;
integer errors;
integer row_out;

initial begin
    rst_n    = 0;
    start    = 0;
    valid_in = 0;
    errors   = 0;
    seed     = 42;
    for (c = 0; c < COLS; c = c+1) data_in[c] = 0;

    @(posedge clk); #1;
    @(posedge clk); #1;
    rst_n = 1;
    @(posedge clk); #1;

    // ── Test 1: pseudo-random data ────────────────────────────────────────
    $display("[TB] Test 1: pseudo-random int16 data");

    // fill reference array
    for (r = 0; r < ROWS; r = r+1)
        for (c = 0; c < COLS; c = c+1) begin
            seed = seed * 1664525 + 1013904223;
            ref_data[r][c] = $signed(seed[15:0]);
        end
    compute_reference;
    $display("[TB] ref_scale = %0d  (ref_max = %0d)", ref_scale, ref_max);

    // assert start
    start    = 1;
    @(posedge clk); #1;
    start    = 0;

    // feed ROWS rows
    valid_in = 1;
    for (r = 0; r < ROWS; r = r+1) begin
        for (c = 0; c < COLS; c = c+1)
            data_in[c] = ref_data[r][c];
        @(posedge clk); #1;
    end
    valid_in = 0;

    // wait for scale_valid
    @(posedge scale_valid);
    @(posedge clk); #1;
    if (scale !== ref_scale)
        $display("[FAIL] scale: got %0d, expected %0d", scale, ref_scale);
    else
        $display("[PASS] scale = %0d", scale);

    // collect ROWS quantized rows
    row_out = 0;
    // first valid_out arrives one cycle after QUANTIZE starts
    @(posedge valid_out);
    repeat (ROWS) begin
        @(posedge clk); #1;
        if (valid_out) begin
            for (c = 0; c < COLS; c = c+1) begin
                if (quant_out[c] !== ref_quant[row_out][c]) begin
                    $display("[FAIL] row %0d col %0d: got %0d, expected %0d",
                             row_out, c, quant_out[c], ref_quant[row_out][c]);
                    errors = errors + 1;
                end
            end
            row_out = row_out + 1;
        end
    end

    // ── Test 2: all-zeros (scale = 0, no divide-by-zero) ─────────────────
    $display("[TB] Test 2: all-zero input");
    for (r = 0; r < ROWS; r = r+1)
        for (c = 0; c < COLS; c = c+1)
            ref_data[r][c] = 0;
    compute_reference;

    start    = 1; @(posedge clk); #1; start = 0;
    valid_in = 1;
    for (r = 0; r < ROWS; r = r+1) begin
        for (c = 0; c < COLS; c = c+1) data_in[c] = 0;
        @(posedge clk); #1;
    end
    valid_in = 0;

    @(posedge scale_valid); @(posedge clk); #1;
    if (scale !== 0)
        $display("[FAIL] all-zero scale: got %0d, expected 0", scale);
    else
        $display("[PASS] all-zero scale = 0");

    row_out = 0;
    @(posedge valid_out);
    repeat (ROWS) begin
        @(posedge clk); #1;
        if (valid_out) begin
            for (c = 0; c < COLS; c = c+1)
                if (quant_out[c] !== 0) begin
                    $display("[FAIL] all-zero row %0d col %0d: got %0d", row_out, c, quant_out[c]);
                    errors = errors + 1;
                end
            row_out = row_out + 1;
        end
    end
    $display("[PASS] all-zero outputs verified");

    // ── Test 3: single large value (saturation check) ─────────────────────
    $display("[TB] Test 3: saturation — one element = 32767");
    for (r = 0; r < ROWS; r = r+1)
        for (c = 0; c < COLS; c = c+1)
            ref_data[r][c] = 0;
    ref_data[0][0] = 16'sd32767;
    compute_reference;

    start    = 1; @(posedge clk); #1; start = 0;
    valid_in = 1;
    for (r = 0; r < ROWS; r = r+1) begin
        for (c = 0; c < COLS; c = c+1) data_in[c] = ref_data[r][c];
        @(posedge clk); #1;
    end
    valid_in = 0;

    @(posedge scale_valid); @(posedge clk); #1;
    $display("[TB] saturation scale = %0d (expected %0d)", scale, ref_scale);
    if (scale !== ref_scale) errors = errors + 1;

    row_out = 0;
    @(posedge valid_out);
    repeat (ROWS) begin
        @(posedge clk); #1;
        if (valid_out) begin
            for (c = 0; c < COLS; c = c+1)
                if (quant_out[c] !== ref_quant[row_out][c]) begin
                    $display("[FAIL] sat row %0d col %0d: got %0d, expected %0d",
                             row_out, c, quant_out[c], ref_quant[row_out][c]);
                    errors = errors + 1;
                end
            row_out = row_out + 1;
        end
    end

    // ── Summary ───────────────────────────────────────────────────────────
    if (errors == 0)
        $display("[TB] All tests PASSED");
    else
        $display("[TB] %0d error(s) detected", errors);

    $finish;
end

// Timeout guard
initial begin
    #5000000;
    $display("[TB] TIMEOUT");
    $finish;
end

endmodule

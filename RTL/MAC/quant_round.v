`timescale 1ns/10ps

// quant_round — per-group int16 → int8 quantization
//
// Instantiate once for Q and once for K.  Each instance handles one
// group of ROWS×COLS int16 values and outputs them as int8 together
// with the scale factor needed for dequantization.
//
// Protocol
// ─────────────────────────────────────────────────────────────────────
//  1. Assert `start` for one cycle to begin a new group.
//  2. Drive `data_in` (64 × int16) with `valid_in` high for 1024
//     consecutive cycles — one row per cycle (FIND_MAX phase).
//     The module writes every row to an internal buffer and tracks
//     the global absolute maximum across all ROWS×COLS values.
//  3. After all rows arrive the module automatically enters QUANTIZE.
//     `scale_valid` pulses for one cycle and `scale` holds
//         scale = global_max >> 7   (≈ max / 128)
//     Then `valid_out` goes high for ROWS cycles; each cycle
//     `quant_out` carries one fully-quantized row (64 × int8).
//
// Mapping to tile.v / MAC.v
// ─────────────────────────────────────────────────────────────────────
//  Each row is 64 × int8 = 512 bits.  Split for tile.v as:
//    Round 1 vecA[i] / vecB  ← {quant_out[31],...,quant_out[0]}  (256b)
//    Round 2 vecA[i] / vecB  ← {quant_out[63],...,quant_out[32]} (256b)
//  Run tile for 2 rounds × 16 columns per tile to complete a 64-dim
//  dot product.
//
// Area × Time notes
// ─────────────────────────────────────────────────────────────────────
//  FIND_MAX  : 1024 cycles, one 64-leaf max-tree (combinational)
//  QUANTIZE  : 1024 cycles, 64 parallel signed dividers (one per col)
//  Buffer    : 1024×64×16b ≈ 128 KB — inferred as BRAM by synthesis
//              (requires 64 BRAMs in parallel or one 1024b-wide bank)
//  Divider opt: all 64 divisions share the same divisor (eff_scale).
//               Replace with a reciprocal LUT + multiply for lower area
//               at the cost of ~1 LSB rounding error.

module quant_round #(
    parameter ROWS  = 1024,   // number of vectors (query or key count)
    parameter COLS  = 64,     // embedding dimension
    parameter IN_W  = 16,     // input word width  (signed int16)
    parameter OUT_W = 8       // output word width (signed int8)
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // control
    input  wire                    start,       // 1-cycle pulse: begin new group
    input  wire                    valid_in,    // upstream row is valid

    // data in: one complete row per cycle
    input  wire signed [IN_W-1:0]  data_in  [0:COLS-1],

    // outputs
    output reg  [IN_W-1:0]         scale,       // global_max >> 7
    output reg                     scale_valid, // 1-cycle pulse when scale ready
    output reg                     valid_out,   // quantized row on quant_out
    output reg  signed [OUT_W-1:0] quant_out [0:COLS-1]  // 64 × int8
);

// ─── FSM ──────────────────────────────────────────────────────────────────────
localparam IDLE     = 2'd0,
           FIND_MAX = 2'd1,
           QUANTIZE = 2'd2;

reg [1:0]  state;
reg [9:0]  row_cnt;   // 0 .. ROWS-1

// ─── Internal data buffer ─────────────────────────────────────────────────────
// Synthesis tools map this 2-D array to block RAM.
// Write port: 64 × 16b per cycle (one full row).
// Read port:  combinational, addressed by row_cnt during QUANTIZE.
reg signed [IN_W-1:0] buf_mem [0:ROWS-1][0:COLS-1];

// ─── Global max accumulator ───────────────────────────────────────────────────
reg [IN_W-1:0] global_max;

// ─── Absolute-value of each input column (combinational) ─────────────────────
// Two's-complement negate for negative values.
// Edge case: -32768 → 0x8000 (wraps in 16b); benign — scale stays correct.
wire [IN_W-1:0] abs_in [0:COLS-1];
genvar g;
generate
    for (g = 0; g < COLS; g = g + 1) begin : GEN_ABS
        assign abs_in[g] = data_in[g][IN_W-1]
                         ? (~data_in[g] + 1'b1)
                         :  data_in[g];
    end
endgenerate

// ─── 6-level binary max-reduction tree: 64 leaves → 1 (combinational) ────────
wire [IN_W-1:0] t0 [0:31];
wire [IN_W-1:0] t1 [0:15];
wire [IN_W-1:0] t2 [0:7];
wire [IN_W-1:0] t3 [0:3];
wire [IN_W-1:0] t4 [0:1];
wire [IN_W-1:0] t5;

generate
    for (g = 0; g < 32; g = g+1) begin : T0
        assign t0[g] = (abs_in[2*g] >= abs_in[2*g+1]) ? abs_in[2*g] : abs_in[2*g+1];
    end
    for (g = 0; g < 16; g = g+1) begin : T1
        assign t1[g] = (t0[2*g] >= t0[2*g+1]) ? t0[2*g] : t0[2*g+1];
    end
    for (g = 0; g < 8; g = g+1) begin : T2
        assign t2[g] = (t1[2*g] >= t1[2*g+1]) ? t1[2*g] : t1[2*g+1];
    end
    for (g = 0; g < 4; g = g+1) begin : T3
        assign t3[g] = (t2[2*g] >= t2[2*g+1]) ? t2[2*g] : t2[2*g+1];
    end
    for (g = 0; g < 2; g = g+1) begin : T4
        assign t4[g] = (t3[2*g] >= t3[2*g+1]) ? t3[2*g] : t3[2*g+1];
    end
endgenerate
assign t5 = (t4[0] >= t4[1]) ? t4[0] : t4[1];

// Fold current row max into running global max without an extra register stage.
wire [IN_W-1:0] new_max = (t5 >= global_max) ? t5 : global_max;

// ─── Quantisation combinational path ──────────────────────────────────────────
// Guard against zero-divide when all inputs are zero (scale would be 0).
// When scale == 0 every |value| < 128 so dividing by 1 and clamping is safe.
wire [IN_W-1:0] eff_scale = (scale == {IN_W{1'b0}})
                           ? {{IN_W-1{1'b0}}, 1'b1}
                           : scale;

integer q;
reg signed [IN_W:0]    div_result;          // 17-bit signed intermediate
reg signed [OUT_W-1:0] quant_next [0:COLS-1];

// div_result[IN_W : OUT_W-1] must equal {(IN_W-OUT_W+2){sign}} for no overflow.
// If not, clamp to 8'h7F (+127) or 8'h80 (-128).
always @(*) begin
    for (q = 0; q < COLS; q = q + 1) begin
        // Sign-extend numerator to IN_W+1 bits; zero-extend denominator.
        div_result = {{1{buf_mem[row_cnt][q][IN_W-1]}}, buf_mem[row_cnt][q]}
                   / $signed({1'b0, eff_scale});

        if (div_result[IN_W : OUT_W-1] != {(IN_W-OUT_W+2){div_result[IN_W]}})
            // Overflow: saturate toward the appropriate boundary.
            quant_next[q] = div_result[IN_W] ? 8'h80 : 8'h7F;
        else
            quant_next[q] = div_result[OUT_W-1:0];
    end
end

// ─── FSM ──────────────────────────────────────────────────────────────────────
integer i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= IDLE;
        row_cnt     <= 10'd0;
        global_max  <= {IN_W{1'b0}};
        scale       <= {IN_W{1'b0}};
        scale_valid <= 1'b0;
        valid_out   <= 1'b0;
        for (i = 0; i < COLS; i = i + 1)
            quant_out[i] <= {OUT_W{1'b0}};
    end
    else begin
        // Default: clear single-cycle pulses every clock.
        scale_valid <= 1'b0;
        valid_out   <= 1'b0;

        case (state)

            // ── Wait for start pulse ──────────────────────────────────────
            IDLE: begin
                if (start) begin
                    state      <= FIND_MAX;
                    row_cnt    <= 10'd0;
                    global_max <= {IN_W{1'b0}};
                end
            end

            // ── Phase 1: buffer data and track global max ─────────────────
            // One row per cycle while valid_in is high.
            // new_max folds this row's tree result into global_max without
            // a one-cycle delay, so the final max includes the last row.
            FIND_MAX: begin
                if (valid_in) begin
                    for (i = 0; i < COLS; i = i + 1)
                        buf_mem[row_cnt][i] <= data_in[i];
                    global_max <= new_max;

                    if (row_cnt == ROWS - 1) begin
                        scale       <= new_max >> 7;   // area-efficient ÷128
                        scale_valid <= 1'b1;
                        row_cnt     <= 10'd0;
                        state       <= QUANTIZE;
                    end
                    else begin
                        row_cnt <= row_cnt + 1'b1;
                    end
                end
            end

            // ── Phase 2: quantize buffered data row by row ────────────────
            // quant_next is computed combinationally from buf_mem[row_cnt].
            // We register it here, so valid_out and quant_out are in phase:
            //   cycle 0  → registers row 0 → quant_out valid on cycle 1
            //   cycle 1  → registers row 1 → quant_out valid on cycle 2
            //   ...
            //   cycle 1023 → registers row 1023 → quant_out valid on cycle 1024
            // Total valid output window: ROWS cycles.
            QUANTIZE: begin
                for (i = 0; i < COLS; i = i + 1)
                    quant_out[i] <= quant_next[i];
                valid_out <= 1'b1;

                if (row_cnt == ROWS - 1) begin
                    state   <= IDLE;
                    row_cnt <= 10'd0;
                end
                else begin
                    row_cnt <= row_cnt + 1'b1;
                end
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule

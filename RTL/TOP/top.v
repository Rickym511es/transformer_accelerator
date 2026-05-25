`timescale 1ns/10ps
//
// top: integrated MAC tile + PPU.
//
// Bench drives the MAC operand side exactly like tb_MAC.v's pattern
// (vecA / vecB / start / tile_done).  An internal row-feeder FSM
// takes over once tile_done fires: it reads tile.latch_array directly
// (latch_array itself acts as the single buffer; tile.v only updates
// it on tile_done so it's stable for the 32-cycle PPU drain) and
// drives PPU's valid / mac_result_vec in the same low/high half
// pattern the standalone PPU bench used.
//
// Inter-tile timing:
//   tile_done (cycle 0) -> latch_array updates at this edge
//   cycle 1: FSM enters S_FEED, drives row 0 + valid=1
//   cycle 2: PPU samples row 0
//   ...
//   cycle 33: PPU samples last clear; FSM back to IDLE
// Next tile_done lands at cycle ~35-36 from the bench's natural cadence
// (32 vecB cycles + bubbles + tile_done pulse), so latch_array is safe
// to read up through cycle 31.
//
// vecA is exposed as a packed bus on the top-level boundary so the
// synthesized netlist has clean Verilog-2001 ports (no unpacked-array
// flattening surprises like we hit on the standalone MAC gate sim).
// tile.v itself is now flat too, so vecA/latch_array pass straight
// through with no pack/unpack wrappers.

module top (
    input  wire                 clk,
    input  wire                 rst_n,

    // MAC operand-side (bench drives, identical timing to tb_MAC.v)
    input  wire [16*256-1:0]    vecA,         // packed: row k at vecA[k*256 +: 256]
    input  wire [255:0]         vecB,
    input  wire                 start,
    input  wire                 tile_done,

    // PPU result-side (passes through)
    output wire                 softmax_valid,
    output wire [16*8-1:0]      softmax_result_vec,
    output wire [23:0]          softmax_scale
);

    // latch_array layout: element (lane,col) at [(lane*16 + col)*24 +: 24]
    wire [16*16*24-1:0] latch_array;

    tile u_tile (
        .clk        (clk),
        .rst_n      (rst_n),
        .vecA       (vecA),
        .vecB       (vecB),
        .start      (start),
        .tile_done  (tile_done),
        .latch_array(latch_array)
    );

    // ------------------------------------------------------------------
    // PPU row-feeder FSM
    // ------------------------------------------------------------------
    // S_IDLE: waiting for tile_done.  ppu_valid_r held low.
    // S_FEED: 32 cycles.  phase = 0..31.
    //   phase[0] == 0 (even): low half  -> drive valid=1, data = row_bus
    //   phase[0] == 1 (odd ): high half -> drive valid=0
    //   row index = phase[4:1], walks 0..15 across the 32 cycles.
    localparam S_IDLE = 1'b0;
    localparam S_FEED = 1'b1;

    reg              state;
    reg [4:0]        phase;
    reg              ppu_valid_r;
    reg [16*24-1:0]  ppu_mac_result_vec_r;

    wire [3:0] row_idx = phase[4:1];

    // Pull the currently-selected row of latch_array (16 cols * 24 b each)
    // out of the flat bus. Element (lane=row_idx, col=gr) sits at
    // (row_idx*16 + gr)*24, which is a contiguous 16*24 = 384-bit slice
    // starting at row_idx*16*24.
    wire [16*24-1:0] row_bus = latch_array[row_idx*16*24 +: 16*24];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= S_IDLE;
            phase                <= 5'd0;
            ppu_valid_r          <= 1'b0;
            ppu_mac_result_vec_r <= {16*24{1'b0}};
        end
        else begin
            case (state)
                S_IDLE: begin
                    ppu_valid_r          <= 1'b0;
                    ppu_mac_result_vec_r <= {16*24{1'b0}};
                    phase                <= 5'd0;
                    if (tile_done)
                        state <= S_FEED;
                end
                S_FEED: begin
                    if (phase[0] == 1'b0) begin
                        ppu_valid_r          <= 1'b1;
                        ppu_mac_result_vec_r <= row_bus;
                    end
                    else begin
                        ppu_valid_r          <= 1'b0;
                        ppu_mac_result_vec_r <= {16*24{1'b0}};
                    end
                    if (phase == 5'd31) begin
                        state <= S_IDLE;
                        phase <= 5'd0;
                    end
                    else begin
                        phase <= phase + 5'd1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    PPU u_ppu (
        .clk               (clk),
        .rst_n             (rst_n),
        .valid             (ppu_valid_r),
        .mac_result_vec    (ppu_mac_result_vec_r),
        .softmax_valid     (softmax_valid),
        .softmax_result_vec(softmax_result_vec),
        .softmax_scale     (softmax_scale)
    );

endmodule

`timescale 1ns/10ps
// Pure Verilog-2001: no SystemVerilog unpacked-array ports.
// MAC16 collapses the 16-lane vecA / partial_sum_in / result interface
// into flat packed buses so the older synth/APR flow can read it without
// the `sverilog` analyze format.

// int8-only mode: old mode-gated header kept here for reference.
// module MAC_unit(vecA, vecB, int4_gate, int8_gate, VSQ_gate, partial_sum_in, result); // Fig 7
module MAC_unit(vecA, vecB, partial_sum_in, result); // Fig 7
//(1) initialization of parameters
input  [255:0] vecA; // int8 : wide32 * 8 = 256 bits // int4 : wide64 * 4 = 256 bits
input  [255:0] vecB;
// input int4_gate;
// input int8_gate;
// input VSQ_gate;
input  [23:0] partial_sum_in; // partial sum in : 24 bits
output reg signed [23:0] result; // partial sum out : 24 bits

//(2) other regs and wires
reg signed [20:0] int8_dotout;
integer n;

//(3) int8 dot product
always @(*) begin
    int8_dotout = 21'd0;
    for (n=0; n<32; n=n+1) begin
        int8_dotout = int8_dotout +  $signed(vecA[n*8 +: 8]) * $signed(vecB[n*8 +: 8]);
    end
end

// assign result
always @(*) begin
    result = partial_sum_in + {{3{int8_dotout[20]}}, int8_dotout};
end
endmodule

// int8-only mode: old mode-gated header kept here for reference.
// module MAC16(vecA, vecB, int4_gate, int8_gate, VSQ_gate, partial_sum_in, result); // Fig 6
module MAC16(vecA, vecB, partial_sum_in, result); // Fig 6
// Lane layout (flat packed):
//   vecA           : 16 lanes * 256 bits ; lane k at vecA[k*256 +: 256]
//   partial_sum_in : 16 lanes *  24 bits ; lane k at partial_sum_in[k*24 +: 24]
//   result         : 16 lanes *  24 bits ; lane k at result[k*24 +: 24]
input  [16*256-1:0] vecA;
input  [255:0]      vecB;
input  [16*24-1:0]  partial_sum_in;
output [16*24-1:0]  result;

genvar i;
generate
    for(i = 0; i < 16; i = i + 1) begin : MAC_LANE
        MAC_unit MAC_inst (
            .vecA(vecA[i*256 +: 256]),
            .vecB(vecB),
            .partial_sum_in(partial_sum_in[i*24 +: 24]),
            .result(result[i*24 +: 24])
        );
    end
endgenerate
endmodule

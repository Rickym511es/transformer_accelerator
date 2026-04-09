module LPW_expo(data_in, max, result);
input  signed [39:0] data_in; //Q16.24
input  signed [39:0] max;     //Q16.24
output reg    [16:0] result;  //Q1.16

localparam [16:0] ONE_Q16 = 17'd65536;

//(1) compute data_in - max
wire signed [39:0] diff;
assign diff = data_in - max; 

// split diff = I + F, where:
// I : signed integer term in Q16.0
// F : fractional term in Q0.24, 0 <= F < 1
wire signed [15:0] I;
wire        [23:0] F;

assign I = diff[39:24];  // integer part
assign F = diff[23:0];   // fraction part

//(2) compute exp(data_in - max)
// m : Q2.16
// c : Q1.16  (because c can be 1.0)
reg [17:0] m;
reg [16:0] c;

always @(*) begin
    case (F[23:22])   // 4 segments
        2'b00: begin m = 18'd49481; c = 17'd65109; end
        2'b01: begin m = 18'd58851; c = 17'd61864; end
        2'b10: begin m = 18'd69983; c = 17'd56441; end
        default: begin m = 18'd83233; c = 17'd51467; end
    endcase
end

// m * F : Q2.16 * Q0.24 = Q2.40
wire [41:0] mult_full;
assign mult_full = m * F;

// take back to Q2.16
wire [17:0] mult_q16;
assign mult_q16 = mult_full[41:24];

// approx 2^F in Q2.16 (18-bit intermediate, nominal range [1,2))
wire [17:0] exp_frac;
assign exp_frac = mult_q16 + {1'b0, c};

// apply 2^I with a bounded logical right shift.
// exp_full stays in Q2.16, then we clamp down to the Q1.16 output range.
wire [15:0] neg_i_mag;
wire [4:0]  shift_amt;
wire [17:0] exp_full;

assign neg_i_mag = ~I + 16'd1;
assign shift_amt = (!diff[39]) ? 5'd0 : ((|neg_i_mag[15:5]) || (neg_i_mag[4:0] > 5'd18)) ? 5'd18 : neg_i_mag[4:0];
assign exp_full = exp_frac >> shift_amt;

always @(*) begin
    if (!diff[39]) begin
        // After subtracting the row max, diff should be <= 0.
        // Clamp any non-negative case to 1.0 so the shifter never sees a negative amount.
        result = ONE_Q16;
    end
    else if (exp_full >= {1'b0, ONE_Q16}) begin
        result = ONE_Q16;
    end
    else begin
        result = exp_full[16:0];
    end
end
endmodule

module LPW_expo_16(data_in_vec, max,result_vec);
input  [16*40-1:0] data_in_vec;   // 16 x Q16.24
input  [39:0]      max;           // common max for this row
output [16*17-1:0] result_vec;    // 16 x Q1.16

genvar i;
generate
    for (i=0; i<16; i=i+1) begin : GEN_EXPO
        LPW_expo u_LPW_expo (
            .data_in (data_in_vec[i*40 +: 40]),
            .max     (max),
            .result  (result_vec[i*17 +: 17])
        );
    end
endgenerate
endmodule


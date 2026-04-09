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
    4-segment LPW (step = 0.25), kept here for reference:
    case (F[23:22]) // top 2 bits of F determine the segment
        2'b00: begin m = 18'd49667; c = 17'd65536; end
        2'b01: begin m = 18'd59185; c = 17'd63074; end
        2'b10: begin m = 18'd70426; c = 17'd57372; end
        default: begin m = 18'd83873; c = 17'd47940; end
    endcase

    // // 8-segment LPW (step = 0.125), select by the top 3 bits of F
    // case (F[23:21])
    //     3'b000: begin m = 18'd47452; c = 17'd65504; end
    //     3'b001: begin m = 18'd51747; c = 17'd64964; end
    //     3'b010: begin m = 18'd56430; c = 17'd63790; end
    //     3'b011: begin m = 18'd61538; c = 17'd61871; end
    //     3'b100: begin m = 18'd67107; c = 17'd59083; end
    //     3'b101: begin m = 18'd73181; c = 17'd55283; end
    //     3'b110: begin m = 18'd79805; c = 17'd50310; end
    //     default: begin m = 18'd87028; c = 17'd43986; end
    // endcase
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


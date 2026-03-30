module softmax(clk, rst_n, );

endmodule

module LPW_expo(data_in, max, result);
input [39:0] data_in; //Q16.24
input [39:0] max;     //Q16.24
output [16:0] result; //Q1.16

//(1) compute data_in - max
wire signed [39:0] diff;
assign diff = data_in - max; 

// split diff = I + F
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
        2'b00: begin
            m = 18'd49611;   // 0.757 * 2^16
            c = 17'd65536;   // 1.000 * 2^16
        end
        2'b01: begin
            m = 18'd58982;   // 0.900 * 2^16
            c = 17'd63177;   // 0.964 * 2^16
        end
        2'b10: begin
            m = 18'd70124;   // 1.070 * 2^16
            c = 17'd57606;   // 0.879 * 2^16
        end
        default: begin
            m = 18'd83427;   // 1.273 * 2^16
            c = 17'd47645;   // 0.727 * 2^16
        end
    endcase
end

// m * F : Q2.16 * Q0.24 = Q2.40
wire [41:0] mult_full;
assign mult_full = m * F;

// take back to Q2.16
wire [17:0] mult_q16;
assign mult_q16 = mult_full[39:24];

// approx 2^F in Q1.16
wire [17:0] exp_frac;
assign exp_frac = mult_q16 + c;

// apply 2^I
integer shift_amt;
reg [17:0] exp_full;

always @(*) begin
    if (diff == 0) begin
        // ideal case after subtract max: only diff=0 should hit here
        result = 17'd65536;   // 1.0 in Q1.16
    end
    else begin
        shift_amt = -I;
        exp_full  = exp_frac >> shift_amt;

        // saturate to [0, 1.0]
        if (exp_full >= 18'd65536)
            result = 17'd65536;
        else
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

module LPW_expo_16parallel_sv(
    input  logic [39:0] data_in_vec [0:15],
    input  logic [39:0] max,
    output logic [16:0] result_vec  [0:15]
);

genvar i;
generate
    for (i=0; i<16; i=i+1) begin : GEN_EXPO
        LPW_expo u_LPW_expo (
            .data_in (data_in_vec[i]),
            .max     (max),
            .result  (result_vec[i])
        );
    end
endgenerate

endmodule
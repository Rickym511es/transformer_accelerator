// Max finder for 16 signed Q24.16 values packed into 16*40 bits.
// A balanced compare tree keeps the combinational depth low.
module vec_max(data_in_vec, max_value);
input  signed [16*40-1:0] data_in_vec;
output signed [39:0]      max_value;

wire signed [39:0] x0  = $signed(data_in_vec[  0 +: 40]);
wire signed [39:0] x1  = $signed(data_in_vec[ 40 +: 40]);
wire signed [39:0] x2  = $signed(data_in_vec[ 80 +: 40]);
wire signed [39:0] x3  = $signed(data_in_vec[120 +: 40]);
wire signed [39:0] x4  = $signed(data_in_vec[160 +: 40]);
wire signed [39:0] x5  = $signed(data_in_vec[200 +: 40]);
wire signed [39:0] x6  = $signed(data_in_vec[240 +: 40]);
wire signed [39:0] x7  = $signed(data_in_vec[280 +: 40]);
wire signed [39:0] x8  = $signed(data_in_vec[320 +: 40]);
wire signed [39:0] x9  = $signed(data_in_vec[360 +: 40]);
wire signed [39:0] x10 = $signed(data_in_vec[400 +: 40]);
wire signed [39:0] x11 = $signed(data_in_vec[440 +: 40]);
wire signed [39:0] x12 = $signed(data_in_vec[480 +: 40]);
wire signed [39:0] x13 = $signed(data_in_vec[520 +: 40]);
wire signed [39:0] x14 = $signed(data_in_vec[560 +: 40]);
wire signed [39:0] x15 = $signed(data_in_vec[600 +: 40]);

wire signed [39:0] s1_0 = (x0  > x1)  ? x0  : x1;
wire signed [39:0] s1_1 = (x2  > x3)  ? x2  : x3;
wire signed [39:0] s1_2 = (x4  > x5)  ? x4  : x5;
wire signed [39:0] s1_3 = (x6  > x7)  ? x6  : x7;
wire signed [39:0] s1_4 = (x8  > x9)  ? x8  : x9;
wire signed [39:0] s1_5 = (x10 > x11) ? x10 : x11;
wire signed [39:0] s1_6 = (x12 > x13) ? x12 : x13;
wire signed [39:0] s1_7 = (x14 > x15) ? x14 : x15;

wire signed [39:0] s2_0 = (s1_0 > s1_1) ? s1_0 : s1_1;
wire signed [39:0] s2_1 = (s1_2 > s1_3) ? s1_2 : s1_3;
wire signed [39:0] s2_2 = (s1_4 > s1_5) ? s1_4 : s1_5;
wire signed [39:0] s2_3 = (s1_6 > s1_7) ? s1_6 : s1_7;

wire signed [39:0] s3_0 = (s2_0 > s2_1) ? s2_0 : s2_1;
wire signed [39:0] s3_1 = (s2_2 > s2_3) ? s2_2 : s2_3;

assign max_value = (s3_0 > s3_1) ? s3_0 : s3_1;
endmodule

module LPW_expo(data_in, max, result);
input  signed [39:0] data_in; //Q24.16
input  signed [39:0] max;     //Q24.16
output reg    [16:0] result;  //Q1.16

localparam [16:0] ONE_Q16 = 17'd65536;

//(1) compute data_in - max
wire signed [39:0] diff;
assign diff = data_in - max; 

// split diff = I + F, where:
// I : signed integer term in Q24.0
// F : fractional term in Q0.16, 0 <= F < 1
wire signed [23:0] I;
wire        [15:0] F;

assign I = diff[39:16];  // integer part
assign F = diff[15:0];   // fraction part

//(2) compute exp(data_in - max)
// m : Q2.16
// c : Q1.16  (because c can be 1.0)
reg [17:0] m;
reg [16:0] c;

always @(*) begin
    // 8-segment LPW (step = 0.125), select by the top 3 bits of F.
    case (F[15:13])
        3'b000: begin m = 18'd47452; c = 17'd65504; end
        3'b001: begin m = 18'd51747; c = 17'd64964; end
        3'b010: begin m = 18'd56430; c = 17'd63790; end
        3'b011: begin m = 18'd61538; c = 17'd61871; end
        3'b100: begin m = 18'd67107; c = 17'd59083; end
        3'b101: begin m = 18'd73181; c = 17'd55283; end
        3'b110: begin m = 18'd79805; c = 17'd50310; end
        default: begin m = 18'd87028; c = 17'd43986; end
    endcase
end

// m * F : Q2.16 * Q0.16 = Q2.32
wire [33:0] mult_full;
assign mult_full = m * F;

// take back to Q2.16
wire [17:0] mult_q16;
assign mult_q16 = mult_full[33:16];

// approx 2^F in Q2.16 (18-bit intermediate, nominal range [1,2))
wire [17:0] exp_frac;
assign exp_frac = mult_q16 + {1'b0, c};

// apply 2^I with a bounded logical right shift.
// exp_full stays in Q2.16, then we clamp down to the Q1.16 output range.
wire [23:0] neg_i_mag;
wire [4:0]  shift_amt;
wire [17:0] exp_full;

assign neg_i_mag = ~I + 24'd1;
assign shift_amt = (!diff[39]) ? 5'd0 : ((|neg_i_mag[23:5]) || (neg_i_mag[4:0] > 5'd18)) ? 5'd18 : neg_i_mag[4:0];
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

module constant_estimation_expo(data_in, max, result);
input  signed [39:0] data_in; //Q24.16
input  signed [39:0] max;     //Q24.16
output reg    [16:0] result;  //Q1.16

localparam [16:0] ONE_Q16 = 17'd65536;

wire signed [39:0] diff;
assign diff = data_in - max;

wire signed [23:0] I;
wire        [15:0] F;
wire        [4:0]  frac_seg;

assign I = diff[39:16];
assign F = diff[15:0];
assign frac_seg = F[15:11];

reg [17:0] exp_frac;
always @(*) begin
    case (frac_seg)
        5'd0:  exp_frac = 18'd65536;
        5'd1:  exp_frac = 18'd66971;
        5'd2:  exp_frac = 18'd68438;
        5'd3:  exp_frac = 18'd69936;
        5'd4:  exp_frac = 18'd71468;
        5'd5:  exp_frac = 18'd73032;
        5'd6:  exp_frac = 18'd74632;
        5'd7:  exp_frac = 18'd76266;
        5'd8:  exp_frac = 18'd77936;
        5'd9:  exp_frac = 18'd79642;
        5'd10: exp_frac = 18'd81386;
        5'd11: exp_frac = 18'd83169;
        5'd12: exp_frac = 18'd84990;
        5'd13: exp_frac = 18'd86851;
        5'd14: exp_frac = 18'd88752;
        5'd15: exp_frac = 18'd90696;
        5'd16: exp_frac = 18'd92682;
        5'd17: exp_frac = 18'd94711;
        5'd18: exp_frac = 18'd96785;
        5'd19: exp_frac = 18'd98905;
        5'd20: exp_frac = 18'd101070;
        5'd21: exp_frac = 18'd103283;
        5'd22: exp_frac = 18'd105545;
        5'd23: exp_frac = 18'd107856;
        5'd24: exp_frac = 18'd110218;
        5'd25: exp_frac = 18'd112631;
        5'd26: exp_frac = 18'd115098;
        5'd27: exp_frac = 18'd117618;
        5'd28: exp_frac = 18'd120194;
        5'd29: exp_frac = 18'd122825;
        5'd30: exp_frac = 18'd125515;
        default: exp_frac = 18'd128263;
    endcase
end

wire [23:0] neg_i_mag;
wire [4:0]  shift_amt;
wire [17:0] exp_full;

assign neg_i_mag = ~I + 24'd1;
assign shift_amt = (!diff[39]) ? 5'd0 : ((|neg_i_mag[23:5]) || (neg_i_mag[4:0] > 5'd18)) ? 5'd18 : neg_i_mag[4:0];
assign exp_full = exp_frac >> shift_amt;

always @(*) begin
    if (!diff[39])
        result = ONE_Q16;
    else if (exp_full >= {1'b0, ONE_Q16})
        result = ONE_Q16;
    else
        result = exp_full[16:0];
end
endmodule

// Reciprocal dataflow for softmax normalization:
// 1. Sum the 16 exponential outputs externally into data_in (UQ12.16).
// 2. Normalize data_in = 2^e * u, where u is in [1, 2). 
// 3. Approximate 1/u with an 8-segment LPW.
// 4. Apply 2^-e to recover 1/data_in in Q1.16.
// This datapath is lightweight; even with a clocked wrapper, it fits comfortably
// within the 64-cycle budget mentioned for the reciprocal stage.
module LPW_reciprocal(data_in, result);
input  [27:0] data_in; //UQ12.16
output reg [16:0] result; //Q1.16 since 1/1024 <= result <= 1.0

localparam [16:0] ONE_Q16 = 17'd65536;
localparam signed [19:0] ONE_Q16_EXT = 20'sd65536;

// data_in = 2^e * u, u in [1, 2)
reg [4:0] exp_shift;
always @(*) begin
    casex (data_in[27:16])
        12'b1xxxxxxxxxxx: exp_shift = 5'd11;
        12'b01xxxxxxxxxx: exp_shift = 5'd10;
        12'b001xxxxxxxxx: exp_shift = 5'd9;
        12'b0001xxxxxxxx: exp_shift = 5'd8;
        12'b00001xxxxxxx: exp_shift = 5'd7;
        12'b000001xxxxxx: exp_shift = 5'd6;
        12'b0000001xxxxx: exp_shift = 5'd5;
        12'b00000001xxxx: exp_shift = 5'd4;
        12'b000000001xxx: exp_shift = 5'd3;
        12'b0000000001xx: exp_shift = 5'd2;
        12'b00000000001x: exp_shift = 5'd1;
        default:          exp_shift = 5'd0;
    endcase
end

wire [27:0] norm_full;
wire [16:0] u_q16;
assign norm_full = data_in >> exp_shift;
assign u_q16 = (data_in == 28'd0) ? ONE_Q16 : norm_full[16:0];

// 1/u ~= m*u + c, u in [1, 2)
// m : signed Q2.16
// c : signed Q2.16
reg signed [17:0] m_recip;
reg signed [17:0] c_recip;
always @(*) begin
    case (u_q16[15:13])
        3'b000: begin m_recip = -18'sd58254; c_recip = 18'sd123790; end
        3'b001: begin m_recip = -18'sd46603; c_recip = 18'sd110683; end
        3'b010: begin m_recip = -18'sd38130; c_recip = 18'sd100091; end
        3'b011: begin m_recip = -18'sd31775; c_recip = 18'sd91353;  end
        3'b100: begin m_recip = -18'sd26887; c_recip = 18'sd84021;  end
        3'b101: begin m_recip = -18'sd23046; c_recip = 18'sd77779;  end
        3'b110: begin m_recip = -18'sd19973; c_recip = 18'sd72402;  end
        default: begin m_recip = -18'sd17476; c_recip = 18'sd67721; end
    endcase
end

wire signed [17:0] u_ext_q16;
wire signed [35:0] recip_mult_full;
wire signed [19:0] recip_mult_q16;
wire signed [19:0] recip_u_q16;
wire signed [19:0] recip_full_q16;

assign u_ext_q16 = $signed({1'b0, u_q16});
assign recip_mult_full = m_recip * u_ext_q16; // Q2.16 * Q2.16 = Q4.32
assign recip_mult_q16 = recip_mult_full >>> 16;
assign recip_u_q16 = recip_mult_q16 + c_recip;
assign recip_full_q16 = recip_u_q16 >>> exp_shift;

always @(*) begin
    if (data_in == 28'd0)
        result = 17'd0;
    else if (recip_full_q16 <= 20'sd0)
        result = 17'd0;
    else if (recip_full_q16 >= ONE_Q16_EXT)
        result = ONE_Q16;
    else
        result = recip_full_q16[16:0];
end
endmodule

module constant_estimation_reciprocal(data_in, result);
input  [27:0] data_in; //UQ12.16
output reg [16:0] result; //Q1.16

localparam [16:0] ONE_Q16 = 17'd65536;

reg [4:0] exp_shift;
always @(*) begin
    casex (data_in[27:16])
        12'b1xxxxxxxxxxx: exp_shift = 5'd11;
        12'b01xxxxxxxxxx: exp_shift = 5'd10;
        12'b001xxxxxxxxx: exp_shift = 5'd9;
        12'b0001xxxxxxxx: exp_shift = 5'd8;
        12'b00001xxxxxxx: exp_shift = 5'd7;
        12'b000001xxxxxx: exp_shift = 5'd6;
        12'b0000001xxxxx: exp_shift = 5'd5;
        12'b00000001xxxx: exp_shift = 5'd4;
        12'b000000001xxx: exp_shift = 5'd3;
        12'b0000000001xx: exp_shift = 5'd2;
        12'b00000000001x: exp_shift = 5'd1;
        default:          exp_shift = 5'd0;
    endcase
end

wire [27:0] norm_full;
wire [16:0] u_q16;
wire [4:0]  frac_seg;
reg  [16:0] recip_u_q16;
wire [16:0] recip_full_q16;

assign norm_full = data_in >> exp_shift;
assign u_q16 = (data_in == 28'd0) ? ONE_Q16 : norm_full[16:0];
assign frac_seg = u_q16[15:11];

always @(*) begin
    case (frac_seg)
        5'd0:  recip_u_q16 = 17'd65536;
        5'd1:  recip_u_q16 = 17'd63550;
        5'd2:  recip_u_q16 = 17'd61681;
        5'd3:  recip_u_q16 = 17'd59919;
        5'd4:  recip_u_q16 = 17'd58254;
        5'd5:  recip_u_q16 = 17'd56680;
        5'd6:  recip_u_q16 = 17'd55188;
        5'd7:  recip_u_q16 = 17'd53773;
        5'd8:  recip_u_q16 = 17'd52429;
        5'd9:  recip_u_q16 = 17'd51150;
        5'd10: recip_u_q16 = 17'd49932;
        5'd11: recip_u_q16 = 17'd48771;
        5'd12: recip_u_q16 = 17'd47663;
        5'd13: recip_u_q16 = 17'd46603;
        5'd14: recip_u_q16 = 17'd45590;
        5'd15: recip_u_q16 = 17'd44620;
        5'd16: recip_u_q16 = 17'd43691;
        5'd17: recip_u_q16 = 17'd42799;
        5'd18: recip_u_q16 = 17'd41943;
        5'd19: recip_u_q16 = 17'd41121;
        5'd20: recip_u_q16 = 17'd40330;
        5'd21: recip_u_q16 = 17'd39569;
        5'd22: recip_u_q16 = 17'd38836;
        5'd23: recip_u_q16 = 17'd38130;
        5'd24: recip_u_q16 = 17'd37449;
        5'd25: recip_u_q16 = 17'd36792;
        5'd26: recip_u_q16 = 17'd36158;
        5'd27: recip_u_q16 = 17'd35545;
        5'd28: recip_u_q16 = 17'd34953;
        5'd29: recip_u_q16 = 17'd34380;
        5'd30: recip_u_q16 = 17'd33825;
        default: recip_u_q16 = 17'd33288;
    endcase
end

assign recip_full_q16 = recip_u_q16 >> exp_shift;

always @(*) begin
    if (data_in == 28'd0)
        result = 17'd0;
    else if (recip_full_q16 >= ONE_Q16)
        result = ONE_Q16;
    else
        result = recip_full_q16;
end
endmodule


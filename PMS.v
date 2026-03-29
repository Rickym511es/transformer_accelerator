// No need of valid/busy signals since the time of PMS not exceeds the time of MAC
// The output of PMS is directly fed into the next stage without buffering
module PMS(MAC_result, scale, PMS_result, clk, rst_n, done); 
input clk, rst_n;
input signed [383:0] MAC_result;
input [255:0] scale;
output reg signed [639:0] PMS_result; 
output reg done;

reg [2:0] counter;
wire signed [23:0] mac0, mac1;
wire        [15:0] sc0,  sc1;
wire signed [39:0] prod0, prod1;

assign mac0 = MAC_result[(counter*2)*24 +: 24];
assign mac1 = MAC_result[(counter*2+1)*24 +: 24];

assign sc0  = scale[(counter*2)*16 +: 16];
assign sc1  = scale[(counter*2+1)*16 +: 16];

assign prod0 = mac0 * sc0;
assign prod1 = mac1 * sc1;

always@(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
        counter <= 3'd0;
        PMS_result  <= 640'sd0;
        done    <= 1'b0;
    end
    else begin
        PMS_result[((counter*2)*40)   +: 40] <= prod0;
        PMS_result[((counter*2+1)*40) +: 40] <= prod1;
        if (counter < 3'd7)
            counter <= counter + 3'd1;
        else begin
            counter <= 3'd0;
            done    <= 1'b1;
        end
    end
end
endmodule

module BA(PMS_result, bias, clk, rst_n, BA_result, done);
input  signed [639:0] PMS_result;
input  signed [127:0] bias;
input  clk, rst_n;
output reg signed [639:0] BA_result;
output reg done;

reg [2:0] counter;  
wire signed [39:0] bias_ext0, bias_ext1;

assign bias_ext0 = $signed(bias[(counter*2)*8 +: 8]) <<< 12;
assign bias_ext1 = $signed(bias[(counter*2+1)*8 +: 8]) <<< 12;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        counter    <= 3'd0;
        BA_result  <= 640'sd0;
        done       <= 1'b0;
    end
    else begin
        BA_result[(counter*2)*40 +: 40]
            <= PMS_result[(counter*2)*40 +: 40] + bias_ext0;
        BA_result[(counter*2+1)*40 +: 40]
            <= PMS_result[(counter*2+1)*40 +: 40] + bias_ext1;
        if (counter < 3'd7) begin
            counter <= counter + 3'd1;
        end
        else begin
            counter <= 3'd0;
            done    <= 1'b1;
        end
    end
end
endmodule

module ReLU(BA_result, ReLU_result);
input signed [639:0] BA_result;
output reg signed [639:0] ReLU_result;

integer i;
reg signed [39:0] temp;

always @(*) begin
    for (i = 0; i < 16; i = i + 1) begin
        temp = $signed(BA_result[i*40 +: 40]);
        if (temp[39])
            ReLU_result[i*40 +: 40] = 40'sd0;
        else
            ReLU_result[i*40 +: 40] = temp;
    end
end
endmodule

// part1 : per-matrix scaling + bias addition + ReLU
// fixed-point representation here
module part1(MAC_result, scale, bias, result, clk, rst_n);
input clk, rst_n;
input signed [383:0] MAC_result; // 16 x 24b
input [255:0] scale;             // 16 x 16b, Q0.16
input signed [127:0] bias;       // 16 x 8b, Q4.4
output reg signed [639:0] result; // 16 x 40b, Q23.16
endmodule

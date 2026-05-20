`timescale 1ns/1ps
// PMS is now a combinational stage.
// It divides each 24-bit integer input value by 8 and encodes the result as Q24.16.
// scale is kept in the port list for interface compatibility.
module PMS(MAC_result, scale, PMS_result); 
input signed [383:0] MAC_result;
input [255:0] scale; // kept for interface compatibility
output reg signed [639:0] PMS_result; 
integer i;

always @(*) begin
    PMS_result = 640'sd0;
    for (i = 0; i < 16; i = i + 1) begin
        PMS_result[i*40 +: 40] = $signed({{16{MAC_result[i*24+23]}}, MAC_result[i*24 +: 24]}) <<< 13;
    end
end
endmodule

// BA is now a combinational stage.
// It adds signed Q4.4 bias values to 16 packed 40-bit inputs.
module BA(PMS_result, bias, BA_result);
input  signed [639:0] PMS_result;
input  signed [127:0] bias;
output reg signed [639:0] BA_result;

integer i;

always @(*) begin
    BA_result = 640'sd0;
    for (i = 0; i < 16; i = i + 1) begin
        BA_result[i*40 +: 40] = $signed(PMS_result[i*40 +: 40]) + ($signed({{32{bias[i*8+7]}}, bias[i*8 +: 8]}) <<< 12);
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

// Combined PMS, bias addition, and ReLU stage for both PPU paths.
// scale is kept in the port list for interface compatibility with the old PMS block.
module PMS_BA_ReLU(MAC_result, scale, bias, ReLU_result);
input signed [383:0] MAC_result;
input [255:0] scale;
input signed [127:0] bias;
output reg signed [639:0] ReLU_result;

integer i;
reg signed [39:0] pms_value;
reg signed [39:0] ba_value;

always @(*) begin
    ReLU_result = 640'sd0;
    for (i = 0; i < 16; i = i + 1) begin
        pms_value = $signed({{16{MAC_result[i*24+23]}}, MAC_result[i*24 +: 24]}) <<< 13;
        ba_value = pms_value + ($signed({{32{bias[i*8+7]}}, bias[i*8 +: 8]}) <<< 12);
        if (ba_value[39])
            ReLU_result[i*40 +: 40] = 40'sd0;
        else
            ReLU_result[i*40 +: 40] = ba_value;
    end
end
endmodule
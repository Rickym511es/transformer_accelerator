`timescale 1ns/1ps

module tb_PMS;
reg signed [383:0] mac_in;
reg [255:0] scale;
reg signed [639:0] golden;
wire signed [639:0] pms_out;

integer fd;
integer case_num;
integer error_num;

function real q24_16_to_real;
    input [39:0] value;
    begin
        q24_16_to_real = $signed(value) / 65536.0;
    end
endfunction

PMS dut (
    .MAC_result(mac_in),
    .scale     (scale),
    .PMS_result(pms_out)
);

task load_case;
    output reg signed [383:0] vec;
    output reg signed [639:0] expected;
    integer i;
    reg signed [63:0] tmp;
    begin
        vec      = 384'sd0;
        expected = 640'sd0;
        for (i = 0; i < 16; i = i + 1) begin
            if ($fscanf(fd, "%d", tmp) != 1) begin
                $display("ERROR: failed to read PMS testcase value %0d", i);
                $finish;
            end
            vec[i*24 +: 24] = tmp;
        end
        for (i = 0; i < 16; i = i + 1) begin
            if ($fscanf(fd, "%d", tmp) != 1) begin
                $display("ERROR: failed to read PMS golden value %0d", i);
                $finish;
            end
            expected[i*40 +: 40] = tmp;
        end
    end
endtask

task display_case;
    input signed [383:0] vec;
    input signed [639:0] expected;
    integer i;
    reg signed [23:0] mac_lane;
    reg signed [39:0] result_lane;
    reg signed [39:0] golden_lane;
    begin
        $display("PREC case=%0d input=%h result=%h golden=%h",
                 case_num, vec, pms_out, expected);
        for (i = 0; i < 16; i = i + 1) begin
            mac_lane    = $signed(vec[i*24 +: 24]);
            result_lane = $signed(pms_out[i*40 +: 40]);
            golden_lane = $signed(expected[i*40 +: 40]);
            $display("LANE case=%0d idx=%0d mac=%0d result=%0d (%0.8f) golden=%0d (%0.8f)",
                     case_num, i, mac_lane,
                     result_lane, q24_16_to_real(result_lane),
                     golden_lane, q24_16_to_real(golden_lane));
        end
    end
endtask

task check_case;
    input signed [383:0] vec;
    input signed [639:0] expected;
    begin
        #1;
        display_case(vec, expected);

        if (pms_out !== expected) begin
            error_num = error_num + 1;
            $display("FAIL case=%0d", case_num);
            $display("  input   = %h", vec);
            $display("  output  = %h", pms_out);
            $display("  expect  = %h", expected);
        end
        else begin
            $display("PASS case=%0d", case_num);
        end
    end
endtask

initial begin
    case_num  = 0;
    error_num = 0;
    mac_in    = 384'sd0;
    scale     = 256'd0;
    golden    = 640'sd0;

    fd = $fopen("testbench/testcase/pms_cases.txt", "r");
    if (fd == 0)
        fd = $fopen("testcase/pms_cases.txt", "r");
    if (fd == 0) begin
        $display("ERROR: cannot open pms_cases.txt");
        $finish;
    end

    $display("=== PMS test start ===");
    $display("Format: each line in pms_cases.txt is 16 MAC integers followed by 16 Q24.16 golden integers");

    for (case_num = 1; case_num <= 3; case_num = case_num + 1) begin
        load_case(mac_in, golden);
        check_case(mac_in, golden);
    end

    $fclose(fd);

    $display("=== PMS test done ===");
    $display("Total cases : %0d", case_num - 1);
    $display("Total errors: %0d", error_num);
    if (error_num == 0)
        $display("RESULT: PASS");
    else
        $display("RESULT: FAIL");

    $finish;
end

endmodule

`timescale 1ns/1ps

module tb_BA;
reg signed [639:0] pms_in;
reg signed [127:0] bias_in;
reg signed [639:0] golden;
wire signed [639:0] ba_out;

integer fd;
integer case_num;
integer error_num;

function real q24_16_to_real;
    input [39:0] value;
    begin
        q24_16_to_real = $signed(value) / 65536.0;
    end
endfunction

function real q4_4_to_real;
    input [7:0] value;
    begin
        q4_4_to_real = $signed(value) / 16.0;
    end
endfunction

BA dut (
    .PMS_result(pms_in),
    .bias      (bias_in),
    .BA_result (ba_out)
);

task load_case;
    output reg signed [639:0] pms_vec;
    output reg signed [127:0] bias_vec;
    output reg signed [639:0] expected;
    integer i;
    integer tmp;
    begin
        pms_vec  = 640'sd0;
        bias_vec = 128'sd0;
        expected = 640'sd0;

        for (i = 0; i < 16; i = i + 1) begin
            if ($fscanf(fd, "%d", tmp) != 1) begin
                $display("ERROR: failed to read BA PMS value %0d", i);
                $finish;
            end
            pms_vec[i*40 +: 40] = tmp;
        end

        for (i = 0; i < 16; i = i + 1) begin
            if ($fscanf(fd, "%d", tmp) != 1) begin
                $display("ERROR: failed to read BA bias value %0d", i);
                $finish;
            end
            bias_vec[i*8 +: 8] = tmp;
        end

        for (i = 0; i < 16; i = i + 1) begin
            if ($fscanf(fd, "%d", tmp) != 1) begin
                $display("ERROR: failed to read BA golden value %0d", i);
                $finish;
            end
            expected[i*40 +: 40] = tmp;
        end
    end
endtask

task display_case;
    input signed [639:0] pms_vec;
    input signed [127:0] bias_vec;
    input signed [639:0] expected;
    integer i;
    reg signed [39:0] pms_lane;
    reg signed [7:0] bias_lane;
    reg signed [39:0] result_lane;
    reg signed [39:0] golden_lane;
    begin
        $display("PREC case=%0d input_pms=%h input_bias=%h result=%h golden=%h",
                 case_num, pms_vec, bias_vec, ba_out, expected);
        for (i = 0; i < 16; i = i + 1) begin
            pms_lane    = $signed(pms_vec[i*40 +: 40]);
            bias_lane   = $signed(bias_vec[i*8 +: 8]);
            result_lane = $signed(ba_out[i*40 +: 40]);
            golden_lane = $signed(expected[i*40 +: 40]);
            $display("LANE case=%0d idx=%0d pms=%0d (%0.8f) bias=%0d (%0.8f) result=%0d (%0.8f) golden=%0d (%0.8f)",
                     case_num, i,
                     pms_lane, q24_16_to_real(pms_lane),
                     bias_lane, q4_4_to_real(bias_lane),
                     result_lane, q24_16_to_real(result_lane),
                     golden_lane, q24_16_to_real(golden_lane));
        end
    end
endtask

task check_case;
    input signed [639:0] pms_vec;
    input signed [127:0] bias_vec;
    input signed [639:0] expected;
    begin
        #1;
        display_case(pms_vec, bias_vec, expected);

        if (ba_out !== expected) begin
            error_num = error_num + 1;
            $display("FAIL case=%0d", case_num);
            $display("  input_pms = %h", pms_vec);
            $display("  input_bias= %h", bias_vec);
            $display("  output    = %h", ba_out);
            $display("  expect    = %h", expected);
        end
        else begin
            $display("PASS case=%0d", case_num);
        end
    end
endtask

initial begin
    case_num  = 0;
    error_num = 0;
    pms_in    = 640'sd0;
    bias_in   = 128'sd0;
    golden    = 640'sd0;

    fd = $fopen("testbench/testcase/ba_cases.txt", "r");
    if (fd == 0)
        fd = $fopen("testcase/ba_cases.txt", "r");
    if (fd == 0) begin
        $display("ERROR: cannot open ba_cases.txt");
        $finish;
    end

    $display("=== BA test start ===");
    $display("Format: each line in ba_cases.txt is 16 Q24.16 PMS inputs, 16 Q4.4 bias inputs, then 16 Q24.16 golden integers");

    for (case_num = 1; case_num <= 3; case_num = case_num + 1) begin
        load_case(pms_in, bias_in, golden);
        check_case(pms_in, bias_in, golden);
    end

    $fclose(fd);

    $display("=== BA test done ===");
    $display("Total cases : %0d", case_num - 1);
    $display("Total errors: %0d", error_num);
    if (error_num == 0)
        $display("RESULT: PASS");
    else
        $display("RESULT: FAIL");

    $finish;
end

endmodule

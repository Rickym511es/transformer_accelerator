module tb_vec_max;
reg  signed [16*40-1:0] data_in_vec;
wire signed [39:0]      max_value;

integer case_num;
integer error_num;

vec_max dut (
    .data_in_vec(data_in_vec),
    .max_value   (max_value)
);

function [39:0] q24;
    input real r;
    begin
        q24 = $rtoi(r * 16777216.0);
    end
endfunction

function real q24_to_real;
    input [39:0] v;
    begin
        q24_to_real = $signed(v) / 16777216.0;
    end
endfunction

task run_case;
    input [39:0] v0;
    input [39:0] v1;
    input [39:0] v2;
    input [39:0] v3;
    input [39:0] v4;
    input [39:0] v5;
    input [39:0] v6;
    input [39:0] v7;
    input [39:0] v8;
    input [39:0] v9;
    input [39:0] v10;
    input [39:0] v11;
    input [39:0] v12;
    input [39:0] v13;
    input [39:0] v14;
    input [39:0] v15;
    input [39:0] expected;
    begin
        case_num = case_num + 1;
        data_in_vec = {v15, v14, v13, v12, v11, v10, v9, v8, v7, v6, v5, v4, v3, v2, v1, v0};
        #1;

        if (max_value !== expected) begin
            error_num = error_num + 1;
            $display("FAIL case=%0d max=%0d (%0.8f) expected=%0d (%0.8f)",
                     case_num, $signed(max_value), q24_to_real(max_value),
                     $signed(expected), q24_to_real(expected));
            $display("      packed_input=%h", data_in_vec);
        end
        else begin
            $display("PASS case=%0d max=%0d (%0.8f)",
                     case_num, $signed(max_value), q24_to_real(max_value));
        end
    end
endtask

initial begin
    case_num  = 0;
    error_num = 0;
    data_in_vec = {16*40{1'b0}};
    #1;

    $display("=== vec_max test start ===");

    // Case 1: mixed signs, maximum at x10
    run_case(
        q24(-3.0), q24(0.5),  q24(1.25), q24(4.0),
        q24(-1.0), q24(2.5),  q24(6.75), q24(3.125),
        q24(-8.0), q24(7.0),  q24(9.5),  q24(-0.25),
        q24(1.0),  q24(8.25), q24(2.0),  q24(5.0),
        q24(9.5)
    );

    // Case 2: maximum at the first element
    run_case(
        q24(12.0), q24(11.0), q24(10.0), q24(9.0),
        q24(8.0),  q24(7.0),  q24(6.0),  q24(5.0),
        q24(4.0),  q24(3.0),  q24(2.0),  q24(1.0),
        q24(0.0),  q24(-1.0), q24(-2.0), q24(-3.0),
        q24(12.0)
    );

    // Case 3: all negative values, maximum is the least negative value
    run_case(
        q24(-6.0),  q24(-5.0),  q24(-7.5),  q24(-1.0),
        q24(-2.5),  q24(-3.25), q24(-4.0),  q24(-0.5),
        q24(-8.0),  q24(-9.0),  q24(-10.0), q24(-11.0),
        q24(-12.0), q24(-13.0), q24(-14.0), q24(-15.0),
        q24(-0.5)
    );

    // Case 4: all values equal
    run_case(
        q24(3.75), q24(3.75), q24(3.75), q24(3.75),
        q24(3.75), q24(3.75), q24(3.75), q24(3.75),
        q24(3.75), q24(3.75), q24(3.75), q24(3.75),
        q24(3.75), q24(3.75), q24(3.75), q24(3.75),
        q24(3.75)
    );

    // Case 5: ascending sequence, maximum at the last element
    run_case(
        q24(0.0),  q24(1.0),  q24(2.0),  q24(3.0),
        q24(4.0),  q24(5.0),  q24(6.0),  q24(7.0),
        q24(8.0),  q24(9.0),  q24(10.0), q24(11.0),
        q24(12.0), q24(13.0), q24(14.0), q24(15.0),
        q24(15.0)
    );

    $display("=== vec_max test done ===");
    $display("Total cases : %0d", case_num);
    $display("Total errors: %0d", error_num);

    if (error_num == 0)
        $display("RESULT: PASS");
    else
        $display("RESULT: FAIL");

    $finish;
end

endmodule

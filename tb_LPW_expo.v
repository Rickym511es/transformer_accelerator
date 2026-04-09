`timescale 1ns/1ps

module tb_LPW_expo;

reg  signed [39:0] data_in;  // Q16.24
reg  signed [39:0] max;      // Q16.24
wire        [16:0] result;   // Q1.16

LPW_expo dut (
    .data_in(data_in),
    .max    (max),
    .result (result)
);

integer vec_fd;
integer scan_count;
integer case_count;

real data_real;
real max_real;
real golden_real;
real dut_real;
real signed_err;
real abs_err;
real rel_err;
real max_abs_err;
real max_rel_err;
real sum_abs_err;
real sum_sq_err;
real mse;
real mae;

function [39:0] real_to_q24;
    input real value;
    real scaled_real;
    integer scaled_int;
    begin
        scaled_real = value * 16777216.0; // 2^24
        if (scaled_real >= 0.0)
            scaled_int = $rtoi(scaled_real + 0.5);
        else
            scaled_int = $rtoi(scaled_real - 0.5);
        real_to_q24 = scaled_int[39:0];
    end
endfunction

function real q16_to_real;
    input [16:0] value;
    begin
        q16_to_real = value / 65536.0;
    end
endfunction

initial begin
    data_in      = 40'sd0;
    max          = 40'sd0;
    case_count   = 0;
    max_abs_err  = 0.0;
    max_rel_err  = 0.0;
    sum_abs_err  = 0.0;
    sum_sq_err   = 0.0;

    vec_fd = $fopen("lpw_expo_vectors.txt", "r");
    if (vec_fd == 0) begin
        $display("ERROR: cannot open lpw_expo_vectors.txt");
        $display("Each line should be: <data_real> <max_real> <golden_real>");
        $finish;
    end

    $display("=== LPW_expo precision test start ===");
    $display("Format: data_real max_real golden_real");

    while (!$feof(vec_fd)) begin
        scan_count = $fscanf(vec_fd, "%f %f %f\n", data_real, max_real, golden_real);
        if (scan_count == 3) begin
            data_in = real_to_q24(data_real);
            max     = real_to_q24(max_real);
            #1;

            dut_real = q16_to_real(result);
            signed_err = dut_real - golden_real;
            abs_err    = signed_err;
            if (abs_err < 0.0)
                abs_err = -abs_err;

            if (golden_real != 0.0) begin
                rel_err = abs_err / golden_real;
                if (rel_err < 0.0)
                    rel_err = -rel_err;
            end
            else begin
                rel_err = 0.0;
            end

            if (abs_err > max_abs_err)
                max_abs_err = abs_err;
            if (rel_err > max_rel_err)
                max_rel_err = rel_err;
            sum_abs_err = sum_abs_err + abs_err;
            sum_sq_err  = sum_sq_err + signed_err * signed_err;

            case_count = case_count + 1;
            $display("case=%0d data=%0.8f max=%0.8f dut=%0.8f golden=%0.8f loss=%0.8f abs_loss=%0.8f rel_loss=%0.8f",
                     case_count, data_real, max_real, dut_real, golden_real, signed_err, abs_err, rel_err);
        end
    end

    $fclose(vec_fd);

    if (case_count > 0) begin
        mae = sum_abs_err / case_count;
        mse = sum_sq_err / case_count;
    end
    else begin
        mae = 0.0;
        mse = 0.0;
    end

    $display("=== LPW_expo precision test done ===");
    $display("Total cases : %0d", case_count);
    $display("MAE         : %0.8f", mae);
    $display("MSE         : %0.8f", mse);
    $display("Max abs err : %0.8f", max_abs_err);
    $display("Max rel err : %0.8f", max_rel_err);

    $finish;
end

endmodule

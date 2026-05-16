module tb_LPW_reciprocal;

reg  [27:0] data_in;     // UQ12.16
wire [16:0] result;      // Q1.16
wire [16:0] const_result; // Q1.16

LPW_reciprocal dut (
    .data_in(data_in),
    .result (result)
);

constant_estimation_reciprocal const_dut (
    .data_in(data_in),
    .result (const_result)
);

integer vec_fd;
integer scan_count;
integer case_count;
integer exp_shift_dbg;
integer const_exp_shift_dbg;
integer u_dbg;
integer const_u_dbg;
integer recip_u_dbg;
integer const_recip_u_dbg;
integer result_q16_dbg;
integer const_result_q16_dbg;

real data_real;
real result_real;
real const_result_real;
real golden_real;
real loss_real;
real const_loss_real;
real abs_loss_real;
real const_abs_loss_real;
real loss_pct;
real const_loss_pct;
real u_real;
real const_u_real;
real recip_u_real;
real const_recip_u_real;
real sum_loss_pct;
real const_sum_loss_pct;
real mean_loss_pct;
real const_mean_loss_pct;
real max_loss_pct;
real const_max_loss_pct;
real max_abs_loss_real;
real const_max_abs_loss_real;

function real q16_to_real;
    input [16:0] value;
    begin
        q16_to_real = value / 65536.0;
    end
endfunction

function real uq16_to_real;
    input [27:0] value;
    begin
        uq16_to_real = value / 65536.0;
    end
endfunction

initial begin
    data_in           = 28'd0;
    golden_real       = 0.0;
    case_count        = 0;
    max_abs_loss_real = 0.0;
    const_max_abs_loss_real = 0.0;
    sum_loss_pct      = 0.0;
    const_sum_loss_pct = 0.0;
    mean_loss_pct     = 0.0;
    const_mean_loss_pct = 0.0;
    max_loss_pct      = 0.0;
    const_max_loss_pct = 0.0;

    vec_fd = $fopen("testbench/testcase/lpw_reciprocal_vectors.txt", "r");
    if (vec_fd == 0)
        vec_fd = $fopen("testcase/lpw_reciprocal_vectors.txt", "r");
    if (vec_fd == 0) begin
        $display("ERROR: cannot open lpw_reciprocal_vectors.txt in testbench/testcase or testcase");
        $display("Each line should be: <data_in_uq12.16_hex> <golden_real>");
        $finish;
    end

    $display("=== LPW_reciprocal precision test start ===");
    $display("Format: data_in_uq12.16_hex golden_real");

    while (!$feof(vec_fd)) begin
        scan_count = $fscanf(vec_fd, "%h %f\n", data_in, golden_real);
        if (scan_count == 2) begin
            #1;

            data_real     = uq16_to_real(data_in);
            result_real   = q16_to_real(result);
            const_result_real = q16_to_real(const_result);
            result_q16_dbg = result;
            const_result_q16_dbg = const_result;
            loss_real     = result_real - golden_real;
            const_loss_real = const_result_real - golden_real;
            abs_loss_real = loss_real;
            const_abs_loss_real = const_loss_real;
            if (abs_loss_real < 0.0)
                abs_loss_real = -abs_loss_real;
            if (const_abs_loss_real < 0.0)
                const_abs_loss_real = -const_abs_loss_real;
            exp_shift_dbg = dut.exp_shift;
            const_exp_shift_dbg = const_dut.exp_shift;
            u_dbg         = dut.u_q16;
            const_u_dbg   = const_dut.u_q16;
            recip_u_dbg   = dut.recip_u_q16;
            const_recip_u_dbg = const_dut.recip_u_q16;
            u_real        = u_dbg / 65536.0;
            const_u_real  = const_u_dbg / 65536.0;
            recip_u_real  = recip_u_dbg / 65536.0;
            const_recip_u_real = const_recip_u_dbg / 65536.0;

            if (golden_real != 0.0)
                loss_pct = (abs_loss_real / golden_real) * 100.0;
            else
                loss_pct = 0.0;
            if (golden_real != 0.0)
                const_loss_pct = (const_abs_loss_real / golden_real) * 100.0;
            else
                const_loss_pct = 0.0;

            if (abs_loss_real > max_abs_loss_real)
                max_abs_loss_real = abs_loss_real;
            if (const_abs_loss_real > const_max_abs_loss_real)
                const_max_abs_loss_real = const_abs_loss_real;
            if (loss_pct > max_loss_pct)
                max_loss_pct = loss_pct;
            if (const_loss_pct > const_max_loss_pct)
                const_max_loss_pct = const_loss_pct;
            sum_loss_pct = sum_loss_pct + loss_pct;
            const_sum_loss_pct = const_sum_loss_pct + const_loss_pct;

            case_count = case_count + 1;
            $display("LPW_PREC case=%0d data=%0.8f result=%0.8f golden=%0.8f loss=%0.8f abs_loss=%0.8f loss_pct=%0.4f%%",
                     case_count, data_real, result_real, golden_real, loss_real, abs_loss_real, loss_pct);
            $display("LPW_DEBUG case=%0d exp_shift=%0d u=%0.8f seg=%0d recip_u=%0.8f result_q16=%0d",
                     case_count, exp_shift_dbg, u_real, dut.u_q16[15:13], recip_u_real, result_q16_dbg);
            $display("CONST_PREC case=%0d data=%0.8f result=%0.8f golden=%0.8f loss=%0.8f abs_loss=%0.8f loss_pct=%0.4f%%",
                     case_count, data_real, const_result_real, golden_real, const_loss_real, const_abs_loss_real, const_loss_pct);
            $display("CONST_DEBUG case=%0d exp_shift=%0d u=%0.8f seg=%0d recip_u=%0.8f result_q16=%0d",
                     case_count, const_exp_shift_dbg, const_u_real, const_dut.frac_seg, const_recip_u_real, const_result_q16_dbg);
        end
    end

    $fclose(vec_fd);

    if (case_count > 0) begin
        mean_loss_pct = sum_loss_pct / case_count;
        const_mean_loss_pct = const_sum_loss_pct / case_count;
    end

    $display("=== LPW_reciprocal precision test done ===");
    $display("Total cases : %0d", case_count);
    $display("LPW mean loss %% : %0.4f%%", mean_loss_pct);
    $display("LPW max loss %%  : %0.4f%%", max_loss_pct);
    $display("LPW max abs loss: %0.8f", max_abs_loss_real);
    $display("CONST mean loss %% : %0.4f%%", const_mean_loss_pct);
    $display("CONST max loss %%  : %0.4f%%", const_max_loss_pct);
    $display("CONST max abs loss: %0.8f", const_max_abs_loss_real);

    $finish;
end

endmodule

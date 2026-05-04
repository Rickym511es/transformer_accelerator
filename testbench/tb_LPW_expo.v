module tb_LPW_expo;

reg  signed [39:0] data_in;    // Q16.24
reg  signed [39:0] max;        // Q16.24
reg         [16:0] golden_q16; // Q1.16
wire        [16:0] result;     // Q1.16
wire        [16:0] const_result; // Q1.16

LPW_expo dut (
    .data_in(data_in),
    .max    (max),
    .result (result)
);

constant_estimation_expo const_dut (
    .data_in(data_in),
    .max    (max),
    .result (const_result)
);

integer vec_fd;
integer scan_count;
integer case_count;
integer result_int;
integer const_result_int;
integer golden_int;
integer loss_q16;
integer const_loss_q16;
integer abs_loss_q16;
integer const_abs_loss_q16;
integer max_abs_loss_q16;
integer const_max_abs_loss_q16;
integer i_dbg;
integer shift_dbg;
integer diff_dbg;
integer f_dbg;
integer exp_frac_dbg;
integer const_i_dbg;
integer const_shift_dbg;
integer const_exp_frac_dbg;

real loss_real;
real const_loss_real;
real abs_loss_real;
real const_abs_loss_real;
real max_abs_loss_real;
real const_max_abs_loss_real;
real sum_abs_loss_real;
real const_sum_abs_loss_real;
real sum_sq_loss_real;
real const_sum_sq_loss_real;
real result_real;
real const_result_real;
real golden_real;
real diff_real;
real f_real;
real exp_frac_real;
real const_exp_frac_real;
real loss_pct;
real const_loss_pct;
real sum_loss_pct;
real const_sum_loss_pct;
real mean_loss_pct;
real const_mean_loss_pct;
real max_loss_pct;
real const_max_loss_pct;

function real q16_to_real;
    input [16:0] value;
    begin
        q16_to_real = value / 65536.0;
    end
endfunction

function real loss_q16_to_real;
    input integer value;
    begin
        loss_q16_to_real = value / 65536.0;
    end
endfunction

initial begin
    data_in           = 40'sd0;
    max               = 40'sd0;
    golden_q16        = 17'd0;
    case_count        = 0;
    max_abs_loss_q16  = 0;
    const_max_abs_loss_q16 = 0;
    max_abs_loss_real = 0.0;
    const_max_abs_loss_real = 0.0;
    sum_abs_loss_real = 0.0;
    const_sum_abs_loss_real = 0.0;
    sum_sq_loss_real  = 0.0;
    const_sum_sq_loss_real  = 0.0;
    sum_loss_pct      = 0.0;
    const_sum_loss_pct = 0.0;
    mean_loss_pct     = 0.0;
    const_mean_loss_pct = 0.0;
    max_loss_pct      = 0.0;
    const_max_loss_pct = 0.0;

    vec_fd = $fopen("testbench/testcase/lpw_expo_vectors.txt", "r");
    if (vec_fd == 0)
        vec_fd = $fopen("testcase/lpw_expo_vectors.txt", "r");
    if (vec_fd == 0) begin
        $display("ERROR: cannot open lpw_expo_vectors.txt in testbench/testcase or testcase");
        $display("Each line should be: <data_in_q16.24_hex> <max_q16.24_hex> <golden_q1.16_hex>");
        $finish;
    end

    $display("=== LPW_expo precision test start ===");
    $display("Format: data_in_q16.24_hex max_q16.24_hex golden_q1.16_hex");

    while (!$feof(vec_fd)) begin
        scan_count = $fscanf(vec_fd, "%h %h %h\n", data_in, max, golden_q16);
        if (scan_count == 3) begin
            #1;

            result_int   = result;
            const_result_int = const_result;
            golden_int   = golden_q16;
            loss_q16     = result_int - golden_int;
            const_loss_q16 = const_result_int - golden_int;
            abs_loss_q16 = loss_q16;
            const_abs_loss_q16 = const_loss_q16;
            if (abs_loss_q16 < 0)
                abs_loss_q16 = -abs_loss_q16;
            if (const_abs_loss_q16 < 0)
                const_abs_loss_q16 = -const_abs_loss_q16;

            loss_real     = loss_q16_to_real(loss_q16);
            const_loss_real = loss_q16_to_real(const_loss_q16);
            abs_loss_real = loss_q16_to_real(abs_loss_q16);
            const_abs_loss_real = loss_q16_to_real(const_abs_loss_q16);
            i_dbg         = dut.I;
            const_i_dbg   = const_dut.I;
            diff_dbg      = dut.diff;
            f_dbg         = dut.F;
            exp_frac_dbg  = dut.exp_frac;
            const_exp_frac_dbg = const_dut.exp_frac;
            shift_dbg     = dut.shift_amt;
            const_shift_dbg = const_dut.shift_amt;
            result_real   = q16_to_real(result);
            const_result_real = q16_to_real(const_result);
            golden_real   = q16_to_real(golden_q16);
            diff_real     = diff_dbg / 16777216.0;
            f_real        = f_dbg / 16777216.0;
            exp_frac_real = exp_frac_dbg / 65536.0;
            const_exp_frac_real = const_exp_frac_dbg / 65536.0;
            if (golden_real != 0.0)
                loss_pct = (abs_loss_real / golden_real) * 100.0;
            else
                loss_pct = 0.0;
            if (golden_real != 0.0)
                const_loss_pct = (const_abs_loss_real / golden_real) * 100.0;
            else
                const_loss_pct = 0.0;

            if (abs_loss_q16 > max_abs_loss_q16)
                max_abs_loss_q16 = abs_loss_q16;
            if (const_abs_loss_q16 > const_max_abs_loss_q16)
                const_max_abs_loss_q16 = const_abs_loss_q16;
            if (abs_loss_real > max_abs_loss_real)
                max_abs_loss_real = abs_loss_real;
            if (const_abs_loss_real > const_max_abs_loss_real)
                const_max_abs_loss_real = const_abs_loss_real;
            if (loss_pct > max_loss_pct)
                max_loss_pct = loss_pct;
            if (const_loss_pct > const_max_loss_pct)
                const_max_loss_pct = const_loss_pct;
            sum_abs_loss_real = sum_abs_loss_real + abs_loss_real;
            const_sum_abs_loss_real = const_sum_abs_loss_real + const_abs_loss_real;
            sum_sq_loss_real  = sum_sq_loss_real + loss_real * loss_real;
            const_sum_sq_loss_real = const_sum_sq_loss_real + const_loss_real * const_loss_real;
            sum_loss_pct      = sum_loss_pct + loss_pct;
            const_sum_loss_pct = const_sum_loss_pct + const_loss_pct;

            case_count = case_count + 1;
            $display("LPW_PREC case=%0d data=%0.8f max=%0.8f result=%0.8f golden=%0.8f loss=%0.8f abs_loss=%0.8f loss_pct=%0.4f%%",
                     case_count, data_in / 16777216.0, max / 16777216.0, result_real, golden_real, loss_real, abs_loss_real, loss_pct);
            $display("LPW_DEBUG case=%0d diff=%0.8f I=%0d F=%0.8f seg=%0d exp_frac=%0.8f shift=%0d loss_q16=%0d",
                     case_count, diff_real, i_dbg, f_real, dut.F[23:21], exp_frac_real, shift_dbg, loss_q16);
            $display("CONST_PREC case=%0d data=%0.8f max=%0.8f result=%0.8f golden=%0.8f loss=%0.8f abs_loss=%0.8f loss_pct=%0.4f%%",
                     case_count, data_in / 16777216.0, max / 16777216.0, const_result_real, golden_real, const_loss_real, const_abs_loss_real, const_loss_pct);
            $display("CONST_DEBUG case=%0d diff=%0.8f I=%0d F=%0.8f seg=%0d exp_frac=%0.8f shift=%0d loss_q16=%0d",
                     case_count, diff_real, const_i_dbg, f_real, const_dut.frac_seg, const_exp_frac_real, const_shift_dbg, const_loss_q16);
        end
    end

    $fclose(vec_fd);

    if (case_count > 0) begin
        mean_loss_pct = sum_loss_pct / case_count;
        const_mean_loss_pct = const_sum_loss_pct / case_count;
    end

    $display("=== LPW_expo precision test done ===");
    $display("Total cases : %0d", case_count);
    $display("LPW mean loss %% : %0.4f%%", mean_loss_pct);
    $display("LPW max loss %%  : %0.4f%%", max_loss_pct);
    $display("LPW max abs loss: %0d LSB (%0.8f)", max_abs_loss_q16, max_abs_loss_real);
    $display("CONST mean loss %% : %0.4f%%", const_mean_loss_pct);
    $display("CONST max loss %%  : %0.4f%%", const_max_loss_pct);
    $display("CONST max abs loss: %0d LSB (%0.8f)", const_max_abs_loss_q16, const_max_abs_loss_real);

    $finish;
end

endmodule

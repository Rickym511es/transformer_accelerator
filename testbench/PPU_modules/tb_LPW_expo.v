module tb_LPW_expo;

parameter TOP_LPW_CASES = 10;
parameter MIN_PCT_GOLDEN_Q16 = 2;

reg  signed [39:0] data_in;    // Q24.16
reg  signed [39:0] max;        // Q24.16
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
integer top_idx;
integer top_slot;
integer top_shift_idx;
integer pct_case_count;
integer pct_skip_count;

integer top_case_id [0:TOP_LPW_CASES-1];
integer top_result_q16 [0:TOP_LPW_CASES-1];
integer top_golden_q16 [0:TOP_LPW_CASES-1];
integer top_loss_q16 [0:TOP_LPW_CASES-1];
integer top_abs_loss_q16 [0:TOP_LPW_CASES-1];
integer top_i_dbg [0:TOP_LPW_CASES-1];
integer top_shift_dbg [0:TOP_LPW_CASES-1];
reg signed [39:0] top_data_q [0:TOP_LPW_CASES-1];
reg signed [39:0] top_max_q [0:TOP_LPW_CASES-1];
reg signed [39:0] top_diff_q [0:TOP_LPW_CASES-1];
reg        [15:0] top_f_q [0:TOP_LPW_CASES-1];
reg        [17:0] top_exp_frac_q [0:TOP_LPW_CASES-1];
reg         [2:0] top_seg [0:TOP_LPW_CASES-1];

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
real top_loss_pct [0:TOP_LPW_CASES-1];

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
    pct_case_count    = 0;
    pct_skip_count    = 0;
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
    for (top_idx = 0; top_idx < TOP_LPW_CASES; top_idx = top_idx + 1) begin
        top_case_id[top_idx] = 0;
        top_result_q16[top_idx] = 0;
        top_golden_q16[top_idx] = 0;
        top_loss_q16[top_idx] = 0;
        top_abs_loss_q16[top_idx] = -1;
        top_i_dbg[top_idx] = 0;
        top_shift_dbg[top_idx] = 0;
        top_data_q[top_idx] = 40'sd0;
        top_max_q[top_idx] = 40'sd0;
        top_diff_q[top_idx] = 40'sd0;
        top_f_q[top_idx] = 16'd0;
        top_exp_frac_q[top_idx] = 18'd0;
        top_seg[top_idx] = 3'd0;
        top_loss_pct[top_idx] = 0.0;
    end

    vec_fd = $fopen("testbench/testcase/lpw_expo_vectors.txt", "r");
    if (vec_fd == 0)
        vec_fd = $fopen("testcase/lpw_expo_vectors.txt", "r");
    if (vec_fd == 0) begin
        $display("ERROR: cannot open lpw_expo_vectors.txt in testbench/testcase or testcase");
        $display("Each line should be: <data_in_q24.16_hex> <max_q24.16_hex> <golden_q1.16_hex>");
        $finish;
    end

    $display("=== LPW_expo precision test start ===");
    $display("Format: data_in_q24.16_hex max_q24.16_hex golden_q1.16_hex");

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
            diff_real     = diff_dbg / 65536.0;
            f_real        = f_dbg / 65536.0;
            exp_frac_real = exp_frac_dbg / 65536.0;
            const_exp_frac_real = const_exp_frac_dbg / 65536.0;
            if (golden_int >= MIN_PCT_GOLDEN_Q16)
                loss_pct = (abs_loss_real / golden_real) * 100.0;
            else
                loss_pct = 0.0;
            if (golden_int >= MIN_PCT_GOLDEN_Q16)
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
            sum_abs_loss_real = sum_abs_loss_real + abs_loss_real;
            const_sum_abs_loss_real = const_sum_abs_loss_real + const_abs_loss_real;
            sum_sq_loss_real  = sum_sq_loss_real + loss_real * loss_real;
            const_sum_sq_loss_real = const_sum_sq_loss_real + const_loss_real * const_loss_real;

            case_count = case_count + 1;

            if (golden_int >= MIN_PCT_GOLDEN_Q16) begin
                pct_case_count = pct_case_count + 1;
                if (loss_pct > max_loss_pct)
                    max_loss_pct = loss_pct;
                if (const_loss_pct > const_max_loss_pct)
                    const_max_loss_pct = const_loss_pct;
                sum_loss_pct      = sum_loss_pct + loss_pct;
                const_sum_loss_pct = const_sum_loss_pct + const_loss_pct;

                top_slot = -1;
                for (top_idx = 0; top_idx < TOP_LPW_CASES; top_idx = top_idx + 1) begin
                    if ((top_slot < 0) && ((top_case_id[top_idx] == 0) || (loss_pct > top_loss_pct[top_idx])))
                        top_slot = top_idx;
                end

                if (top_slot >= 0) begin
                    for (top_shift_idx = TOP_LPW_CASES - 1; top_shift_idx > top_slot; top_shift_idx = top_shift_idx - 1) begin
                        top_case_id[top_shift_idx] = top_case_id[top_shift_idx - 1];
                        top_result_q16[top_shift_idx] = top_result_q16[top_shift_idx - 1];
                        top_golden_q16[top_shift_idx] = top_golden_q16[top_shift_idx - 1];
                        top_loss_q16[top_shift_idx] = top_loss_q16[top_shift_idx - 1];
                        top_abs_loss_q16[top_shift_idx] = top_abs_loss_q16[top_shift_idx - 1];
                        top_i_dbg[top_shift_idx] = top_i_dbg[top_shift_idx - 1];
                        top_shift_dbg[top_shift_idx] = top_shift_dbg[top_shift_idx - 1];
                        top_data_q[top_shift_idx] = top_data_q[top_shift_idx - 1];
                        top_max_q[top_shift_idx] = top_max_q[top_shift_idx - 1];
                        top_diff_q[top_shift_idx] = top_diff_q[top_shift_idx - 1];
                        top_f_q[top_shift_idx] = top_f_q[top_shift_idx - 1];
                        top_exp_frac_q[top_shift_idx] = top_exp_frac_q[top_shift_idx - 1];
                        top_seg[top_shift_idx] = top_seg[top_shift_idx - 1];
                        top_loss_pct[top_shift_idx] = top_loss_pct[top_shift_idx - 1];
                    end

                    top_case_id[top_slot] = case_count;
                    top_result_q16[top_slot] = result_int;
                    top_golden_q16[top_slot] = golden_int;
                    top_loss_q16[top_slot] = loss_q16;
                    top_abs_loss_q16[top_slot] = abs_loss_q16;
                    top_i_dbg[top_slot] = i_dbg;
                    top_shift_dbg[top_slot] = shift_dbg;
                    top_data_q[top_slot] = data_in;
                    top_max_q[top_slot] = max;
                    top_diff_q[top_slot] = dut.diff;
                    top_f_q[top_slot] = dut.F;
                    top_exp_frac_q[top_slot] = dut.exp_frac;
                    top_seg[top_slot] = dut.F[15:13];
                    top_loss_pct[top_slot] = loss_pct;
                end
            end
            else begin
                pct_skip_count = pct_skip_count + 1;
            end
        end
    end

    $fclose(vec_fd);

    if (pct_case_count > 0) begin
        mean_loss_pct = sum_loss_pct / pct_case_count;
        const_mean_loss_pct = const_sum_loss_pct / pct_case_count;
    end

    $display("=== LPW_expo precision test done ===");
    $display("Total cases : %0d", case_count);
    $display("Pct cases   : %0d (golden >= %0d LSB), skipped tiny golden: %0d",
             pct_case_count, MIN_PCT_GOLDEN_Q16, pct_skip_count);
    $display("LPW mean loss %% : %0.4f%%", mean_loss_pct);
    $display("LPW max loss %%  : %0.4f%%", max_loss_pct);
    $display("LPW max abs loss: %0d LSB (%0.8f)", max_abs_loss_q16, max_abs_loss_real);
    $display("CONST mean loss %% : %0.4f%%", const_mean_loss_pct);
    $display("CONST max loss %%  : %0.4f%%", const_max_loss_pct);
    $display("CONST max abs loss: %0d LSB (%0.8f)", const_max_abs_loss_q16, const_max_abs_loss_real);
    $display("Top %0d LPW segment-method cases by loss pct:", TOP_LPW_CASES);
    for (top_idx = 0; top_idx < TOP_LPW_CASES; top_idx = top_idx + 1) begin
        if (top_case_id[top_idx] != 0) begin
            $display("LPW_TOP rank=%0d case=%0d data=%010h max=%010h result=%05h golden=%05h loss=%0d LSB abs=%0d LSB loss_pct=%0.4f%%",
                     top_idx + 1, top_case_id[top_idx], top_data_q[top_idx], top_max_q[top_idx],
                     top_result_q16[top_idx], top_golden_q16[top_idx], top_loss_q16[top_idx],
                     top_abs_loss_q16[top_idx], top_loss_pct[top_idx]);
            $display("        data=%0.8f max=%0.8f diff=%0.8f I=%0d F=%0.8f seg=%0d exp_frac=%0.8f shift=%0d",
                     top_data_q[top_idx] / 65536.0, top_max_q[top_idx] / 65536.0,
                     top_diff_q[top_idx] / 65536.0, top_i_dbg[top_idx],
                     top_f_q[top_idx] / 65536.0, top_seg[top_idx],
                     top_exp_frac_q[top_idx] / 65536.0, top_shift_dbg[top_idx]);
        end
    end

    $finish;
end

endmodule

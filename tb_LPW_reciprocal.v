module tb_LPW_reciprocal;

reg  [27:0] data_in;     // UQ12.16
reg  [16:0] golden_q16;  // Q1.16
wire [16:0] result;      // Q1.16

LPW_reciprocal dut (
    .data_in(data_in),
    .result (result)
);

integer vec_fd;
integer scan_count;
integer case_count;
integer result_int;
integer golden_int;
integer loss_q16;
integer abs_loss_q16;
integer max_abs_loss_q16;
integer exp_shift_dbg;
integer u_dbg;
integer recip_u_dbg;

real data_real;
real result_real;
real golden_real;
real loss_real;
real abs_loss_real;
real loss_pct;
real u_real;
real recip_u_real;
real sum_loss_pct;
real mean_loss_pct;
real max_loss_pct;
real max_abs_loss_real;

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

function real loss_q16_to_real;
    input integer value;
    begin
        loss_q16_to_real = value / 65536.0;
    end
endfunction

initial begin
    data_in           = 28'd0;
    golden_q16        = 17'd0;
    case_count        = 0;
    max_abs_loss_q16  = 0;
    max_abs_loss_real = 0.0;
    sum_loss_pct      = 0.0;
    mean_loss_pct     = 0.0;
    max_loss_pct      = 0.0;

    vec_fd = $fopen("lpw_reciprocal_vectors.txt", "r");
    if (vec_fd == 0) begin
        $display("ERROR: cannot open lpw_reciprocal_vectors.txt");
        $display("Each line should be: <data_in_uq12.16_hex> <golden_q1.16_hex>");
        $finish;
    end

    $display("=== LPW_reciprocal precision test start ===");
    $display("Format: data_in_uq12.16_hex golden_q1.16_hex");

    while (!$feof(vec_fd)) begin
        scan_count = $fscanf(vec_fd, "%h %h\n", data_in, golden_q16);
        if (scan_count == 2) begin
            #1;

            result_int   = result;
            golden_int   = golden_q16;
            loss_q16     = result_int - golden_int;
            abs_loss_q16 = loss_q16;
            if (abs_loss_q16 < 0)
                abs_loss_q16 = -abs_loss_q16;

            data_real     = uq16_to_real(data_in);
            result_real   = q16_to_real(result);
            golden_real   = q16_to_real(golden_q16);
            loss_real     = loss_q16_to_real(loss_q16);
            abs_loss_real = loss_q16_to_real(abs_loss_q16);
            exp_shift_dbg = dut.exp_shift;
            u_dbg         = dut.u_q16;
            recip_u_dbg   = dut.recip_u_q16;
            u_real        = u_dbg / 65536.0;
            recip_u_real  = recip_u_dbg / 65536.0;

            if (golden_real != 0.0)
                loss_pct = (abs_loss_real / golden_real) * 100.0;
            else
                loss_pct = 0.0;

            if (abs_loss_q16 > max_abs_loss_q16)
                max_abs_loss_q16 = abs_loss_q16;
            if (abs_loss_real > max_abs_loss_real)
                max_abs_loss_real = abs_loss_real;
            if (loss_pct > max_loss_pct)
                max_loss_pct = loss_pct;
            sum_loss_pct = sum_loss_pct + loss_pct;

            case_count = case_count + 1;
            $display("PREC case=%0d data=%0.8f result=%0.8f golden=%0.8f loss=%0.8f abs_loss=%0.8f loss_pct=%0.4f%%",
                     case_count, data_real, result_real, golden_real, loss_real, abs_loss_real, loss_pct);
            $display("DEBUG case=%0d exp_shift=%0d u=%0.8f seg=%0d recip_u=%0.8f loss_q16=%0d",
                     case_count, exp_shift_dbg, u_real, dut.u_q16[15:14], recip_u_real, loss_q16);
        end
    end

    $fclose(vec_fd);

    if (case_count > 0)
        mean_loss_pct = sum_loss_pct / case_count;

    $display("=== LPW_reciprocal precision test done ===");
    $display("Total cases : %0d", case_count);
    $display("Mean loss %% : %0.4f%%", mean_loss_pct);
    $display("Max loss %%  : %0.4f%%", max_loss_pct);
    $display("Max abs loss: %0d LSB (%0.8f)", max_abs_loss_q16, max_abs_loss_real);

    $finish;
end

endmodule

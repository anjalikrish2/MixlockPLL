// =============================================================================
// tb_dco_characterize : DCO characterization for a tamper-detection bounds-checker
//   Instantiates the DCO module standalone (same params as its real ADPLL
//   instantiation: RJ_SIGMA_PS=20, DET_JITTER_AMP_PS=10, DET_JITTER_PER_NS=50)
//   and measures:
//     1. Tuning range   - sweep all 129 thermometer-code control words (0..128
//                          ones), measure resulting frequency, report min/max.
//     2. Max slew rate  - force back-to-back code transitions (extremes + mid
//                          jumps + the worst single-LSB-step pair found in the
//                          sweep), measure real elapsed time vs. frequency delta.
//     3. Settling time  - after a code change, count cycles until the measured
//                          period is within 1% of the new nominal period and
//                          stays there for a short stability window.
//   Read-only characterization: DCO module itself is not modified.
// =============================================================================
`timescale 1ps/1ps
module tb_dco_characterize;
    reg          RESET;
    reg  [128:0] code;
    wire         OUT_CLK;
    wire [31:0]  jitter_out_ps;

    DCO #(.RJ_SIGMA_PS(20), .DET_JITTER_AMP_PS(10), .DET_JITTER_PER_NS(50)) u_dco (
        .RESET(RESET),
        .code0(code[0]), .code1(code[1]), .code2(code[2]), .code3(code[3]), .code4(code[4]), .code5(code[5]), .code6(code[6]), .code7(code[7]), .code8(code[8]), .code9(code[9]), .code10(code[10]), .code11(code[11]), .code12(code[12]), .code13(code[13]), .code14(code[14]), .code15(code[15]), .code16(code[16]), .code17(code[17]), .code18(code[18]), .code19(code[19]), .code20(code[20]), .code21(code[21]), .code22(code[22]), .code23(code[23]), .code24(code[24]), .code25(code[25]), .code26(code[26]), .code27(code[27]), .code28(code[28]), .code29(code[29]), .code30(code[30]), .code31(code[31]), .code32(code[32]), .code33(code[33]), .code34(code[34]), .code35(code[35]), .code36(code[36]), .code37(code[37]), .code38(code[38]), .code39(code[39]), .code40(code[40]), .code41(code[41]), .code42(code[42]), .code43(code[43]), .code44(code[44]), .code45(code[45]), .code46(code[46]), .code47(code[47]), .code48(code[48]), .code49(code[49]), .code50(code[50]), .code51(code[51]), .code52(code[52]), .code53(code[53]), .code54(code[54]), .code55(code[55]), .code56(code[56]), .code57(code[57]), .code58(code[58]), .code59(code[59]), .code60(code[60]), .code61(code[61]), .code62(code[62]), .code63(code[63]), .code64(code[64]), .code65(code[65]), .code66(code[66]), .code67(code[67]), .code68(code[68]), .code69(code[69]), .code70(code[70]), .code71(code[71]), .code72(code[72]), .code73(code[73]), .code74(code[74]), .code75(code[75]), .code76(code[76]), .code77(code[77]), .code78(code[78]), .code79(code[79]), .code80(code[80]), .code81(code[81]), .code82(code[82]), .code83(code[83]), .code84(code[84]), .code85(code[85]), .code86(code[86]), .code87(code[87]), .code88(code[88]), .code89(code[89]), .code90(code[90]), .code91(code[91]), .code92(code[92]), .code93(code[93]), .code94(code[94]), .code95(code[95]), .code96(code[96]), .code97(code[97]), .code98(code[98]), .code99(code[99]), .code100(code[100]), .code101(code[101]), .code102(code[102]), .code103(code[103]), .code104(code[104]), .code105(code[105]), .code106(code[106]), .code107(code[107]), .code108(code[108]), .code109(code[109]), .code110(code[110]), .code111(code[111]), .code112(code[112]), .code113(code[113]), .code114(code[114]), .code115(code[115]), .code116(code[116]), .code117(code[117]), .code118(code[118]), .code119(code[119]), .code120(code[120]), .code121(code[121]), .code122(code[122]), .code123(code[123]), .code124(code[124]), .code125(code[125]), .code126(code[126]), .code127(code[127]), .code128(code[128]),
        .OUT_CLK(OUT_CLK), .jitter_out_ps(jitter_out_ps));

    // Thermometer code word N (0..128): bits [N-1:0] = 1, rest = 0
    task set_code;
        input integer n;
        integer k;
        begin
            for (k = 0; k < 129; k = k + 1)
                code[k] = (k < n) ? 1'b1 : 1'b0;
        end
    endtask

    // Average frequency (MHz) over n_periods consecutive posedge-to-posedge intervals
    task measure_avg_freq_mhz;
        output real freq_mhz;
        input integer n_periods;
        real t0, t1;
        integer k;
        begin
            @(posedge OUT_CLK); t0 = $realtime;
            for (k = 0; k < n_periods; k = k + 1) @(posedge OUT_CLK);
            t1 = $realtime;
            freq_mhz = (n_periods * 1.0e6) / (t1 - t0);
        end
    endtask

    real    freq_mhz_arr      [0:128];
    integer nominal_period_ps [0:128];
    integer i;
    real    min_freq, max_freq, f;
    integer min_code, max_code;

    initial begin
        RESET = 1; code = 129'd0;
        #10 RESET = 0;
        repeat (5) @(posedge OUT_CLK);

        // ══════════════════════════════════════════════════════════════
        // SECTION 1: Tuning range sweep
        // ══════════════════════════════════════════════════════════════
        $display("=== SECTION 1: Tuning range sweep (129 thermometer codes) ===");
        for (i = 0; i <= 128; i = i + 1) begin
            set_code(i);
            nominal_period_ps[i] = u_dco.period_ps;   // combinational, jitter-free
            repeat (3) @(posedge OUT_CLK);             // let transition settle + margin
            measure_avg_freq_mhz(f, 15);               // avg over 15 cycles, averages out jitter
            freq_mhz_arr[i] = f;
            $display("  code=%0d  nominal_period_ps=%0d  measured_freq=%.3f MHz", i, nominal_period_ps[i], f);
        end

        min_freq = freq_mhz_arr[0]; min_code = 0;
        max_freq = freq_mhz_arr[0]; max_code = 0;
        for (i = 1; i <= 128; i = i + 1) begin
            if (freq_mhz_arr[i] < min_freq) begin min_freq = freq_mhz_arr[i]; min_code = i; end
            if (freq_mhz_arr[i] > max_freq) begin max_freq = freq_mhz_arr[i]; max_code = i; end
        end
        $display("--- TUNING RANGE: MIN = %.3f MHz @ code=%0d  |  MAX = %.3f MHz @ code=%0d  |  span = %.3f MHz ---",
                  min_freq, min_code, max_freq, max_code, max_freq - min_freq);

        // ══════════════════════════════════════════════════════════════
        // SECTION 2: Max slew rate (forced transitions)
        // ══════════════════════════════════════════════════════════════
        $display("\n=== SECTION 2: Max slew rate (forced control-word transitions) ===");
        begin : slew
            integer from_c, to_c, worst_step, k2;
            real worst_delta;
            worst_delta = 0.0; worst_step = 0;
            for (k2 = 0; k2 < 128; k2 = k2 + 1) begin
                if ((freq_mhz_arr[k2+1] - freq_mhz_arr[k2]) > worst_delta ||
                    (freq_mhz_arr[k2] - freq_mhz_arr[k2+1]) > worst_delta) begin
                    worst_delta = (freq_mhz_arr[k2+1] > freq_mhz_arr[k2]) ?
                                  (freq_mhz_arr[k2+1] - freq_mhz_arr[k2]) : (freq_mhz_arr[k2] - freq_mhz_arr[k2+1]);
                    worst_step = k2;
                end
            end
            $display("  Largest single-LSB-step frequency delta in sweep: %.3f MHz, between code %0d and %0d",
                      worst_delta, worst_step, worst_step+1);

            do_transition(0,   128);
            do_transition(128, 0);
            do_transition(32,  96);
            do_transition(96,  32);
            do_transition(10,  64);
            do_transition(64,  10);
            do_transition(worst_step, worst_step+1);
            do_transition(worst_step+1, worst_step);
        end

        // ══════════════════════════════════════════════════════════════
        // SECTION 3: Settling time
        // ══════════════════════════════════════════════════════════════
        $display("\n=== SECTION 3: Settling time (1%% tolerance) ===");
        settle_test(0,   128, 40);
        settle_test(128, 0,   40);
        settle_test(32,  96,  40);

        $display("\n=== DONE ===");
        $finish;
    end

    // ---- Task: force a code transition synced to a posedge, measure latency & slew ----
    task do_transition;
        input integer from_c, to_c;
        real f_old, t_change, t_mid, t_new, t_new2, half_latency, half_new_a, half_new_b, period_new, f_new_first, delta_f_mhz, slew_hz_per_ns;
        begin
            set_code(from_c);
            repeat (8) @(posedge OUT_CLK);
            measure_avg_freq_mhz(f_old, 10);

            @(posedge OUT_CLK);
            t_change = $realtime;
            set_code(to_c);                 // change code immediately after a posedge

            @(negedge OUT_CLK); t_mid  = $realtime; half_latency = t_mid - t_change;  // finishes in-flight OLD half period
            @(posedge OUT_CLK); t_new  = $realtime; half_new_a   = t_new  - t_mid;    // first half period at NEW code
            @(negedge OUT_CLK); t_new2 = $realtime; half_new_b   = t_new2 - t_new;    // second half, completes one full NEW period

            period_new  = half_new_a + half_new_b;
            f_new_first = 1.0e6 / period_new;   // MHz, from the first full period fully governed by the new code
            delta_f_mhz = f_new_first - f_old;
            slew_hz_per_ns = (delta_f_mhz * 1.0e6) / (half_latency / 1000.0);

            $display("  code %0d -> %0d : f_old=%.3f MHz, f_new(first full period)=%.3f MHz, delta=%.3f MHz, latency_to_effect=%.1f ps, slew=%.3e Hz/ns",
                      from_c, to_c, f_old, f_new_first, delta_f_mhz, half_latency, slew_hz_per_ns);
        end
    endtask

    // ---- Task: measure settling time in cycles after a code transition ----
    task settle_test;
        input integer from_c, to_c, max_cycles;
        real target_period, tol, period_arr[0:63];
        real t_prev, t_cur;
        integer c, first_hit, sustained_hit, w, all_ok;
        begin
            set_code(from_c);
            repeat (8) @(posedge OUT_CLK);
            target_period = nominal_period_ps[to_c] * 1.0;
            tol = target_period / 100.0;   // 1%

            @(posedge OUT_CLK);
            set_code(to_c);
            t_prev = $realtime;
            for (c = 0; c < max_cycles; c = c + 1) begin
                @(posedge OUT_CLK);
                t_cur = $realtime;
                period_arr[c] = t_cur - t_prev;
                t_prev = t_cur;
            end

            first_hit = -1;
            for (c = 0; c < max_cycles; c = c + 1)
                if (first_hit == -1 && (period_arr[c] >= target_period - tol) && (period_arr[c] <= target_period + tol))
                    first_hit = c + 1;

            sustained_hit = -1;
            for (c = 0; c <= max_cycles - 5; c = c + 1) begin
                if (sustained_hit == -1) begin
                    all_ok = 1;
                    for (w = 0; w < 5; w = w + 1)
                        if (!((period_arr[c+w] >= target_period - tol) && (period_arr[c+w] <= target_period + tol)))
                            all_ok = 0;
                    if (all_ok) sustained_hit = c + 1;
                end
            end

            $write("  code %0d -> %0d : target_period=%.1f ps (tol=+-%.2f ps) : first single-cycle within 1%% = ",
                      from_c, to_c, target_period, tol);
            if (first_hit == -1) $write("NEVER in window"); else $write("cycle %0d", first_hit);
            $write(", sustained (5-cycle window) within 1%% = ");
            if (sustained_hit == -1) $write("NEVER in window"); else $write("cycle %0d", sustained_hit);
            $display("");
        end
    endtask

endmodule

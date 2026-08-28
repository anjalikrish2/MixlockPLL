// =============================================================================
// tb_disorc_checker : validates disorc_checker's two independent fault flags
//
//   SCENARIO 1 — normal correct-key operation on the real mixlock_adpll_top:
//                expect digital_fault == 0 && analog_fault == 0
//   SCENARIO 2 — normal wrong-key operation (scan_enable trips DisORC's
//                sticky corrupt latch -> active_key=DUMMY_KEY -> wrong_key=1,
//                M_locked=(scramble%6)+2 in [2,7]):
//                expect digital_fault == 0 && analog_fault == 0
//                (M_locked in [2,7] is NOT a fault by design)
//   SCENARIO 3 — direct fault injection: force wrong_key=1 and M_locked=0/1
//                on a standalone disorc_checker (bypassing trll_locked_M
//                entirely, simulating fault injection on the divider input):
//                expect digital_fault -> 1, analog_fault stays 0
//   SCENARIO 4 — direct fault injection: drive the standalone checker's
//                OUT_CLK input at a frequency outside [171,1550] MHz:
//                expect analog_fault -> 1, digital_fault stays 0
//
// design_fixed2.v is not otherwise modified beyond the disorc_checker module.
// =============================================================================
`timescale 1ns/1ps
module tb_disorc_checker;

    // ══════════════════════════════════════════════════════════════════════
    // Clocks
    // ══════════════════════════════════════════════════════════════════════
    reg clk = 0;
    reg REF_CLK = 0;
    always #5 clk     = ~clk;       // 100 MHz digital / DisORC domain
    always #5 REF_CLK = ~REF_CLK;   // 100 MHz PLL reference

    // ══════════════════════════════════════════════════════════════════════
    // SCENARIOS 1 & 2 : real mixlock_adpll_top + disorc_checker wired to it
    // ══════════════════════════════════════════════════════════════════════
    reg        rst_n, chip_reset, enrol_mode, scan_enable, scan_in;
    reg  [2:0] M_prog;
    wire       OUT_CLK, LOCK, corrupt_flag, scan_out;
    wire [127:0] helper_data;
    wire [15:0]  key_diff_obs;
    wire [2:0]   M_locked_obs;
    wire [31:0]  jitter_out, jitter_out_ps;

    mixlock_adpll_top #(.SIM_SEED(32'hC001_C0DE)) u_dut (
        .clk(clk), .rst_n(rst_n), .chip_reset(chip_reset), .enrol_mode(enrol_mode),
        .scan_enable(scan_enable), .scan_in(scan_in), .scan_out(scan_out),
        .REF_CLK(REF_CLK), .M_prog(M_prog),
        .OUT_CLK(OUT_CLK), .LOCK(LOCK),
        .corrupt_flag(corrupt_flag), .helper_data(helper_data),
        .key_diff_obs(key_diff_obs), .M_locked_obs(M_locked_obs),
        .jitter_out(jitter_out), .jitter_out_ps(jitter_out_ps));

    wire wrong_key_dut = |key_diff_obs;
    wire digital_fault_normal, analog_fault_normal;

    disorc_checker #(.REF_CLK_FREQ_HZ(100_000_000), .WINDOW_REF_CYCLES(10)) u_chk_normal (
        .clk(clk), .rst_n(rst_n),
        .wrong_key(wrong_key_dut), .M_locked(M_locked_obs), .digital_fault(digital_fault_normal),
        .REF_CLK(REF_CLK), .OUT_CLK(OUT_CLK), .analog_fault(analog_fault_normal));

    // ══════════════════════════════════════════════════════════════════════
    // SCENARIOS 3 & 4 : standalone disorc_checker for direct fault injection
    // ══════════════════════════════════════════════════════════════════════
    reg        rst_n2;
    reg        wrong_key_f;
    reg  [2:0] M_locked_f;
    reg        REF_CLK2 = 0;
    reg        OUT_CLK_f = 0;
    real       out_clk_period_ns = 2.0;   // initialized so the OUT_CLK_f generator never sees a #0 delay
    wire       digital_fault_f, analog_fault_f;

    always #5 REF_CLK2 = ~REF_CLK2;             // 100 MHz reference, same as above
    always #(out_clk_period_ns / 2.0) OUT_CLK_f = ~OUT_CLK_f;  // controllable "DCO" stand-in

    disorc_checker #(.REF_CLK_FREQ_HZ(100_000_000), .WINDOW_REF_CYCLES(10)) u_chk_fault (
        .clk(clk), .rst_n(rst_n2),
        .wrong_key(wrong_key_f), .M_locked(M_locked_f), .digital_fault(digital_fault_f),
        .REF_CLK(REF_CLK2), .OUT_CLK(OUT_CLK_f), .analog_fault(analog_fault_f));

    task reset_fault_checker;
        begin
            rst_n2 = 0;
            wrong_key_f = 1'b0; M_locked_f = 3'd4;   // valid, non-faulting divider state
            out_clk_period_ns = 2.0;                  // 500 MHz -> comfortably in [171,1550] MHz
            #20 rst_n2 = 1;
            #20; // let synchronizers settle post-reset
        end
    endtask

    initial begin
        // ── init ──────────────────────────────────────────────────────────
        rst_n = 0; chip_reset = 0; enrol_mode = 0; scan_enable = 0; scan_in = 0; M_prog = 3'd4;
        #20 rst_n = 1;

        // ═══════════════════════════════════════════════════════════════
        // SCENARIO 1: normal correct-key operation
        // ═══════════════════════════════════════════════════════════════
        #1000; // let PUF settle + several REF_CLK measurement windows elapse
        $display("=== SCENARIO 1: normal correct-key operation ===");
        $display("  wrong_key=%b  M_locked_obs=%0d  OUT_CLK freq window ok? (see analog_fault)", wrong_key_dut, M_locked_obs);
        $display("  digital_fault=%b  analog_fault=%b  -> %s",
                  digital_fault_normal, analog_fault_normal,
                  (digital_fault_normal == 0 && analog_fault_normal == 0) ? "PASS (both low, as expected)" : "FAIL");

        // ═══════════════════════════════════════════════════════════════
        // SCENARIO 2: normal wrong-key operation (trip DisORC corrupt latch)
        // ═══════════════════════════════════════════════════════════════
        scan_enable = 1'b1;
        @(posedge clk); @(posedge clk);
        scan_enable = 1'b0;
        #1000; // let active_key/M_locked_obs settle + several more windows elapse
        $display("\n=== SCENARIO 2: normal wrong-key operation (scan_enable tripped) ===");
        $display("  corrupt_flag=%b  wrong_key=%b  M_locked_obs=%0d (expect in [2,7])", corrupt_flag, wrong_key_dut, M_locked_obs);
        $display("  digital_fault=%b  analog_fault=%b  -> %s",
                  digital_fault_normal, analog_fault_normal,
                  (digital_fault_normal == 0 && analog_fault_normal == 0 && M_locked_obs >= 2 && M_locked_obs <= 7)
                  ? "PASS (both low; M_locked in [2,7] correctly NOT flagged)" : "FAIL");

        // ═══════════════════════════════════════════════════════════════
        // SCENARIO 3: direct digital fault injection (bypass TRLL logic)
        // ═══════════════════════════════════════════════════════════════
        reset_fault_checker;
        #200;
        $display("\n=== SCENARIO 3: direct fault injection - force wrong_key=1, M_locked=0 ===");
        $display("  baseline before injection: digital_fault=%b analog_fault=%b", digital_fault_f, analog_fault_f);
        wrong_key_f = 1'b1;
        M_locked_f  = 3'd0;    // structurally impossible through real TRLL logic while wrong_key=1
        #200;
        M_locked_f = 3'd1;     // also try the other impossible value
        #200;
        $display("  after injection (M_locked forced 0 then 1, wrong_key=1):");
        $display("  digital_fault=%b  analog_fault=%b  -> %s",
                  digital_fault_f, analog_fault_f,
                  (digital_fault_f == 1'b1 && analog_fault_f == 1'b0)
                  ? "PASS (digital_fault asserted, analog_fault stayed independent/low)" : "FAIL");

        // ═══════════════════════════════════════════════════════════════
        // SCENARIO 4: direct analog fault injection (OUT_CLK out of range)
        // ═══════════════════════════════════════════════════════════════
        reset_fault_checker;
        #200;
        $display("\n=== SCENARIO 4a: force OUT_CLK to 50 MHz (below 171 MHz floor) ===");
        $display("  baseline before injection: digital_fault=%b analog_fault=%b", digital_fault_f, analog_fault_f);
        out_clk_period_ns = 20.0;  // 50 MHz -- below MIN_FREQ_HZ
        #800;
        $display("  after injection (OUT_CLK=50MHz, wrong_key/M_locked held valid):");
        $display("  digital_fault=%b  analog_fault=%b  -> %s",
                  digital_fault_f, analog_fault_f,
                  (analog_fault_f == 1'b1 && digital_fault_f == 1'b0)
                  ? "PASS (analog_fault asserted, digital_fault stayed independent/low)" : "FAIL");

        reset_fault_checker;
        #200;
        $display("\n=== SCENARIO 4b: force OUT_CLK to ~3.33 GHz (above 1550 MHz ceiling) ===");
        $display("  baseline before injection: digital_fault=%b analog_fault=%b", digital_fault_f, analog_fault_f);
        out_clk_period_ns = 0.3;  // ~3.33 GHz -- above MAX_FREQ_HZ
        #800;
        $display("  after injection (OUT_CLK=3.33GHz, wrong_key/M_locked held valid):");
        $display("  digital_fault=%b  analog_fault=%b  -> %s",
                  digital_fault_f, analog_fault_f,
                  (analog_fault_f == 1'b1 && digital_fault_f == 1'b0)
                  ? "PASS (analog_fault asserted, digital_fault stayed independent/low)" : "FAIL");

        $display("\n=== DONE ===");
        $finish;
    end

endmodule

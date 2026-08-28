// =============================================================================
// tb_bitstability : per-bit stability analysis for the ro_puf/fuzzy_extractor
//   Measurement only — no design files touched. Same enrollment sequence and
//   SIM_SEED as tb_ber30.v so it reproduces the identical enrolled reference,
//   then does 30 reconstruct reads and tallies, per raw-PUF bit position (0..127),
//   how many of the 30 reads differed from the enrolled value. Also sweeps
//   flip-count thresholds to show, for each candidate "stable set" (bits kept
//   at or below that threshold), how many bits remain and the worst-case
//   number of simultaneous errors within that kept set across the 30 reads.
// =============================================================================
`timescale 1ns/1ps
module tb_bitstability;
    localparam integer SIM_SEED  = 32'hC001_C0DE;
    localparam integer NUM_READS = 30;

    reg clk = 0;
    reg rst_n = 0;
    reg sample = 0;
    reg enrol = 0;
    reg reconstruct = 0;

    wire [127:0] puf_raw;
    wire         puf_valid;
    wire [127:0] helper_data;
    wire [15:0]  K_puf;
    wire         puf_ready;

    ro_puf #(.DEVICE_ID(32'hA5F3_1C2B), .CELLS(128), .NOISE_BITS(3), .SIM_SEED(SIM_SEED)) u_puf (
        .clk(clk), .rst_n(rst_n), .sample(sample), .puf_raw(puf_raw), .puf_valid(puf_valid));

    fuzzy_extractor u_fe (
        .clk(clk), .rst_n(rst_n), .enrol(enrol), .reconstruct(reconstruct),
        .puf_raw(puf_raw), .puf_valid(puf_valid),
        .helper_data(helper_data), .K_puf(K_puf), .puf_ready(puf_ready));

    always #5 clk = ~clk;

    reg [127:0] enrolled_helper;
    reg [127:0] diffs [0:NUM_READS-1];
    integer flip_count [0:127];
    integer i, b, r;

    task do_sample;
        begin
            @(posedge clk); sample = 1;
            @(posedge clk); sample = 0;
            wait (puf_valid == 1);
            @(posedge clk);
        end
    endtask

    task wait_done_and_idle;
        begin
            wait (puf_ready == 1);
            @(posedge clk);
            enrol = 0; reconstruct = 0;
            @(posedge clk);
        end
    endtask

    initial begin
        $display("=== Per-bit stability analysis (SIM_SEED=%0h, %0d reads) ===", SIM_SEED, NUM_READS);
        rst_n = 0; sample = 0; enrol = 0; reconstruct = 0;
        for (b = 0; b < 128; b = b + 1) flip_count[b] = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Enrollment: identical sequence/seed to tb_ber30.v -> same enrolled reference
        do_sample;
        enrol = 1;
        wait_done_and_idle;
        enrolled_helper = helper_data;
        $display("[ENROL] helper_data=%032h", enrolled_helper);

        for (i = 0; i < NUM_READS; i = i + 1) begin
            do_sample;
            diffs[i] = puf_raw ^ enrolled_helper;
            reconstruct = 1;
            wait_done_and_idle;
            for (b = 0; b < 128; b = b + 1)
                if (diffs[i][b]) flip_count[b] = flip_count[b] + 1;
        end

        $display("--- Per-bit flip counts over %0d reads (bit: count) ---", NUM_READS);
        for (b = 0; b < 128; b = b + 1)
            $display("bit[%0d] = %0d%s", b, flip_count[b], (flip_count[b] > 0) ? "  <-- noisy" : "");

        $display("--- Histogram: how many bits had exactly N flips ---");
        begin : hist
            integer n, cnt;
            for (n = 0; n <= NUM_READS; n = n + 1) begin
                cnt = 0;
                for (b = 0; b < 128; b = b + 1)
                    if (flip_count[b] == n) cnt = cnt + 1;
                if (cnt > 0)
                    $display("  flips=%0d : %0d bits", n, cnt);
            end
        end

        $display("--- Masking sweep: keep bits with flip_count <= T, worst-case simultaneous errors in kept set over %0d reads ---", NUM_READS);
        begin : sweep
            integer T, count_bits, worst, cur;
            reg [127:0] mask;
            for (T = 0; T <= NUM_READS; T = T + 1) begin
                mask = 128'd0; count_bits = 0;
                for (b = 0; b < 128; b = b + 1)
                    if (flip_count[b] <= T) begin mask[b] = 1'b1; count_bits = count_bits + 1; end
                worst = 0;
                for (r = 0; r < NUM_READS; r = r + 1) begin
                    cur = 0;
                    for (b = 0; b < 128; b = b + 1)
                        if (mask[b] && diffs[r][b]) cur = cur + 1;
                    if (cur > worst) worst = cur;
                end
                $display("  T<=%0d : kept=%0d bits (masked out=%0d), worst_case_simultaneous_errors=%0d",
                          T, count_bits, 128 - count_bits, worst);
                if (count_bits == 128) begin
                    // once every bit is included, higher T is redundant
                    T = NUM_READS + 1;
                end
            end
        end

        $finish;
    end
endmodule

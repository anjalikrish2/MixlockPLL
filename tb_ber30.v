// =============================================================================
// tb_ber30 : 30-read BER test for fuzzy_extractor RECO-state fix
//   Enrolls once against ro_puf (fixed SIM_SEED), then performs 30 independent
//   reconstruct reads. Reports:
//     - per-read Hamming distance between raw noisy PUF word and the
//       enrollment-time helper_data (pre-ECC noise)
//     - per-read K_puf match/mismatch against the enrolled K_puf (post-ECC)
//     - aggregate bit error rate on K_puf across all 30 reads
// =============================================================================
`timescale 1ns/1ps
module tb_ber30;
    localparam integer SIM_SEED = 32'hC001_C0DE;
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

    reg  [127:0] enrolled_helper;
    reg  [15:0]  enrolled_K;
    reg  [127:0] read_raw;
    integer      i, mismatches, hamm, total_bit_errors, total_reads_mismatched;

    task do_sample;
        begin
            @(posedge clk); sample = 1;
            @(posedge clk); sample = 0;
            wait (puf_valid == 1);
            @(posedge clk); // sample puf_raw/puf_valid on this edge
        end
    endtask

    task wait_done_and_idle(input do_enrol);
        begin
            // hold enrol/reconstruct high until puf_ready pulses (state -> DONE)
            wait (puf_ready == 1);
            @(posedge clk);
            enrol = 0; reconstruct = 0;
            @(posedge clk); // state DONE -> IDLE
        end
    endtask

    initial begin
        $display("=== fuzzy_extractor 30-read BER test (SIM_SEED=%0h) ===", SIM_SEED);
        rst_n = 0; sample = 0; enrol = 0; reconstruct = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- Enrollment ----
        do_sample;
        read_raw = puf_raw;
        enrol = 1;
        wait_done_and_idle(1);
        enrolled_helper = helper_data;
        enrolled_K      = K_puf;
        $display("[ENROL] raw=%032h  helper_data=%032h  K_puf=%04h", read_raw, enrolled_helper, enrolled_K);

        // ---- 30 reconstruct reads ----
        total_bit_errors = 0;
        total_reads_mismatched = 0;
        for (i = 0; i < NUM_READS; i = i + 1) begin
            do_sample;
            read_raw = puf_raw;
            hamm = 0;
            for (mismatches = 0; mismatches < 128; mismatches = mismatches + 1)
                if (read_raw[mismatches] !== enrolled_helper[mismatches]) hamm = hamm + 1;

            reconstruct = 1;
            wait_done_and_idle(0);

            mismatches = 0;
            begin : bitcount
                integer b;
                for (b = 0; b < 16; b = b + 1)
                    if (K_puf[b] !== enrolled_K[b]) mismatches = mismatches + 1;
            end
            total_bit_errors = total_bit_errors + mismatches;
            if (mismatches != 0) total_reads_mismatched = total_reads_mismatched + 1;

            $display("[READ %0d] raw_hamm_vs_enrolled=%0d  K_puf=%04h  key_bit_errors=%0d  %s",
                      i+1, hamm, K_puf, mismatches, (mismatches==0) ? "MATCH" : "MISMATCH");
        end

        $display("=== SUMMARY ===");
        $display("Reads with key mismatch : %0d / %0d", total_reads_mismatched, NUM_READS);
        $display("Total K_puf bit errors  : %0d / %0d bits", total_bit_errors, NUM_READS*16);
        $display("Bit Error Rate (K_puf)  : %0f %%", (100.0*total_bit_errors)/(NUM_READS*16));

        $finish;
    end
endmodule

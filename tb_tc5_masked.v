// =============================================================================
// tb_tc5_masked : TC5 PUF-uniqueness re-check with bit-masking in place.
//   Two independent ro_puf/fuzzy_extractor pairs (SIM_SEED=1, SIM_SEED=2),
//   each enrolled once. Reports:
//     - Hamming distance on K_puf (16-bit hash) -- same metric/threshold as
//       tbmixlock_vivado_.v's TC5 (PASS requires >= 6/16 bits, i.e. >=37.5%)
//     - Hamming distance on the masked 110-bit stable helper_data set, for
//       extra confirmation that uniqueness survives at the pre-hash level too.
// =============================================================================
`timescale 1ns/1ps
module tb_tc5_masked;
    reg clk = 0;
    reg rst_n = 0;

    // ---- Device 1 : SIM_SEED = 1 ----
    reg  sample1 = 0, enrol1 = 0;
    wire [127:0] puf_raw1;
    wire         puf_valid1;
    wire [127:0] helper_data1, mask_data1;
    wire [15:0]  K_puf1;
    wire         puf_ready1;

    ro_puf #(.DEVICE_ID(32'hA5F3_1C2B), .CELLS(128), .NOISE_BITS(3), .SIM_SEED(32'd1)) u_puf1 (
        .clk(clk), .rst_n(rst_n), .sample(sample1), .puf_raw(puf_raw1), .puf_valid(puf_valid1));
    fuzzy_extractor u_fe1 (
        .clk(clk), .rst_n(rst_n), .enrol(enrol1), .reconstruct(1'b0),
        .puf_raw(puf_raw1), .puf_valid(puf_valid1),
        .helper_data(helper_data1), .mask_data(mask_data1), .K_puf(K_puf1), .puf_ready(puf_ready1));

    // ---- Device 2 : SIM_SEED = 2 ----
    reg  sample2 = 0, enrol2 = 0;
    wire [127:0] puf_raw2;
    wire         puf_valid2;
    wire [127:0] helper_data2, mask_data2;
    wire [15:0]  K_puf2;
    wire         puf_ready2;

    ro_puf #(.DEVICE_ID(32'h1C2B_A5F3), .CELLS(128), .NOISE_BITS(3), .SIM_SEED(32'd2)) u_puf2 (
        .clk(clk), .rst_n(rst_n), .sample(sample2), .puf_raw(puf_raw2), .puf_valid(puf_valid2));
    fuzzy_extractor u_fe2 (
        .clk(clk), .rst_n(rst_n), .enrol(enrol2), .reconstruct(1'b0),
        .puf_raw(puf_raw2), .puf_valid(puf_valid2),
        .helper_data(helper_data2), .mask_data(mask_data2), .K_puf(K_puf2), .puf_ready(puf_ready2));

    always #5 clk = ~clk;

    task do_sample1; begin
        @(posedge clk); sample1 = 1;
        @(posedge clk); sample1 = 0;
        wait (puf_valid1 == 1);
        @(posedge clk);
    end endtask

    task do_sample2; begin
        @(posedge clk); sample2 = 1;
        @(posedge clk); sample2 = 0;
        wait (puf_valid2 == 1);
        @(posedge clk);
    end endtask

    integer hamming_k, hamming_stable, bit_i;
    reg [127:0] stable1, stable2;

    initial begin
        $display("=== TC5 re-check with masking (SIM_SEED=1 vs SIM_SEED=2) ===");
        rst_n = 0; sample1 = 0; sample2 = 0; enrol1 = 0; enrol2 = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Enroll device 1
        do_sample1;
        enrol1 = 1;
        wait (puf_ready1 == 1);
        @(posedge clk); enrol1 = 0;
        @(posedge clk);

        // Enroll device 2
        do_sample2;
        enrol2 = 1;
        wait (puf_ready2 == 1);
        @(posedge clk); enrol2 = 0;
        @(posedge clk);

        $display("  Device 1 (SIM_SEED=1): helper_data=%032h  mask_data=%032h  K_puf=0x%04h", helper_data1, mask_data1, K_puf1);
        $display("  Device 2 (SIM_SEED=2): helper_data=%032h  mask_data=%032h  K_puf=0x%04h", helper_data2, mask_data2, K_puf2);

        hamming_k = 0;
        for (bit_i = 0; bit_i < 16; bit_i = bit_i + 1)
            if (K_puf1[bit_i] !== K_puf2[bit_i]) hamming_k = hamming_k + 1;

        stable1 = helper_data1 & mask_data1;
        stable2 = helper_data2 & mask_data2;
        hamming_stable = 0;
        for (bit_i = 0; bit_i < 128; bit_i = bit_i + 1)
            if (stable1[bit_i] !== stable2[bit_i]) hamming_stable = hamming_stable + 1;

        $display("  Inter-device Hamming distance on K_puf         = %0d / 16 bits (%0d%%)",
                  hamming_k, (hamming_k * 100) / 16);
        $display("  Inter-device Hamming distance on masked-stable = %0d / 110 bits (%0d%%)",
                  hamming_stable, (hamming_stable * 100) / 110);

        if (hamming_k >= 6)
            $display("  TC5 PASS: K_puf HD >= 37.5%% (sufficient uniqueness)");
        else
            $display("  TC5 FAIL: K_puf HD = %0d%% (keys too similar)", (hamming_k*100)/16);

        if (K_puf1 !== K_puf2)
            $display("  TC5 PASS: keys are different");
        else
            $display("  TC5 FAIL: keys identical -- PUF not unique!");

        $finish;
    end
endmodule

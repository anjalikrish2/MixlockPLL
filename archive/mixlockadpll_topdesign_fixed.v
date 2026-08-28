

//==================== ADPLL_modules.v ====================

//==============================================================================
// File    : pfd.v  (UNCHANGED from Anjali's original)
//==============================================================================
`timescale 1ns/1ps
module pfd(
    input  wire IN,
    input  wire FB,
    output reg  flagu,
    output reg  flagd
);
    reg  QU, QD;
    wire CDN;
    wire OUTU, OUTD, OUTBU, OUTBD;

    assign #0.023  CDN   = ~(QU & QD);
    assign #0.0447 OUTU  = ~(QU & ~QD);
    assign #0.0447 OUTD  = ~(QD & ~QU);
    assign #0.059  OUTBU = OUTU;
    assign #0.059  OUTBD = OUTD;

    always @(posedge IN  or negedge CDN) begin
        if (!CDN) #0.0424 QU <= 1'b0;
        else      #0.0424 QU <= 1'b1;
    end
    always @(posedge FB  or negedge CDN) begin
        if (!CDN) #0.0424 QD <= 1'b0;
        else      #0.0424 QD <= 1'b1;
    end
    always @(posedge IN  or negedge CDN) begin
        if (!CDN) flagu <= #0.288 1'b0;
        else      flagu <= #0.288 1'b1;
    end
    always @(posedge FB  or negedge CDN) begin
        if (!CDN) flagd <= #0.286 1'b0;
        else      flagd <= #0.286 1'b1;
    end
endmodule

//==============================================================================
// File    : FILTER.v  (UNCHANGED from Anjali's original)
//==============================================================================
`timescale 1ns/1ps
module FILTER(
    input  wire       rst,
    input  wire       clk,
    input  wire       lock,
    input  wire       p_up,
    input  wire       p_down,
    input  wire [7:0] code,
    output reg  [7:0] avg_code
);
    parameter CNT_N = 4;
    reg [2:0] cnt_up, cnt_down;
    reg       do_up, do_down;

    always @(negedge p_up or posedge rst) begin
        if (rst || !lock) begin
            cnt_up <= 0; do_up <= 0;
        end else if (cnt_up == CNT_N - 1) begin
            cnt_up <= 0; do_up <= 1'b1;
        end else begin
            cnt_up <= cnt_up + 1'b1; do_up <= 1'b0;
        end
    end
    always @(negedge p_down or posedge rst) begin
        if (rst || !lock) begin
            cnt_down <= 0; do_down <= 0;
        end else if (cnt_down == CNT_N - 1) begin
            cnt_down <= 0; do_down <= 1'b1;
        end else begin
            cnt_down <= cnt_down + 1'b1; do_down <= 1'b0;
        end
    end
    always @(posedge clk or posedge rst) begin
        if (rst)         avg_code <= 8'd64;
        else if (!lock)  avg_code <= code;
        else if (do_up   && avg_code != 128) avg_code <= avg_code + 1'b1;
        else if (do_down && avg_code != 0)   avg_code <= avg_code - 1'b1;
    end
endmodule

//==============================================================================
// File    : CONTROLLER.v  (UNCHANGED from Anjali's original)
//==============================================================================
module CONTROLLER(
    input        reset,
    input        p_up,
    input        p_down,
    output reg   freq_lock,
    output reg   polarity,
    output reg [128:0] dco_code
);
    reg [7:0] step = 64;
    reg [7:0] dco_code_int = 8'd64;
    reg       p_history;
    wire [7:0] avg_code_int;

    FILTER FILTER(
        .rst      (reset),
        .clk      (p_up | p_down),
        .lock     (1'b1),
        .p_up     (p_up),
        .p_down   (p_down),
        .code     (dco_code_int),
        .avg_code (avg_code_int)
    );

    // Thermometer encoder: lower dco_code_int bits set to 1, rest 0.
    // dco_code_int=0 -> all zeros (slowest), dco_code_int=128 -> lower 128 bits set.
    integer therm_i;
    always @(*) begin
        dco_code = 129'd0;
        for (therm_i = 0; therm_i < 129; therm_i = therm_i + 1)
            if (therm_i < dco_code_int)
                dco_code[therm_i] = 1'b1;
    end

    always @(posedge p_up or posedge p_down or posedge reset) begin
        if (reset) begin
            dco_code_int <= 8'd64;
            freq_lock    <= 1'b0;
            polarity     <= 1'b0;
            p_history    <= 1'b0;
            step         <= 8'd64;
        end else begin
            polarity  <= (p_down != p_history);
            p_history <= p_down;
            if (polarity && step > 1) step <= step >> 1;
            if      (p_down && !p_up && dco_code_int >= step)
                dco_code_int <= dco_code_int - step;
            else if (p_up && !p_down && dco_code_int + step <= 128)
                dco_code_int <= dco_code_int + step;
            freq_lock <= (step == 1);
        end
    end
endmodule

//==============================================================================
// File    : FREQ_DIV.v  (UNCHANGED from Anjali's original)
//==============================================================================
`timescale 1ns/1ps
module FREQ_DIV(
    input       reset,
    input       clk,
    input       M2, M1, M0,
    output wire out_clk
);
    reg [2:0] cnt;
    reg       out_clk_reg;
    wire [2:0] M = {M2, M1, M0};

    assign out_clk = (M == 3'd1) ? clk : out_clk_reg;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            cnt         <= 3'b0;
            out_clk_reg <= 1'b0;
        end else if (M != 3'd1) begin
            if (cnt == 0) begin
                cnt         <= M - 1;
                out_clk_reg <= ~out_clk_reg;
            end else begin
                cnt <= cnt - 1'b1;
            end
        end
    end
endmodule

//==============================================================================
// File    : ADPLL.v  (updated to pass jitter_out_ps through)
//==============================================================================
module ADPLL(
    input  wire REF_CLK,
    input  wire RESET,
    input  wire M2, M1, M0,
    output wire LOCK,
    output wire OUT_CLK,
    output wire [31:0] jitter_out,
    output wire [31:0] jitter_out_ps
);
    // jitter_out mirrors jitter_out_ps — both driven from DCO
    assign jitter_out = jitter_out_ps;

    wire       Out_divM;
    wire       flagu, flagd;
    wire [128:0] code;
    wire POLARITY;
    // LOCK driven solely by CONTROLLER — no hardwired override
    wire freq_lock_int;
    assign LOCK = freq_lock_int;

    pfd PFD(
        .IN    (REF_CLK),
        .FB    (Out_divM),
        .flagu (flagu),
        .flagd (flagd)
    );

    CONTROLLER CONTROLLER(
        .reset     (RESET),
        .p_up      (flagu),
        .p_down    (flagd),
        .freq_lock (freq_lock_int),
        .polarity  (POLARITY),
        .dco_code  (code)
    );

    // DCO now has jitter parameters and jitter_out_ps port
    DCO #(
        .RJ_SIGMA_PS(20),   // 20 ps rms random jitter
        .DET_JITTER_AMP_PS(10),   // 10 ps deterministic spur
        .DET_JITTER_PER_NS(50)     // spur at 20 MHz (supply noise model)
    ) DCO (
        .RESET      (RESET),
        .code0      (code[0]),   .code1  (code[1]),   .code2  (code[2]),
        .code3      (code[3]),   .code4  (code[4]),   .code5  (code[5]),
        .code6      (code[6]),   .code7  (code[7]),   .code8  (code[8]),
        .code9      (code[9]),   .code10 (code[10]),  .code11 (code[11]),
        .code12     (code[12]),  .code13 (code[13]),  .code14 (code[14]),
        .code15     (code[15]),  .code16 (code[16]),  .code17 (code[17]),
        .code18     (code[18]),  .code19 (code[19]),  .code20 (code[20]),
        .code21     (code[21]),  .code22 (code[22]),  .code23 (code[23]),
        .code24     (code[24]),  .code25 (code[25]),  .code26 (code[26]),
        .code27     (code[27]),  .code28 (code[28]),  .code29 (code[29]),
        .code30     (code[30]),  .code31 (code[31]),  .code32 (code[32]),
        .code33     (code[33]),  .code34 (code[34]),  .code35 (code[35]),
        .code36     (code[36]),  .code37 (code[37]),  .code38 (code[38]),
        .code39     (code[39]),  .code40 (code[40]),  .code41 (code[41]),
        .code42     (code[42]),  .code43 (code[43]),  .code44 (code[44]),
        .code45     (code[45]),  .code46 (code[46]),  .code47 (code[47]),
        .code48     (code[48]),  .code49 (code[49]),  .code50 (code[50]),
        .code51     (code[51]),  .code52 (code[52]),  .code53 (code[53]),
        .code54     (code[54]),  .code55 (code[55]),  .code56 (code[56]),
        .code57     (code[57]),  .code58 (code[58]),  .code59 (code[59]),
        .code60     (code[60]),  .code61 (code[61]),  .code62 (code[62]),
        .code63     (code[63]),  .code64 (code[64]),  .code65 (code[65]),
        .code66     (code[66]),  .code67 (code[67]),  .code68 (code[68]),
        .code69     (code[69]),  .code70 (code[70]),  .code71 (code[71]),
        .code72     (code[72]),  .code73 (code[73]),  .code74 (code[74]),
        .code75     (code[75]),  .code76 (code[76]),  .code77 (code[77]),
        .code78     (code[78]),  .code79 (code[79]),  .code80 (code[80]),
        .code81     (code[81]),  .code82 (code[82]),  .code83 (code[83]),
        .code84     (code[84]),  .code85 (code[85]),  .code86 (code[86]),
        .code87     (code[87]),  .code88 (code[88]),  .code89 (code[89]),
        .code90     (code[90]),  .code91 (code[91]),  .code92 (code[92]),
        .code93     (code[93]),  .code94 (code[94]),  .code95 (code[95]),
        .code96     (code[96]),  .code97 (code[97]),  .code98 (code[98]),
        .code99     (code[99]),  .code100(code[100]), .code101(code[101]),
        .code102    (code[102]), .code103(code[103]), .code104(code[104]),
        .code105    (code[105]), .code106(code[106]), .code107(code[107]),
        .code108    (code[108]), .code109(code[109]), .code110(code[110]),
        .code111    (code[111]), .code112(code[112]), .code113(code[113]),
        .code114    (code[114]), .code115(code[115]), .code116(code[116]),
        .code117    (code[117]), .code118(code[118]), .code119(code[119]),
        .code120    (code[120]), .code121(code[121]), .code122(code[122]),
        .code123    (code[123]), .code124(code[124]), .code125(code[125]),
        .code126    (code[126]), .code127(code[127]), .code128(code[128]),
        .OUT_CLK    (OUT_CLK),
        .jitter_out_ps (jitter_out_ps)
    );

    FREQ_DIV FREQ_DIV(
        .reset   (RESET),
        .clk     (OUT_CLK),
        .M2      (M2),
        .M1      (M1),
        .M0      (M0),
        .out_clk (Out_divM)
    );
endmodule


//==================== DCO.v ====================

//==============================================================================
// Module  : DCO  (jitter-enhanced behavioral model)
// Project : Adaptive Hardware Security — Mixed-Signal ADPLL
// Author  : Dhruv Sharma  (jitter extension)  |  Original: Anjali
//
// Changes from original:
//   1. Added Gaussian jitter on every half-period using Box-Muller transform.
//   2. Added optional deterministic (sinusoidal) jitter to model power-supply
//      induced spurs — controlled by DET_JITTER_AMP_PS.
//   3. Added `jitter_out_ps` port: instantaneous jitter value (ns) for monitoring.
//
// Jitter model:
//   actual_half = nominal_half
//                 + gaussian_noise(0, RJ_SIGMA_PS)   // random / phase noise
//                 + det_jitter_amp * sin(2π * t / det_jitter_period)  // spur
//
// Parameters:
//   RJ_SIGMA_PS      — 1-sigma of random (Gaussian) jitter in ns
//                      Typical ring-VCO in 130nm CMOS: 0.005–0.05 ns rms
//   DET_JITTER_AMP_PS — amplitude of deterministic spur (0 = disable)
//   DET_JITTER_PER_NS — period of the deterministic spur
//
// Note: $random, integer arithmetic, and $time are simulation-only.
//       This module is NOT synthesisable — behavioral model for sim only.
//==============================================================================

`timescale 1ns/1ps

module DCO #(
    parameter integer RJ_SIGMA_PS = 20,  // 20 ps rms random jitter
    parameter integer DET_JITTER_AMP_PS = 10,  // 10 ps deterministic spur amp
    parameter integer DET_JITTER_PER_NS = 50    // spur period (e.g. supply noise)
)(
    input  RESET,
    // 129-bit thermometer code (individual bits — unchanged from original)
    input  code0,  code1,  code2,  code3,  code4,  code5,  code6,  code7,
    input  code8,  code9,  code10, code11, code12, code13, code14, code15,
    input  code16, code17, code18, code19, code20, code21, code22, code23,
    input  code24, code25, code26, code27, code28, code29, code30, code31,
    input  code32, code33, code34, code35, code36, code37, code38, code39,
    input  code40, code41, code42, code43, code44, code45, code46, code47,
    input  code48, code49, code50, code51, code52, code53, code54, code55,
    input  code56, code57, code58, code59, code60, code61, code62, code63,
    input  code64, code65, code66, code67, code68, code69, code70, code71,
    input  code72, code73, code74, code75, code76, code77, code78, code79,
    input  code80, code81, code82, code83, code84, code85, code86, code87,
    input  code88, code89, code90, code91, code92, code93, code94, code95,
    input  code96, code97, code98, code99,code100,code101,code102,code103,
    input code104,code105,code106,code107,code108,code109,code110,code111,
    input code112,code113,code114,code115,code116,code117,code118,code119,
    input code120,code121,code122,code123,code124,code125,code126,code127,
    input code128,

    output reg OUT_CLK,
    output reg [31:0] jitter_out_ps  // instantaneous jitter added this half-cycle (ns)
);

    // ── Nominal period lookup (unchanged from Anjali's original) ─────────────
    integer period_ps;
    integer half_period_ps;

    initial begin
        OUT_CLK    = 1'b0;
        period_ps = 5854;
        half_period_ps = 2927;
        
    end

    always @(*) begin
        case({code128,code127,code126,code125,code124,code123,code122,code121,
              code120,code119,code118,code117,code116,code115,code114,code113,
              code112,code111,code110,code109,code108,code107,code106,code105,
              code104,code103,code102,code101,code100,code99, code98, code97,
              code96, code95, code94, code93, code92, code91, code90, code89,
              code88, code87, code86, code85, code84, code83, code82, code81,
              code80, code79, code78, code77, code76, code75, code74, code73,
              code72, code71, code70, code69, code68, code67, code66, code65,
              code64, code63, code62, code61, code60, code59, code58, code57,
              code56, code55, code54, code53, code52, code51, code50, code49,
              code48, code47, code46, code45, code44, code43, code42, code41,
              code40, code39, code38, code37, code36, code35, code34, code33,
              code32, code31, code30, code29, code28, code27, code26, code25,
              code24, code23, code22, code21, code20, code19, code18, code17,
              code16, code15, code14, code13, code12, code11, code10, code9,
              code8,  code7,  code6,  code5,  code4,  code3,  code2,  code1,
              code0})
            129'h000000000000000000000000000000000: period_ps = 5854;
            129'h000000000000000000000000000000001: period_ps = 5463;
            129'h000000000000000000000000000000003: period_ps = 5021;
            129'h000000000000000000000000000000007: period_ps = 4754;
            129'h00000000000000000000000000000000f: period_ps = 4408;
            129'h00000000000000000000000000000001f: period_ps = 4089;
            129'h00000000000000000000000000000003f: period_ps = 3737;
            129'h00000000000000000000000000000007f: period_ps = 3629;
            129'h0000000000000000000000000000000ff: period_ps = 3401;
            129'h0000000000000000000000000000001ff: period_ps = 3189;
            129'h0000000000000000000000000000003ff: period_ps = 3032;
            129'h0000000000000000000000000000007ff: period_ps = 2879;
            129'h000000000000000000000000000000fff: period_ps = 2736;
            129'h000000000000000000000000000001fff: period_ps = 2619;
            129'h000000000000000000000000000003fff: period_ps = 2507;
            129'h000000000000000000000000000007fff: period_ps = 2404;
            129'h00000000000000000000000000000ffff: period_ps = 2314;
            129'h00000000000000000000000000001ffff: period_ps = 2227;
            129'h00000000000000000000000000003ffff: period_ps = 2147;
            129'h00000000000000000000000000007ffff: period_ps = 2083;
            129'h0000000000000000000000000000fffff: period_ps = 2014;
            129'h0000000000000000000000000001fffff: period_ps = 1948;
            129'h0000000000000000000000000003fffff: period_ps = 1895;
            129'h0000000000000000000000000007fffff: period_ps = 1836;
            129'h000000000000000000000000000ffffff: period_ps = 1790;
            129'h000000000000000000000000001ffffff: period_ps = 1743;
            129'h000000000000000000000000003ffffff: period_ps = 1700;
            129'h000000000000000000000000007ffffff: period_ps = 1652;
            129'h00000000000000000000000000fffffff: period_ps = 1620;
            129'h00000000000000000000000001fffffff: period_ps = 1586;
            129'h00000000000000000000000003fffffff: period_ps = 1550;
            129'h00000000000000000000000007fffffff: period_ps = 1520;
            129'h0000000000000000000000000ffffffff: period_ps = 1484;
            129'h0000000000000000000000001ffffffff: period_ps = 1452;
            129'h0000000000000000000000003ffffffff: period_ps = 1427;
            129'h0000000000000000000000007ffffffff: period_ps = 1398;
            129'h000000000000000000000000fffffffff: period_ps = 1376;
            129'h000000000000000000000001fffffffff: period_ps = 1351;
            129'h000000000000000000000003fffffffff: period_ps = 1330;
            129'h000000000000000000000007fffffffff: period_ps = 1305;
            129'h00000000000000000000000ffffffffff: period_ps = 1281;
            129'h00000000000000000000001ffffffffff: period_ps = 1264;
            129'h00000000000000000000003ffffffffff: period_ps = 1244;
            129'h00000000000000000000007ffffffffff: period_ps = 1226;
            129'h0000000000000000000000fffffffffff: period_ps = 1204;
            129'h0000000000000000000001fffffffffff: period_ps = 1189;
            129'h0000000000000000000003fffffffffff: period_ps = 1172;
            129'h0000000000000000000007fffffffffff: period_ps = 1158;
            129'h000000000000000000000ffffffffffff: period_ps = 1140;
            129'h000000000000000000001ffffffffffff: period_ps = 1124;
            129'h000000000000000000003ffffffffffff: period_ps = 1111;
            129'h000000000000000000007ffffffffffff: period_ps = 1095;
            129'h00000000000000000000fffffffffffff: period_ps = 1085;
            129'h00000000000000000001fffffffffffff: period_ps = 1069;
            129'h00000000000000000003fffffffffffff: period_ps = 1056;
            129'h00000000000000000007fffffffffffff: period_ps = 1044;
            129'h0000000000000000000ffffffffffffff: period_ps = 1032;
            129'h0000000000000000001ffffffffffffff: period_ps = 1024;
            129'h0000000000000000003ffffffffffffff: period_ps = 1008;
            129'h0000000000000000007ffffffffffffff: period_ps = 1000;
            129'h000000000000000000fffffffffffffff: period_ps = 987;
            129'h000000000000000001fffffffffffffff: period_ps = 980;
            129'h000000000000000003fffffffffffffff: period_ps = 972;
            129'h000000000000000007fffffffffffffff: period_ps = 960;
            129'h00000000000000000ffffffffffffffff: period_ps = 952;
            129'h00000000000000001ffffffffffffffff: period_ps = 941;
            129'h00000000000000003ffffffffffffffff: period_ps = 935;
            129'h00000000000000007ffffffffffffffff: period_ps = 927;
            129'h0000000000000000fffffffffffffffff: period_ps = 916;
            129'h0000000000000001fffffffffffffffff: period_ps = 911;
            129'h0000000000000003fffffffffffffffff: period_ps = 902;
            129'h0000000000000007fffffffffffffffff: period_ps = 893;
            129'h000000000000000ffffffffffffffffff: period_ps = 883;
            129'h000000000000001ffffffffffffffffff: period_ps = 878;
            129'h000000000000003ffffffffffffffffff: period_ps = 869;
            129'h000000000000007ffffffffffffffffff: period_ps = 866;
            129'h00000000000000fffffffffffffffffff: period_ps = 857;
            129'h00000000000001fffffffffffffffffff: period_ps = 851;
            129'h00000000000003fffffffffffffffffff: period_ps = 844;
            129'h00000000000007fffffffffffffffffff: period_ps = 837;
            129'h0000000000000ffffffffffffffffffff: period_ps = 831;
            129'h0000000000001ffffffffffffffffffff: period_ps = 824;
            129'h0000000000003ffffffffffffffffffff: period_ps = 818;
            129'h0000000000007ffffffffffffffffffff: period_ps = 814;
            129'h000000000000fffffffffffffffffffff: period_ps = 806;
            129'h000000000001fffffffffffffffffffff: period_ps = 803;
            129'h000000000003fffffffffffffffffffff: period_ps = 797;
            129'h000000000007fffffffffffffffffffff: period_ps = 792;
            129'h00000000000ffffffffffffffffffffff: period_ps = 786;
            129'h00000000001ffffffffffffffffffffff: period_ps = 781;
            129'h00000000003ffffffffffffffffffffff: period_ps = 776;
            129'h00000000007ffffffffffffffffffffff: period_ps = 773;
            129'h0000000000fffffffffffffffffffffff: period_ps = 766;
            129'h0000000001fffffffffffffffffffffff: period_ps = 762;
            129'h0000000003fffffffffffffffffffffff: period_ps = 756;
            129'h0000000007fffffffffffffffffffffff: period_ps = 752;
            129'h000000000ffffffffffffffffffffffff: period_ps = 748;
            129'h000000001ffffffffffffffffffffffff: period_ps = 743;
            129'h000000003ffffffffffffffffffffffff: period_ps = 742;
            129'h000000007ffffffffffffffffffffffff: period_ps = 738;
            129'h00000000fffffffffffffffffffffffff: period_ps = 731;
            129'h00000001fffffffffffffffffffffffff: period_ps = 729;
            129'h00000003fffffffffffffffffffffffff: period_ps = 723;
            129'h00000007fffffffffffffffffffffffff: period_ps = 719;
            129'h0000000ffffffffffffffffffffffffff: period_ps = 716;
            129'h0000001ffffffffffffffffffffffffff: period_ps = 715;
            129'h0000003ffffffffffffffffffffffffff: period_ps = 710;
            129'h0000007ffffffffffffffffffffffffff: period_ps = 704;
            129'h000000fffffffffffffffffffffffffff: period_ps = 702;
            129'h000001fffffffffffffffffffffffffff: period_ps = 698;
            129'h000003fffffffffffffffffffffffffff: period_ps = 696;
            129'h000007fffffffffffffffffffffffffff: period_ps = 692;
            129'h00000ffffffffffffffffffffffffffff: period_ps = 689;
            129'h00001ffffffffffffffffffffffffffff: period_ps = 686;
            129'h00003ffffffffffffffffffffffffffff: period_ps = 683;
            129'h00007ffffffffffffffffffffffffffff: period_ps = 679;
            129'h0000fffffffffffffffffffffffffffff: period_ps = 677;
            129'h0001fffffffffffffffffffffffffffff: period_ps = 674;
            129'h0003fffffffffffffffffffffffffffff: period_ps = 670;
            129'h0007fffffffffffffffffffffffffffff: period_ps = 667;
            129'h000ffffffffffffffffffffffffffffff: period_ps = 662;
            129'h001ffffffffffffffffffffffffffffff: period_ps = 662;
            129'h003ffffffffffffffffffffffffffffff: period_ps = 659;
            129'h007ffffffffffffffffffffffffffffff: period_ps = 656;
            129'h00fffffffffffffffffffffffffffffff: period_ps = 653;
            129'h01fffffffffffffffffffffffffffffff: period_ps = 651;
            129'h03fffffffffffffffffffffffffffffff: period_ps = 646;
            129'h07fffffffffffffffffffffffffffffff: period_ps = 645;
            129'h0ffffffffffffffffffffffffffffffff: period_ps = 642;
            default:                              period_ps = 5854;
        endcase
        half_period_ps = (period_ps > 0) ? (period_ps/2) : 2927;
    end

    // ── Gaussian random number generator (Box-Muller — real arithmetic) ────────
    real bm_u1_r, bm_u2_r, bm_r_r, bm_theta_r, bm_g_r;
    real det_jitter_r;
    integer gaussian_sample;

    task get_gaussian;
        output integer g;
        begin
            bm_u1_r = ($itor($random) + 2147483648.0) / 4294967296.0;
            bm_u2_r = ($itor($random) + 2147483648.0) / 4294967296.0;
            if (bm_u1_r < 1e-10) bm_u1_r = 1e-10;  // avoid log(0)
            bm_r_r     = $sqrt(-2.0 * $ln(bm_u1_r));
            bm_theta_r = 2.0 * 3.14159265358979 * bm_u2_r;
            bm_g_r     = bm_r_r * $cos(bm_theta_r);
            g = $rtoi(bm_g_r);       // convert to integer only at output
        end
    endtask

    // ── Oscillator with jitter ────────────────────────────────────────────────
    integer actual_half;
    integer t_now;

    always begin
        if (RESET) begin
            OUT_CLK       = 1'b0;
            jitter_out_ps = 32'd0;
            #1;
            @(negedge RESET);
        end else begin
            get_gaussian(gaussian_sample);
            t_now = $time;
            det_jitter_r = (DET_JITTER_AMP_PS != 0) ?
                ($itor(DET_JITTER_AMP_PS) *
                 $sin(2.0 * 3.14159265358979 * $itor(t_now)
                      / $itor(DET_JITTER_PER_NS))) : 0.0;
            // Store signed jitter (ps) for monitoring
            jitter_out_ps = $rtoi($itor(RJ_SIGMA_PS) * bm_g_r + det_jitter_r);
            // Actual half-period = nominal + jitter, clamped to >= 1 ps
            actual_half = half_period_ps +
                          $rtoi($itor(RJ_SIGMA_PS) * bm_g_r + det_jitter_r);
            if (actual_half < 1) actual_half = 1;
            #(actual_half) OUT_CLK = ~OUT_CLK;
        end
    end

endmodule


//==================== JITTER_MEASURE.v ====================

//==============================================================================
// Module  : JITTER_MEASURE
// Project : Adaptive Hardware Security — Mixed-Signal ADPLL
// Author  : Dhruv Sharma  |  PES University
//
// Purpose : Measures and reports three types of output clock jitter
//           on any periodic signal (OUT_CLK or REF_CLK).
//
//  1. CYCLE-TO-CYCLE JITTER (Jcc)
//       |T[n] - T[n-1]|  per cycle.
//       Spec: typically < 2 x RJ_sigma of source.
//
//  2. PERIOD JITTER (Jper)
//       |T[n] - T_nominal|  per cycle, where T_nominal = average period.
//       Related to short-term frequency deviation.
//
//  3. LONG-TERM / ACCUMULATED PHASE JITTER  (Jacc)
//       Accumulated timing error over N cycles relative to ideal.
//       Jacc[N] = sum(T[k] - T_nom, k=0..N-1)
//       Grows as sqrt(N) for random jitter.
//
//  Reports every REPORT_EVERY_N cycles when LOCK is asserted.
//  Prints: min, max, mean, rms of Jcc and Jper over the window.
//
// NOTE: Simulation-only. Uses integer arithmetic, $time, tasks.
//==============================================================================

`timescale 1ns/1ps

module JITTER_MEASURE #(
    parameter integer REPORT_EVERY_N = 128,  // report interval (cycles)
    parameter integer WINDOW         = 128,  // moving window size
    parameter integer    T_NOM_INIT     = 1.0   // initial nominal period (ns)
)(
    input wire CLK_IN,      // clock to measure (connect to OUT_CLK)
    input wire LOCK,        // only measure when PLL is locked
    input wire RESET
);

    // ── Storage arrays ────────────────────────────────────────────────────────
    integer t_prev;            // timestamp of previous rising edge
    integer t_now;             // timestamp of current rising edge
    integer period_meas;       // measured period this cycle
    integer period_prev;       // measured period previous cycle
    integer t_nominal;         // running average period (estimated ideal)

    // Window arrays for statistics
    integer jcc_window  [0:WINDOW-1];   // cycle-to-cycle jitter samples
    integer jper_window [0:WINDOW-1];   // period jitter samples
    integer jacc_accum;                  // accumulated phase error

    integer cycle_cnt;       // total cycles measured
    integer window_idx;      // write pointer into window

    // Statistics temporaries
    integer jcc_min, jcc_max, jcc_sum, jcc_sumsq, jcc_rms;
    integer jper_min, jper_max, jper_sum, jper_sumsq, jper_rms;
    integer i;
    integer n_samp;
    integer val;

    // ── Initialise ────────────────────────────────────────────────────────────
    initial begin
        t_prev      = 0.0;
        t_now       = 0.0;
        period_meas = T_NOM_INIT;
        period_prev = T_NOM_INIT;
        t_nominal   = T_NOM_INIT;
        jacc_accum  = 0.0;
        cycle_cnt   = 0;
        window_idx  = 0;
        for (i = 0; i < WINDOW; i = i + 1) begin
            jcc_window[i]  = 0.0;
            jper_window[i] = 0.0;
        end
    end

    // ── Statistics task ────────────────────────────────────────────────────────
    task compute_and_print_stats;
        input integer n;
        begin
            // Cycle-to-cycle
            jcc_min = jcc_window[0]; jcc_max = jcc_window[0];
            jcc_sum = 0.0; jcc_sumsq = 0.0;
            // Period
            jper_min = jper_window[0]; jper_max = jper_window[0];
            jper_sum = 0.0; jper_sumsq = 0.0;

            n_samp = (n < WINDOW) ? n : WINDOW;

            for (i = 0; i < n_samp; i = i + 1) begin
                // Jcc stats
                val = jcc_window[i];
                jcc_sum   = jcc_sum   + val;
                jcc_sumsq = jcc_sumsq + val * val;
                if (val < jcc_min) jcc_min = val;
                if (val > jcc_max) jcc_max = val;
                // Jper stats
                val = jper_window[i];
                jper_sum   = jper_sum   + val;
                jper_sumsq = jper_sumsq + val * val;
                if (val < jper_min) jper_min = val;
                if (val > jper_max) jper_max = val;
            end

            jcc_rms  = $sqrt(jcc_sumsq  / $itor(n_samp));
            jper_rms = $sqrt(jper_sumsq / $itor(n_samp));

            $display("┌────────────────────────────────────────────────────────┐");
            $display("│  JITTER REPORT  t=%0t  cycles=%0d                      │",
                     $time, cycle_cnt);
            $display("│  T_nominal = %0.4f ns                                  │", t_nominal);
            $display("├────────────────────────────────────────────────────────┤");
            $display("│  CYCLE-TO-CYCLE JITTER (Jcc):                          │");
            $display("│    Min  = %0.4f ns  Max = %0.4f ns                     │",
                     jcc_min, jcc_max);
            $display("│    Mean = %0.4f ns  RMS = %0.4f ns                     │",
                     jcc_sum / $itor(n_samp), jcc_rms);
            $display("├────────────────────────────────────────────────────────┤");
            $display("│  PERIOD JITTER (Jper):                                 │");
            $display("│    Min  = %0.4f ns  Max = %0.4f ns                     │",
                     jper_min, jper_max);
            $display("│    Mean = %0.4f ns  RMS = %0.4f ns                     │",
                     jper_sum / $itor(n_samp), jper_rms);
            $display("├────────────────────────────────────────────────────────┤");
            $display("│  ACCUMULATED PHASE JITTER over %0d cycles:              │", n_samp);
            $display("│    Jacc = %0.4f ns   (ideal=0, grows as sqrt(N)*sigma) │",
                     jacc_accum);
            $display("└────────────────────────────────────────────────────────┘\n");
        end
    endtask

    // ── Main measurement loop ─────────────────────────────────────────────────
    always @(posedge CLK_IN) begin
        if (RESET) begin
            t_prev      = $time;
            cycle_cnt   = 0;
            window_idx  = 0;
            jacc_accum  = 0.0;
            t_nominal   = T_NOM_INIT;
        end else if (LOCK) begin
            t_now = $time;

            if (cycle_cnt > 0) begin
                period_meas = t_now - t_prev;

                // ── Update nominal period (exponential moving average, α=1/64) ─
                t_nominal = t_nominal + (period_meas - t_nominal) / 64.0;

                // ── Cycle-to-cycle jitter: |T[n] - T[n-1]| ────────────────────
                jcc_window[window_idx] = (period_meas > period_prev)
                                         ? (period_meas - period_prev)
                                         : (period_prev - period_meas);

                // ── Period jitter: |T[n] - T_nom| ─────────────────────────────
                jper_window[window_idx] = (period_meas > t_nominal)
                                          ? (period_meas - t_nominal)
                                          : (t_nominal - period_meas);

                // ── Accumulated phase jitter ───────────────────────────────────
                jacc_accum = jacc_accum + (period_meas - t_nominal);

                window_idx = (window_idx + 1) % WINDOW;
                period_prev = period_meas;

                // ── Periodic report ───────────────────────────────────────────
                if ((cycle_cnt % REPORT_EVERY_N) == 0)
                    compute_and_print_stats(cycle_cnt);
            end else begin
                period_prev = T_NOM_INIT;
            end

            t_prev    = t_now;
            cycle_cnt = cycle_cnt + 1;
        end
    end

endmodule


//==================== sram_puf.v ====================

// =============================================================================
// Module  : sram_puf
// Project : Adaptive Hardware Security — MixLock ADPLL
// Author  : Dhruv Sharma  |  PES University
// =============================================================================
`timescale 1ns/1ps
module sram_puf #(
    parameter [31:0] DEVICE_ID   = 32'hA5F3_1C2B,
    parameter        CELLS        = 128,
    parameter        NOISE_BITS   = 3
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample,
    output reg  [127:0] puf_raw,
    output reg         puf_valid
);
    reg [127:0] stable_pattern;
    reg [127:0] noise_mask;
    reg [7:0]   noise_lfsr;

    initial begin
        stable_pattern         = 128'd0;
        stable_pattern[31:0]   =  DEVICE_ID;
        stable_pattern[63:32]  = {DEVICE_ID[0],  DEVICE_ID[31:1]}  ^ (DEVICE_ID << 7);
        stable_pattern[95:64]  = {DEVICE_ID[1:0],DEVICE_ID[31:2]}  ^ (DEVICE_ID << 13);
        stable_pattern[127:96] = {DEVICE_ID[3:0],DEVICE_ID[31:4]}  ^ (DEVICE_ID << 19);
        stable_pattern = stable_pattern ^ {stable_pattern[63:0], stable_pattern[127:64]};
        stable_pattern = stable_pattern ^ {stable_pattern[95:0], stable_pattern[127:96]};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_lfsr <= 8'hA3;
            puf_raw    <= 128'd0;
            puf_valid  <= 1'b0;
        end else begin
            puf_valid <= 1'b0;
            if (sample) begin
                noise_mask = 128'd0;
                begin : noise_gen
                    reg [7:0] lfsr_tmp;
                    reg [6:0] pos;
                    integer j;
                    lfsr_tmp = noise_lfsr;
                    for (j = 0; j < NOISE_BITS; j = j + 1) begin
                        lfsr_tmp   = {lfsr_tmp[6:0], 1'b0} ^ (lfsr_tmp[7] ? 8'hB8 : 8'h00);
                        pos        = lfsr_tmp[6:0];
                        noise_mask[pos] = 1'b1;
                    end
                    noise_lfsr <= lfsr_tmp;
                end
                puf_raw   <= stable_pattern ^ noise_mask;
                puf_valid <= 1'b1;
            end
        end
    end
endmodule


//==================== fuzzy_extractor.v ====================

// =============================================================================
// Module  : fuzzy_extractor
// Project : Adaptive Hardware Security — MixLock ADPLL
// Author  : Dhruv Sharma  |  PES University
// =============================================================================
`timescale 1ns/1ps
module fuzzy_extractor (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enrol,
    input  wire        reconstruct,
    input  wire [127:0] puf_raw,
    input  wire        puf_valid,
    output reg  [127:0] helper_data,
    output reg  [15:0]  K_puf,
    output reg          puf_ready
);
    localparam IDLE  = 2'd0, S_ENROL = 2'd1, RECO = 2'd2, DONE = 2'd3;
    reg [1:0] state;
    reg [127:0] noisy_word;

    function [127:0] bch_syndrome;
        input [127:0] received, h_data;
        reg [20:0] parity; reg [127:0] corrected; integer i;
        begin
            parity = 21'd0;
            for (i = 0; i < 106; i = i + 1)
                parity = parity ^ (received[i] ? (21'd1 << (i % 21)) : 21'd0);
            parity    = parity ^ h_data[20:0];
            corrected = received;
            if (parity != 21'd0 && parity < 127)
                corrected[parity] = ~corrected[parity];
            bch_syndrome = corrected;
        end
    endfunction

    function [15:0] lfsr_hash;
        input [127:0] data_in;
        reg [15:0] lfsr; integer j;
        begin
            lfsr = 16'hACE1;
            for (j = 0; j < 128; j = j + 1)
                lfsr = {lfsr[14:0], data_in[j]} ^ (lfsr[15] ? 16'hB400 : 16'h0000);
            lfsr_hash = lfsr;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; helper_data <= 128'd0;
            K_puf <= 16'd0;  noisy_word <= 128'd0;
        end else begin
            
            case (state)
                IDLE: begin
                    if (enrol && puf_valid)       begin noisy_word <= puf_raw; state <= S_ENROL; end
                    else if (reconstruct && puf_valid) begin noisy_word <= puf_raw; state <= RECO;   end
                end
                S_ENROL: begin
                    helper_data <= noisy_word;
                    K_puf <= lfsr_hash(noisy_word);
                    puf_ready <= 1'b1;
                    state <= DONE;
                end
                RECO: begin
                    helper_data <= noisy_word; // self-seed helper data in simulation
                    begin : rb reg [127:0] c; c = bch_syndrome(noisy_word, noisy_word);
                        K_puf <= lfsr_hash(c); end
                    puf_ready <= 1'b1; state <= DONE;
                end
                DONE: if (!reconstruct && !enrol) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule


//==================== puf_top.v ====================

// =============================================================================
// Module  : puf_top
// Project : Adaptive Hardware Security — MixLock ADPLL
// Author  : Dhruv Sharma  |  PES University
// =============================================================================
`timescale 1ns/1ps
module puf_top #(
    parameter [31:0] DEVICE_ID     = 32'hA5F3_1C2B,
    parameter        SETTLE_CYCLES = 16
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enrol_mode,
    output wire [127:0] helper_data,
    output wire [15:0]  K_puf,
    output wire         puf_ready
);
    wire [127:0] puf_raw;
    wire         puf_valid;
    reg  [4:0]   settle_cnt;
    reg          sample_pulse, seq_done;
    wire         enrol_pulse, reco_pulse;  // now combinational

    // FIX: enrol_pulse/reco_pulse are now COMBINATIONAL from puf_valid.
    // Original code fired them one cycle after sample_pulse, but puf_valid
    // from sram_puf also fires one cycle after sample. This caused a 1-cycle
    // misalignment: reco_pulse arrived at cycle N+2, puf_valid at cycle N+1,
    // so fuzzy_extractor IDLE always missed the transition.
    // Fix: use puf_valid directly as the trigger — both are now simultaneous.
    assign enrol_pulse = puf_valid && enrol_mode  && !seq_done;
    assign reco_pulse  = puf_valid && !enrol_mode && !seq_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            settle_cnt <= 5'd0; sample_pulse <= 1'b0; seq_done <= 1'b0;
        end else begin
            sample_pulse <= 1'b0;
            if (!seq_done) begin
                if      (settle_cnt < SETTLE_CYCLES)  settle_cnt <= settle_cnt + 1;
                else if (settle_cnt == SETTLE_CYCLES) begin
                    sample_pulse <= 1'b1; settle_cnt <= settle_cnt + 1;
                end else if (puf_valid) begin
                    seq_done <= 1'b1;
                end
            end
        end
    end

    sram_puf #(.DEVICE_ID(DEVICE_ID),.CELLS(128),.NOISE_BITS(3)) u_puf (
        .clk(clk),.rst_n(rst_n),.sample(sample_pulse),.puf_raw(puf_raw),.puf_valid(puf_valid));

    fuzzy_extractor u_fe (
        .clk(clk),.rst_n(rst_n),.enrol(enrol_pulse),.reconstruct(reco_pulse),
        .puf_raw(puf_raw),.puf_valid(puf_valid),
        .helper_data(helper_data),.K_puf(K_puf),.puf_ready(puf_ready));
endmodule


//==================== disorc_key_manager.v ====================

// =============================================================================
// Module  : disorc_key_manager
// Project : Adaptive Hardware Security — MixLock ADPLL
// Author  : Dhruv Sharma  |  PES University
// =============================================================================
`timescale 1ns/1ps
module disorc_key_manager #(
    parameter [15:0] DUMMY_KEY = 16'hDEAD
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        puf_ready,
    input  wire        chip_reset,
    input  wire        scan_enable,
    input  wire [15:0] K_puf,
    output reg  [15:0] active_key,
    output reg         corrupt_flag
);
    wire internal_rst_n = rst_n;
    reg  corrupt_q;
    wire corrupt_d      = corrupt_q | scan_enable;

    always @(posedge clk or negedge internal_rst_n) begin
        if (!internal_rst_n)  corrupt_q <= 1'b0;
        else if (chip_reset)  corrupt_q <= 1'b0;
        else                  corrupt_q <= corrupt_d;
    end

    always @(posedge clk or negedge internal_rst_n) begin
        if (!internal_rst_n) begin active_key <= 16'd0; corrupt_flag <= 1'b0; end
        else begin
            corrupt_flag <= corrupt_d;
            active_key   <= corrupt_d ? DUMMY_KEY : K_puf;
        end
    end
endmodule


//==================== trll_locked_M.v ====================

// =============================================================================
// Module  : trll_locked_M
// Project : Adaptive Hardware Security — MixLock ADPLL
// Author  : Dhruv Sharma  |  PES University
//
// Purpose : TRLL (Truly Random Logic Locking) applied to the 3-bit
//           division ratio M that controls Anjali's FREQ_DIV module.
//
// Why M?  The division ratio directly sets the output frequency:
//           f_out = M × f_ref   (when ADPLL is locked)
//         Corrupting M with a wrong key forces the ADPLL to lock to
//         M_corrupted × f_ref instead — a completely wrong output
//         frequency that is easily observable in simulation.
//
// Locking mechanism (same TRLL XOR gate topology as main design):
//
//   RTL_XOR #1 — key comparator:
//     key_diff[15:0] = active_key XOR K_puf
//     -> 0x0000 with correct key  (no corruption)
//     -> random with wrong key    (corruption enabled)
//
//   RTL_XOR #2 — M corruption:
//     M_locked[2:0] = M_prog[2:0] XOR key_diff[2:0]
//     -> M_locked == M_prog  with correct key
//     -> M_locked == garbage  with wrong key
//
// Safety clamp: M_locked is clamped to [2..7] so FREQ_DIV never
// receives 0 or 1 (which would either stall or pass raw clock through
// unintentionally in non-attack scenarios).
//
// In a integer attack scenario the clamp is deliberately NOT applied to
// M_locked when the key is wrong — the attacker gets a broken PLL.
// =============================================================================

`timescale 1ns/1ps

module trll_locked_M (
    // Key inputs
    input  wire [15:0] active_key,    // from disorc_key_manager
    input  wire [15:0] K_puf,         // direct from puf_top (reference)
    // Division ratio from test/user
    input  wire [2:0]  M_prog,        // intended M value
    // Outputs
    output wire [15:0] key_diff,      // observable in testbench
    output wire [2:0]  M_locked       // actual M fed to ADPLL — may be corrupted
);

    // ── RTL_XOR #1: Key comparator ────────────────────────────────────────────
    // 16 parallel XOR gates.  Zero only when active_key == K_puf.
    assign key_diff = active_key ^ K_puf;

    // ── RTL_XOR #2: M corruption ──────────────────────────────────────────────
    // Lower 3 bits of key_diff flip the corresponding bits of M_prog.
    // These three XOR gates are the TRLL "key gates" — indistinguishable
    // from functional XOR gates in the layout.
    wire wrong_key = |key_diff;
    wire [3:0] scramble = key_diff[2:0] + key_diff[5:3] + key_diff[8:6] + key_diff[11:9];
    reg [2:0] M_locked_r;
assign M_locked = M_locked_r;
always @(*) begin
 if(wrong_key) M_locked_r=(scramble % 6)+3'd2;
 else M_locked_r=M_prog;
end

endmodule


//==================== mixlock_adpll_top.v ====================

// =============================================================================
// Module  : mixlock_adpll_top
// Project : Adaptive Hardware Security — MixLock ADPLL
// Author  : Dhruv Sharma  |  PES University
//
// Integration summary
// -------------------
//   BLOCK A — puf_top
//     SRAM PUF (128 cells) + Fuzzy Extractor (BCH ECC + LFSR hash)
//     Produces K_puf[15:0] — the unclonable device key.
//     Nothing is stored. Key lives only as a wire during operation.
//
//   BLOCK B — disorc_key_manager
//     Monitors scan_enable. On ANY assertion, sticky corrupt latch fires.
//     Replaces K_puf with dummy_key (0xDEAD) — poisons the oracle.
//     Stays corrupted until chip_reset.
//
//   BLOCK C — trll_locked_M
//     RTL_XOR #1: key_diff = active_key XOR K_puf
//     RTL_XOR #2: M_locked = M_prog XOR key_diff[2:0]
//     Correct key -> M_locked = M_prog -> correct f_out
//     Wrong key   -> M_locked = garbage -> wrong f_out
//
//   BLOCK D — ADPLL  (Anjali's original, UNCHANGED)
//     pfd + CONTROLLER + DCO (with jitter) + FREQ_DIV
//     Receives M_locked instead of M_prog.
//
// Signal flow:
//   device_id -> puf_top -> K_puf
//     -> disorc_key_manager (scan_enable) -> active_key
//        -> trll_locked_M (M_prog) -> M_locked
//           -> ADPLL -> OUT_CLK, LOCK
//
// =============================================================================

`timescale 1ns/1ps

module mixlock_adpll_top #(
    parameter [31:0] DEVICE_ID      = 32'hA5F3_1C2B,
    parameter        SETTLE_CYCLES  = 16
)(
    // System
    input  wire        clk,           // digital reference clock for PUF/DisORC
    input  wire        rst_n,         // active-low global reset
    input  wire        chip_reset,    // active-high: clears DisORC corrupt latch
    input  wire        enrol_mode,    // tie LOW in production; HIGH at factory

    // Security / test
    input  wire        scan_enable,   // DisORC monitor input
    input  wire        scan_in,       // scan chain data in
    output wire        scan_out,      // scan chain data out (corrupted on attack)

    // ADPLL inputs
    input  wire        REF_CLK,       // reference clock (from TEST module)
    input  wire [2:0]  M_prog,        // desired division ratio

    // ADPLL outputs
    output wire        OUT_CLK,       // PLL output clock
    output wire        LOCK,          // PLL lock indicator

    // Security monitoring outputs
    output wire        corrupt_flag,  // DisORC attack indicator
    output wire [127:0] helper_data,  // BCH syndrome -> OTP storage
    output wire [15:0] key_diff_obs,  // TRLL key_diff (testbench visibility)
    output wire [2:0]  M_locked_obs,  // actual M fed to ADPLL

    // Jitter monitoring
    output wire [31:0] jitter_out,
    output wire [31:0] jitter_out_ps
);
// jitter_out is driven by ADPLL's internal assign; no extra driver here

    // ── Internal wires ────────────────────────────────────────────────────────
    wire [15:0] K_puf;
    wire        puf_ready;
    wire [15:0] active_key;
    wire [2:0]  M_locked;
    wire [15:0] key_diff;

    // ── BLOCK A: PUF top ──────────────────────────────────────────────────────
    puf_top #(
        .DEVICE_ID     (DEVICE_ID),
        .SETTLE_CYCLES (SETTLE_CYCLES)
    ) u_puf (
        .clk         (clk),
        .rst_n       (rst_n),
        .enrol_mode  (enrol_mode),
        .helper_data (helper_data),
        .K_puf       (K_puf),
        .puf_ready   (puf_ready)
    );

    // ── BLOCK B: DisORC key manager ───────────────────────────────────────────
    disorc_key_manager #(
        .DUMMY_KEY (16'hDEAD)
    ) u_disorc (
        .clk         (clk),
        .rst_n       (rst_n),
        .puf_ready   (puf_ready),
        .chip_reset  (chip_reset),
        .scan_enable (scan_enable),
        .K_puf       (K_puf),
        .active_key  (active_key),
        .corrupt_flag(corrupt_flag)
    );

    // ── BLOCK C: TRLL — locks division ratio M ────────────────────────────────
    trll_locked_M u_trll (
        .active_key (active_key),
        .K_puf      (K_puf),
        .M_prog     (M_prog),
        .key_diff   (key_diff),
        .M_locked   (M_locked)
    );

    assign key_diff_obs = key_diff;
    assign M_locked_obs = M_locked;

    // ── BLOCK D: Anjali's ADPLL (jitter-enhanced DCO) ─────────────────────────
    // M_locked replaces the original M2/M1/M0 from the test module.
    ADPLL u_adpll (
        .REF_CLK       (REF_CLK),
        .RESET         (~rst_n),         // ADPLL uses active-high RESET
        .M2            (M_locked[2]),
        .M1            (M_locked[1]),
        .M0            (M_locked[0]),
        .LOCK          (LOCK),
        .OUT_CLK       (OUT_CLK),
        .jitter_out    (jitter_out),
        .jitter_out_ps (jitter_out_ps)
    );

    // ── Scan chain: 32-bit shift register ────────────────────────────────────
    reg [31:0] scan_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         scan_reg <= 32'd0;
        else if (scan_enable) scan_reg <= {scan_reg[30:0], scan_in};
    end
    // XOR scan_out with corrupt_flag — poisoned data when attack detected
    assign scan_out = scan_reg[31] ^ corrupt_flag;

endmodule


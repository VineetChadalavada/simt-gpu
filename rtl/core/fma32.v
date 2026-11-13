`timescale 1ns/1ps

// FP32 fused multiply-add, y = a * b + c, with one rounding.
// The core uses it for all FP instructions (fadd = a*1+b, fmul = a*b+(-0)).
//
// Rules: round to nearest even; denormal inputs and outputs are zero (FTZ);
// a NaN result is the canonical quiet NaN 0x7FC00000. tools/fp32.py is the
// bit-exact reference.
//
// Pipeline (inputs in cycle t, y valid in cycle t+3 from the stage-3 regs):
//   1  unpack, special cases, 24x24 multiply
//   2  align the addend to the product, add or subtract (76-bit window)
//   3  leading-zero count, normalize
//   4  round, overflow / flush to zero, pack   (combinational, after reg 3)
//
// The alignment window: the product P has 48 bits, the addend C 24 bits.
// s = (exponent of C's lsb) - (exponent of P's lsb).
//   s >= 0: C is shifted left by s over P. If s > 50, C is so much larger
//           that P only changes the sticky bit: C is shifted by 50 and P is
//           replaced by 1 (same top 24 bits, same round bit, same sticky).
//   s < 0:  P is shifted left by -s over C. If -s > 26, C is replaced by 1
//           in the same way.
// So a 76-bit adder gives an exact result for rounding, with no 3x24-bit
// wide shifter.
module fma32 (
    input  wire        clk,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [31:0] c,
    output reg  [31:0] y
);
    localparam W = 76;

    // ------------------------------------------------------------------
    // Stage 1: unpack, special cases, multiply
    // ------------------------------------------------------------------
    wire [7:0] ea = a[30:23], eb = b[30:23], ec = c[30:23];
    wire a_z = (ea == 8'd0), b_z = (eb == 8'd0), c_z = (ec == 8'd0);
    wire a_i = (ea == 8'hFF) && (a[22:0] == 0);
    wire b_i = (eb == 8'hFF) && (b[22:0] == 0);
    wire c_i = (ec == 8'hFF) && (c[22:0] == 0);
    wire a_n = (ea == 8'hFF) && (a[22:0] != 0);
    wire b_n = (eb == 8'hFF) && (b[22:0] != 0);
    wire c_n = (ec == 8'hFF) && (c[22:0] != 0);

    wire sp    = a[31] ^ b[31];
    wire p_inf = a_i | b_i;
    wire p_z   = a_z | b_z;
    wire nan   = a_n | b_n | c_n | (p_inf & p_z) | (p_inf & c_i & (sp != c[31]));
    wire inf   = p_inf | c_i;

    reg            r1_sp, r1_sc, r1_pz, r1_cz, r1_nan, r1_inf, r1_inf_s;
    reg [47:0]     r1_p;
    reg [23:0]     r1_mc;
    reg signed [11:0] r1_lp, r1_lc;        // exponents of the lsb of P and of C

    always @(posedge clk) begin
        r1_sp    <= sp;
        r1_sc    <= c[31];
        r1_pz    <= p_z;
        r1_cz    <= c_z;
        r1_nan   <= nan;
        r1_inf   <= inf;
        r1_inf_s <= p_inf ? sp : c[31];
        r1_p     <= {1'b1, a[22:0]} * {1'b1, b[22:0]};
        r1_mc    <= {1'b1, c[22:0]};
        r1_lp    <= $signed({4'd0, ea}) + $signed({4'd0, eb}) - 12'sd300;
        r1_lc    <= $signed({4'd0, ec}) - 12'sd150;
    end

    // ------------------------------------------------------------------
    // Stage 2: align and add
    // ------------------------------------------------------------------
    wire signed [11:0] s = r1_lc - r1_lp;
    wire signed [11:0] t = -s;

    reg [W-1:0]       hi, lo;
    reg               hs, ls;
    reg signed [11:0] base;
    reg [5:0]         sh;
    always @(*) begin
        hi = 0; lo = 0; hs = 1'b0; ls = 1'b0; base = 0; sh = 0;
        if (r1_pz) begin                       // product is zero: y = c
            hi = {{(W-24){1'b0}}, r1_mc}; base = r1_lc; hs = r1_sc; ls = r1_sc;
        end else if (r1_cz) begin              // addend is zero: y = round(a * b)
            hi = {{(W-48){1'b0}}, r1_p};  base = r1_lp; hs = r1_sp; ls = r1_sp;
        end else if (s >= 0) begin
            sh   = (s > 50) ? 6'd50 : s[5:0];
            hi   = {{(W-24){1'b0}}, r1_mc} << sh;
            lo   = (s > 50) ? {{(W-1){1'b0}}, 1'b1} : {{(W-48){1'b0}}, r1_p};
            base = r1_lc - $signed({6'd0, sh});
            hs   = r1_sc; ls = r1_sp;
        end else begin
            sh   = (t > 26) ? 6'd26 : t[5:0];
            hi   = {{(W-48){1'b0}}, r1_p} << sh;
            lo   = (t > 26) ? {{(W-1){1'b0}}, 1'b1} : {{(W-24){1'b0}}, r1_mc};
            base = r1_lp - $signed({6'd0, sh});
            hs   = r1_sp; ls = r1_sc;
        end
    end

    wire [W:0] diff = {1'b0, hi} - {1'b0, lo};
    wire       neg  = (hs != ls) && diff[W];
    wire [W-1:0] mag = (hs == ls) ? hi + lo : (neg ? lo - hi : diff[W-1:0]);

    reg               r2_sign, r2_nan, r2_inf, r2_inf_s, r2_zz, r2_zz_s;
    reg [W-1:0]       r2_mag;
    reg signed [11:0] r2_base;

    always @(posedge clk) begin
        r2_mag   <= (r1_pz && r1_cz) ? {W{1'b0}} : mag;
        r2_sign  <= neg ? ls : hs;
        r2_base  <= base;
        r2_nan   <= r1_nan;
        r2_inf   <= r1_inf;
        r2_inf_s <= r1_inf_s;
        r2_zz    <= r1_pz && r1_cz;            // both terms zero
        r2_zz_s  <= r1_sp & r1_sc;
    end

    // ------------------------------------------------------------------
    // Stage 3: leading-zero count and normalize
    // ------------------------------------------------------------------
    reg [6:0] lz;
    integer i;
    always @(*) begin
        lz = W;
        for (i = 0; i < W; i = i + 1)
            if (r2_mag[i]) lz = W - 1 - i;
    end

    reg [W-1:0]       r3_norm;
    reg signed [11:0] r3_e;                    // unbiased exponent of the msb
    reg               r3_sign, r3_nan, r3_inf, r3_inf_s, r3_zz, r3_zz_s, r3_zero;

    always @(posedge clk) begin
        r3_norm  <= r2_mag << lz;
        r3_e     <= r2_base + $signed(12'd75) - $signed({5'd0, lz});
        r3_sign  <= r2_sign;
        r3_zero  <= (r2_mag == 0);
        r3_nan   <= r2_nan;
        r3_inf   <= r2_inf;
        r3_inf_s <= r2_inf_s;
        r3_zz    <= r2_zz;
        r3_zz_s  <= r2_zz_s;
    end

    // ------------------------------------------------------------------
    // Stage 4: round to nearest even, pack
    // ------------------------------------------------------------------
    wire [23:0] m24   = r3_norm[W-1 -: 24];
    wire        rnd   = r3_norm[W-25];
    wire        stk   = |r3_norm[W-26:0];
    wire [24:0] m25   = {1'b0, m24} + (rnd & (stk | m24[0]));
    wire signed [11:0] e2 = r3_e + (m25[24] ? 12'sd1 : 12'sd0);
    wire signed [11:0] biased = e2 + 12'sd127;
    wire [22:0] frac  = m25[24] ? 23'd0 : m25[22:0];

    always @(*) begin
        if (r3_nan)                 y = 32'h7FC00000;
        else if (r3_inf)            y = {r3_inf_s, 8'hFF, 23'd0};
        else if (r3_zz)             y = {r3_zz_s, 31'd0};
        else if (r3_zero)           y = 32'd0;                        // exact cancellation
        else if (biased >= 255)     y = {r3_sign, 8'hFF, 23'd0};       // overflow
        else if (biased <= 0)       y = {r3_sign, 31'd0};              // flush to zero
        else                        y = {r3_sign, biased[7:0], frac};
    end
endmodule

`timescale 1ns/1ps

// Unit test for fma32. A new vector goes in every cycle. The inputs of
// cycle t are captured at the end of t, and y shows the result in cycle
// t+3 (after the 3rd clock edge).
// Vectors come from tools/fp_vectors.py (vectors.hex in the current
// directory): a, b, c, expected, one word per line.
module tb_fma;
    localparam LAT = 3;
    reg clk = 0;
    always #5 clk = ~clk;

    reg  [31:0] a, b, c;
    wire [31:0] y;
    reg  [31:0] va [0:LAT-1], vb [0:LAT-1], vc [0:LAT-1], ve [0:LAT-1];

    fma32 dut (.clk(clk), .a(a), .b(b), .c(c), .y(y));

    integer fd, i, k, n, errors, got;
    reg [31:0] x0, x1, x2, x3;
    initial begin
        fd = $fopen("vectors.hex", "r");
        if (fd == 0) begin
            $display("ERROR: no vectors.hex");
            $finish;
        end
        n = 0; errors = 0;
        // ve[k] holds the expected value of the vector that went in k cycles ago
        for (i = 0; i < LAT; i = i + 1) ve[i] = 32'bx;
        got = 4;
        while (1) begin
            got = $fscanf(fd, "%h\n%h\n%h\n%h\n", x0, x1, x2, x3);
            if (got == 4) begin
                a <= x0; b <= x1; c <= x2;
            end
            @(posedge clk);
            #1;
            for (k = LAT - 1; k > 0; k = k - 1) begin
                va[k] = va[k-1]; vb[k] = vb[k-1]; vc[k] = vc[k-1]; ve[k] = ve[k-1];
            end
            va[0] = x0; vb[0] = x1; vc[0] = x2; ve[0] = (got == 4) ? x3 : 32'bx;
            // after this edge, y belongs to the vector LAT-1 entries back
            if (ve[LAT-1] !== 32'bx) begin
                n = n + 1;
                if (y !== ve[LAT-1]) begin
                    if (errors < 10)
                        $display("MISMATCH: %h * %h + %h = %h, expected %h",
                                 va[LAT-1], vb[LAT-1], vc[LAT-1], y, ve[LAT-1]);
                    errors = errors + 1;
                end
            end
            if (got != 4 && ve[LAT-1] === 32'bx && ve[0] === 32'bx && ve[1] === 32'bx) begin
                $display("%0d vectors, %0d errors", n, errors);
                if (errors == 0 && n > 0) $display("TEST PASSED");
                else                      $display("TEST FAILED");
                $finish;
            end
        end
    end
endmodule

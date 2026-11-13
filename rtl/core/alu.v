`timescale 1ns/1ps

// The integer ALU of one SIMD lane. The core has one ALU per lane.
module alu (
    input  wire [3:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] y
);
    wire [4:0] sh = b[4:0];
    wire lt  = $signed(a) < $signed(b);

    always @(*) begin
        case (op)
            4'h0: y = b;                       // pass (LUI)
            4'h1: y = a + b;
            4'h2: y = a - b;
            4'h3: y = a * b;
            4'h4: y = a & b;
            4'h5: y = a | b;
            4'h6: y = a ^ b;
            4'h7: y = a << sh;
            4'h8: y = a >> sh;
            4'h9: y = $signed(a) >>> sh;
            4'hA: y = {31'b0, lt};
            4'hB: y = {31'b0, a < b};
            4'hC: y = lt ? a : b;              // min (signed)
            4'hD: y = lt ? b : a;              // max (signed)
            4'hE: y = {31'b0, a == b};
            default: y = {31'b0, a != b};
        endcase
    end
endmodule

`timescale 1ns/1ps

// The register file slice of one SIMD lane: 16 registers for each warp.
// Three read ports (operands a, b and c of the issuing warp; c is only for
// ffma) and two write ports (port 0 = ALU or FPU result, port 1 = load data
// from the LSU). The scoreboard makes sure that the two ports never write
// the same register; the issue stage makes sure that the ALU and the FPU
// never use port 0 in the same cycle.
module regfile_lane #(
    parameter NW = 4,
    parameter WB = 2               // warp index width
)(
    input  wire          clk,
    input  wire [WB-1:0] rw,
    input  wire [3:0]    ra,
    input  wire [3:0]    rb,
    input  wire [3:0]    rc,
    output wire [31:0]   da,
    output wire [31:0]   db,
    output wire [31:0]   dc,
    input  wire          we0,
    input  wire [WB-1:0] ww0,
    input  wire [3:0]    wr0,
    input  wire [31:0]   wd0,
    input  wire          we1,
    input  wire [WB-1:0] ww1,
    input  wire [3:0]    wr1,
    input  wire [31:0]   wd1
);
    reg [31:0] mem [0:NW*16-1];

    integer i;
    initial for (i = 0; i < NW*16; i = i + 1) mem[i] = 32'd0;

    assign da = (ra == 4'd0) ? 32'd0 : mem[rw*16 + ra];
    assign db = (rb == 4'd0) ? 32'd0 : mem[rw*16 + rb];
    assign dc = (rc == 4'd0) ? 32'd0 : mem[rw*16 + rc];

    always @(posedge clk) begin
        if (we0) mem[ww0*16 + wr0] <= wd0;
        if (we1) mem[ww1*16 + wr1] <= wd1;
    end
endmodule

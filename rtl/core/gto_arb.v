`timescale 1ns/1ps

// Greedy-then-oldest (GTO) arbiter, the second warp-scheduler policy.
// Greedy: the warp that won last time wins again while it is ready.
// Oldest: else the lowest warp number wins. All warps of a block start
// together, so the lowest number stands for the oldest warp.
// The interface is the same as rr_arb, so sm_core can use either one.
module gto_arb #(
    parameter N  = 4,
    parameter WB = 2
)(
    input  wire          clk,
    input  wire          rst,
    input  wire [N-1:0]  req,
    input  wire          take,
    output reg           gnt_valid,
    output reg  [WB-1:0] gnt
);
    reg [WB-1:0] last;
    integer i;

    always @(*) begin
        gnt_valid = |req;
        gnt       = {WB{1'b0}};
        if (req[last])
            gnt = last;
        else
            for (i = N - 1; i >= 0; i = i - 1)
                if (req[i]) gnt = i[WB-1:0];
    end

    always @(posedge clk) begin
        if (rst)
            last <= {WB{1'b0}};
        else if (take && gnt_valid)
            last <= gnt;
    end
endmodule

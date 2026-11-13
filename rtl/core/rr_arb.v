`timescale 1ns/1ps

// Round-robin arbiter. The search starts at the requester after the last
// winner, so every requester wins within N grants. The warp scheduler and
// the fetch unit both use it (loose round-robin, "LRR").
module rr_arb #(
    parameter N  = 4,
    parameter WB = 2
)(
    input  wire          clk,
    input  wire          rst,
    input  wire [N-1:0]  req,
    input  wire          take,        // the grant is used this cycle
    output reg           gnt_valid,
    output reg  [WB-1:0] gnt
);
    reg [WB-1:0] last;
    integer i, k;

    always @(*) begin
        gnt_valid = 1'b0;
        gnt       = {WB{1'b0}};
        for (i = N; i >= 1; i = i - 1) begin
            k = (last + i) % N;
            if (req[k]) begin
                gnt_valid = 1'b1;
                gnt       = k[WB-1:0];
            end
        end
    end

    always @(posedge clk) begin
        if (rst)
            last <= N - 1;
        else if (take && gnt_valid)
            last <= gnt;
    end
endmodule

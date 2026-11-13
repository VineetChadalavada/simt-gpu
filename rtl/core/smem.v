`timescale 1ns/1ps

// Shared memory: NB banks, each ROWS words of 32 bits, one port per bank.
// Word address = row * NB + bank, so consecutive words are in different
// banks. Synchronous read: rdata is valid the cycle after en.
module smem #(
    parameter NB   = 8,
    parameter ROWS = 32
)(
    input  wire              clk,
    input  wire [NB-1:0]     en,
    input  wire              we,
    input  wire [NB*$clog2(ROWS)-1:0] row,
    input  wire [NB*32-1:0]  wdata,
    output wire [NB*32-1:0]  rdata
);
    localparam RB = $clog2(ROWS);

    genvar b;
    generate
        for (b = 0; b < NB; b = b + 1) begin : bank
            reg [31:0] mem [0:ROWS-1];
            reg [31:0] q;
            always @(posedge clk)
                if (en[b]) begin
                    if (we) mem[row[b*RB +: RB]] <= wdata[b*32 +: 32];
                    else    q <= mem[row[b*RB +: RB]];
                end
            assign rdata[b*32 +: 32] = q;
        end
    endgenerate
endmodule

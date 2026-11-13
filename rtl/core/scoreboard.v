`timescale 1ns/1ps

// One pending bit per (warp, register). The issue stage sets the bit of the
// destination register. The write-back ports clear it. An instruction may
// issue only when none of its registers is pending (RAW and WAW hazards).
module scoreboard #(
    parameter NW = 4,
    parameter WB = 2
)(
    input  wire           clk,
    input  wire           clear_all,
    input  wire           set_en,
    input  wire [WB-1:0]  set_w,
    input  wire [3:0]     set_r,
    input  wire           clr0_en,
    input  wire [WB-1:0]  clr0_w,
    input  wire [3:0]     clr0_r,
    input  wire           clr1_en,
    input  wire [WB-1:0]  clr1_w,
    input  wire [3:0]     clr1_r,
    output reg [NW*16-1:0] pending
);
    initial pending = 0;

    always @(posedge clk) begin
        if (clear_all) begin
            pending <= 0;
        end else begin
            if (clr0_en) pending[clr0_w*16 + clr0_r] <= 1'b0;
            if (clr1_en) pending[clr1_w*16 + clr1_r] <= 1'b0;
            if (set_en)  pending[set_w*16 + set_r]   <= 1'b1;
        end
    end
endmodule

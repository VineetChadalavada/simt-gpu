`timescale 1ns/1ps

// The SIMT reconvergence stack of one warp (IPDOM stack).
//
// The top entry lives in registers: pc (the next PC to fetch), rpc (where
// this path ends) and mask (its active lanes). D more entries live below it.
// sp = 0 means the top entry is the base entry: the warp does not diverge.
//
// Events, from the core:
//   fetch  the warp fetched pc, so pc <= pc + 1
//   jump   a jmp or a branch that all lanes take: pc <= jump_pc
//   div    a divergent branch: split the top entry into two paths
//   exit   the lanes in exit_mask stop
//   pop    the top path reached its rpc (or has no lanes left)
// The core sends at most one of jump/div/exit/pop for a warp in a cycle,
// and never fetch together with them.
//
// Divergence keeps the stack small with two rules (golden.py has the same):
//   - no entry for a path that starts at the rpc: it would pop at once;
//   - if the top entry already ends at this rpc, the new paths replace it.
// The entries that remain go in order [old top, not-taken, taken]; the last
// one becomes the new top, the others go into the stack memory.
//
// exit does not touch the stack memory. A popped entry is ANDed with alive
// (the lanes that have not exited), so exited lanes never come back.
module simt_stack #(
    parameter NL = 8,
    parameter D  = 8
)(
    input  wire          clk,
    input  wire          init,
    input  wire [NL-1:0] init_mask,
    input  wire [10:0]   init_pc,     // the kernel entry PC
    input  wire          fetch,
    input  wire          jump,
    input  wire [10:0]   jump_pc,
    input  wire          div,
    input  wire [10:0]   div_target,
    input  wire [10:0]   div_rpc,
    input  wire [NL-1:0] div_taken,
    output wire          div_overflow,
    input  wire          exit,
    input  wire [NL-1:0] exit_mask,
    input  wire          pop,
    output reg  [10:0]   pc,
    output reg  [NL-1:0] mask,
    output wire          need_pop,
    output wire          at_base,
    output reg  [NL-1:0] alive
);
    localparam SPW = $clog2(D + 1);

    reg [10:0]   rpc;
    reg [SPW-1:0] sp;
    reg [10:0]   s_pc   [0:D-1];
    reg [10:0]   s_rpc  [0:D-1];
    reg [NL-1:0] s_mask [0:D-1];

    assign at_base  = (sp == 0);
    assign need_pop = !at_base && ((pc == rpc) || (mask == 0));

    // ---- divergence: build the list [old top, not-taken, taken] ----
    wire keep    = at_base || (rpc != div_rpc);
    wire push_nt = (pc != div_rpc);              // pc is already branch pc + 1
    wire push_tk = (div_target != div_rpc);

    reg [1:0]       n;                           // entries in the list (0..3)
    reg [3*11-1:0]  l_pc, l_rpc;
    reg [3*NL-1:0]  l_mask;
    always @(*) begin
        n = 0;
        l_pc = 0; l_rpc = 0; l_mask = 0;
        if (keep) begin
            l_pc[n*11 +: 11] = div_rpc;   l_rpc[n*11 +: 11] = rpc;
            l_mask[n*NL +: NL] = mask;    n = n + 1;
        end
        if (push_nt) begin
            l_pc[n*11 +: 11] = pc;        l_rpc[n*11 +: 11] = div_rpc;
            l_mask[n*NL +: NL] = mask & ~div_taken;  n = n + 1;
        end
        if (push_tk) begin
            l_pc[n*11 +: 11] = div_target; l_rpc[n*11 +: 11] = div_rpc;
            l_mask[n*NL +: NL] = div_taken; n = n + 1;
        end
    end
    // The last list entry becomes the top, so the stack grows by n - 1.
    assign div_overflow = (n != 0) && ({1'b0, sp} + n - 1 > D);

    integer i;
    always @(posedge clk) begin
        if (init) begin
            pc    <= init_pc;
            rpc   <= 11'd0;
            mask  <= init_mask;
            alive <= init_mask;
            sp    <= 0;
        end else if (fetch) begin
            pc <= pc + 11'd1;
        end else if (jump) begin
            pc <= jump_pc;
        end else if (div) begin
            if (n == 0) begin
                pc <= div_rpc;                   // rpc == div_rpc here: pops next
            end else begin
                for (i = 0; i < 2; i = i + 1)
                    if (i < n - 1) begin
                        s_pc[sp + i]   <= l_pc[i*11 +: 11];
                        s_rpc[sp + i]  <= l_rpc[i*11 +: 11];
                        s_mask[sp + i] <= l_mask[i*NL +: NL];
                    end
                pc   <= l_pc[(n-1)*11 +: 11];
                rpc  <= l_rpc[(n-1)*11 +: 11];
                mask <= l_mask[(n-1)*NL +: NL];
                sp   <= sp + n - 1;
            end
        end else if (exit) begin
            mask  <= mask & ~exit_mask;
            alive <= alive & ~exit_mask;
        end else if (pop) begin
            pc   <= s_pc[sp - 1];
            rpc  <= s_rpc[sp - 1];
            mask <= s_mask[sp - 1] & alive;
            sp   <= sp - 1;
        end
    end
endmodule

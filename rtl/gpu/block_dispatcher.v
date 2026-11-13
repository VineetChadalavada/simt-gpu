`timescale 1ns/1ps

// Block dispatcher: gives the blocks of a kernel to the shader cores.
//
//   IDLE   wait for start
//   INV    one cycle: every core invalidates its L1 (all cores are idle)
//   RUN    each cycle, if blocks are left, give the next block (ctaid) to
//          the lowest core that is free (launch_ready). Count block_done.
//          When all blocks are done, the kernel is done.
//
// A core is free again in the cycle of its block_done pulse, so a core
// with short blocks takes more of them: the load balances by itself.
// If a core stops with an error, the kernel stops (state ERR). The other
// core can finish its block, but it gets no new blocks. Only a reset
// clears a core error.
module block_dispatcher #(
    parameter NC = 2,
    parameter CB = 1
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          start,          // ignored when busy
    input  wire [31:0]   grid,           // blocks in the kernel
    output wire          busy,
    output reg           done,           // sticky; start clears it
    output reg           error,          // sticky; only reset clears it
    output reg  [3:0]    error_code,
    output reg  [CB-1:0] error_core,
    output reg  [31:0]   kernel_cycles,
    // to the cores
    output wire          l1_inv,
    output wire [NC-1:0] launch_valid,
    input  wire [NC-1:0] launch_ready,
    output reg  [31:0]   launch_ctaid,
    input  wire [NC-1:0] block_done,
    input  wire [NC-1:0] core_err,
    input  wire [NC*4-1:0] core_err_code
);
    localparam S_IDLE = 2'd0, S_INV = 2'd1, S_RUN = 2'd2, S_ERR = 2'd3;
    reg [1:0]  state;
    reg [31:0] n_done;

    assign busy   = (state == S_INV) || (state == S_RUN);
    assign l1_inv = (state == S_INV);

    // the lowest free core
    reg          pick_valid;
    reg [CB-1:0] pick;
    integer c1, c2;
    always @(*) begin
        pick_valid = 1'b0;
        pick       = 0;
        for (c1 = NC - 1; c1 >= 0; c1 = c1 - 1)
            if (launch_ready[c1]) begin
                pick_valid = 1'b1;
                pick       = c1[CB-1:0];
            end
    end

    wire give = (state == S_RUN) && (launch_ctaid < grid) && pick_valid && (core_err == 0);
    assign launch_valid = give ? ({{NC-1{1'b0}}, 1'b1} << pick) : {NC{1'b0}};

    function [CB:0] popcount;
        input [NC-1:0] m;
        integer j;
        begin
            popcount = 0;
            for (j = 0; j < NC; j = j + 1) popcount = popcount + m[j];
        end
    endfunction

    // the lowest core with an error
    reg [CB-1:0] ecore;
    always @(*) begin
        ecore = 0;
        for (c2 = NC - 1; c2 >= 0; c2 = c2 - 1)
            if (core_err[c2]) ecore = c2[CB-1:0];
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            error <= 1'b0;
            error_code <= 4'd0;
            error_core <= 0;
            kernel_cycles <= 0;
        end else begin
            case (state)
                S_IDLE:
                    if (start) begin
                        state         <= S_INV;
                        done          <= 1'b0;
                        launch_ctaid  <= 0;
                        n_done        <= 0;
                        kernel_cycles <= 0;
                    end
                S_INV:
                    state <= S_RUN;
                S_RUN: begin
                    kernel_cycles <= kernel_cycles + 1;
                    if (give) launch_ctaid <= launch_ctaid + 1;
                    n_done <= n_done + popcount(block_done);
                    if (core_err != 0) begin
                        state      <= S_ERR;
                        error      <= 1'b1;
                        error_code <= core_err_code[ecore*4 +: 4];
                        error_core <= ecore;
                    end else if (n_done == grid) begin
                        state <= S_IDLE;
                        done  <= 1'b1;
                    end
                end
                default: ;                  // S_ERR: wait for reset
            endcase
        end
    end
endmodule

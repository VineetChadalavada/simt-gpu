`timescale 1ns/1ps

// The GPU: NC shader cores, a block dispatcher, a memory arbiter, and the
// kernel launch registers.
//
// Launch registers (32-bit words on a simple register bus, reg_addr = word):
//   0  CTRL      write 1: start the kernel (ignored while busy)
//   1  STATUS    read: [0] busy [1] done [2] error [7:4] error code
//                      [11:8] core with the error
//   2  ENTRY     kernel entry PC
//   3  GRID      blocks in the grid (nctaid)
//   4  BLOCK     threads per block (ntid), 1..NW*NL
//   5-8 PARAM0-3 kernel arguments
//   9  CYCLES    read: cycles of the last kernel
// irq is a one-cycle pulse when a kernel ends (done or error).
//
// Each core has its own instruction-memory read port (outside, so the
// testbench or the FPGA wrapper decides what the memory is). The cores
// share one global-memory port through the arbiter.
module gpu_top #(
    parameter NC = 2,
    parameter NW = 4,
    parameter NL = 8,
    parameter SCHED = 0               // warp scheduler: 0 = LRR, 1 = GTO
)(
    input  wire              clk,
    input  wire              rst,

    // launch registers
    input  wire              reg_we,
    input  wire [3:0]        reg_addr,
    input  wire [31:0]       reg_wdata,
    output reg  [31:0]       reg_rdata,
    output wire              irq,

    // instruction memory, one synchronous read port for each core
    output wire [NC-1:0]     imem_en,
    output wire [NC*11-1:0]  imem_addr,
    input  wire [NC*32-1:0]  imem_rdata,

    // global memory: 32-byte lines, in-order read responses
    output wire              mem_req_valid,
    input  wire              mem_req_ready,
    output wire              mem_req_we,
    output wire [31:0]       mem_req_addr,
    output wire [7:0]        mem_req_wmask,
    output wire [255:0]      mem_req_wdata,
    input  wire              mem_resp_valid,
    input  wire [255:0]      mem_resp_data,
    output wire              mem_fifo_error,

    // performance counters of each core, 14 counters x 32 bits per core
    output wire [NC*14*32-1:0] perf
);
    localparam CB = (NC > 1) ? $clog2(NC) : 1;

    // ---------------- launch registers ----------------
    reg [10:0]  entry;
    reg [31:0]  grid, block;
    reg [127:0] params;

    wire        busy, done, error;
    wire [3:0]  error_code;
    wire [CB-1:0] error_core;
    wire [31:0] kernel_cycles;
    wire        start = reg_we && reg_addr == 4'd0 && reg_wdata[0];

    always @(posedge clk) begin
        if (rst) begin
            entry  <= 0;
            grid   <= 0;
            block  <= 0;
            params <= 0;
        end else if (reg_we && !busy) begin
            case (reg_addr)
                4'd2: entry <= reg_wdata[10:0];
                4'd3: grid  <= reg_wdata;
                4'd4: block <= reg_wdata;
                4'd5: params[ 0 +: 32] <= reg_wdata;
                4'd6: params[32 +: 32] <= reg_wdata;
                4'd7: params[64 +: 32] <= reg_wdata;
                4'd8: params[96 +: 32] <= reg_wdata;
                default: ;
            endcase
        end
    end

    always @(*) begin
        case (reg_addr)
            4'd1:    reg_rdata = {20'd0, {(4-CB){1'b0}}, error_core, error_code,
                                  1'b0, error, done, busy};
            4'd2:    reg_rdata = {21'd0, entry};
            4'd3:    reg_rdata = grid;
            4'd4:    reg_rdata = block;
            4'd5:    reg_rdata = params[ 0 +: 32];
            4'd6:    reg_rdata = params[32 +: 32];
            4'd7:    reg_rdata = params[64 +: 32];
            4'd8:    reg_rdata = params[96 +: 32];
            4'd9:    reg_rdata = kernel_cycles;
            default: reg_rdata = 32'd0;
        endcase
    end

    reg busy_q;
    always @(posedge clk) busy_q <= rst ? 1'b0 : busy;
    assign irq = busy_q && !busy;

    // ---------------- dispatcher ----------------
    wire          l1_inv;
    wire [NC-1:0] launch_valid, launch_ready, block_done, core_err;
    wire [NC*4-1:0] core_err_code;
    wire [31:0]   launch_ctaid;

    block_dispatcher #(.NC(NC), .CB(CB)) disp (
        .clk(clk), .rst(rst), .start(start), .grid(grid),
        .busy(busy), .done(done), .error(error), .error_code(error_code),
        .error_core(error_core), .kernel_cycles(kernel_cycles),
        .l1_inv(l1_inv), .launch_valid(launch_valid), .launch_ready(launch_ready),
        .launch_ctaid(launch_ctaid), .block_done(block_done),
        .core_err(core_err), .core_err_code(core_err_code)
    );

    // ---------------- shader cores ----------------
    wire [NC-1:0]     c_req_valid, c_req_ready, c_req_we, c_resp_valid;
    wire [NC*32-1:0]  c_req_addr;
    wire [NC*8-1:0]   c_req_wmask;
    wire [NC*256-1:0] c_req_wdata;
    wire [255:0]      c_resp_data;

    genvar c;
    generate
        for (c = 0; c < NC; c = c + 1) begin : core
            sm_core #(.NW(NW), .NL(NL), .CORE_ID(c), .SCHED(SCHED)) u_core (
                .clk(clk), .rst(rst),
                .launch_valid(launch_valid[c]), .launch_ready(launch_ready[c]),
                .launch_pc(entry), .l1_inv(l1_inv),
                .launch_ctaid(launch_ctaid), .launch_ntid(block), .launch_nctaid(grid),
                .launch_params(params), .block_done(block_done[c]),
                .imem_en(imem_en[c]), .imem_addr(imem_addr[c*11 +: 11]),
                .imem_rdata(imem_rdata[c*32 +: 32]),
                .dmem_req_valid(c_req_valid[c]), .dmem_req_ready(c_req_ready[c]),
                .dmem_req_we(c_req_we[c]), .dmem_req_addr(c_req_addr[c*32 +: 32]),
                .dmem_req_wmask(c_req_wmask[c*8 +: 8]),
                .dmem_req_wdata(c_req_wdata[c*256 +: 256]),
                .dmem_resp_valid(c_resp_valid[c]), .dmem_resp_data(c_resp_data),
                .err(core_err[c]), .err_code(core_err_code[c*4 +: 4]),
                .perf_cycles       (perf[(c*14 +  0)*32 +: 32]),
                .perf_warp_instrs  (perf[(c*14 +  1)*32 +: 32]),
                .perf_thread_instrs(perf[(c*14 +  2)*32 +: 32]),
                .perf_stall_dep    (perf[(c*14 +  3)*32 +: 32]),
                .perf_stall_mem    (perf[(c*14 +  4)*32 +: 32]),
                .perf_stall_bar    (perf[(c*14 +  5)*32 +: 32]),
                .perf_stall_empty  (perf[(c*14 +  6)*32 +: 32]),
                .perf_diverge      (perf[(c*14 +  7)*32 +: 32]),
                .perf_mem_txn      (perf[(c*14 +  8)*32 +: 32]),
                .perf_l1_hit       (perf[(c*14 +  9)*32 +: 32]),
                .perf_l1_miss      (perf[(c*14 + 10)*32 +: 32]),
                .perf_bank_conflict(perf[(c*14 + 11)*32 +: 32]),
                .perf_fp_instrs    (perf[(c*14 + 12)*32 +: 32]),
                .perf_stall_wb     (perf[(c*14 + 13)*32 +: 32])
            );
        end
    endgenerate

    // ---------------- memory arbiter ----------------
    mem_arbiter #(.NC(NC), .CB(CB)) arb (
        .clk(clk), .rst(rst),
        .c_req_valid(c_req_valid), .c_req_ready(c_req_ready), .c_req_we(c_req_we),
        .c_req_addr(c_req_addr), .c_req_wmask(c_req_wmask), .c_req_wdata(c_req_wdata),
        .c_resp_valid(c_resp_valid), .c_resp_data(c_resp_data),
        .m_req_valid(mem_req_valid), .m_req_ready(mem_req_ready), .m_req_we(mem_req_we),
        .m_req_addr(mem_req_addr), .m_req_wmask(mem_req_wmask), .m_req_wdata(mem_req_wdata),
        .m_resp_valid(mem_resp_valid), .m_resp_data(mem_resp_data),
        .fifo_error(mem_fifo_error)
    );
endmodule

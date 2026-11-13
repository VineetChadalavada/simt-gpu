`timescale 1ns/1ps
`include "isa_defs.vh"

// One shader core (an "SM"): NW warps, NL SIMD lanes.
//
// Pipeline, per warp instruction:
//   IF  the fetch arbiter picks a warp that needs an instruction and sends
//       its PC to the instruction memory (synchronous read).
//   IB  the instruction lands in that warp's 1-entry instruction buffer.
//       A control instruction (jmp, brz, brnz, bar, exit) stops more fetch
//       for the warp until EX resolves it, so the core never fetches a
//       wrong path and never needs a flush.
//   IS  the warp scheduler picks one ready warp (round-robin). Ready means:
//       an instruction in the buffer, no scoreboard hazard, not waiting at
//       a barrier, and a free LSU for a memory instruction. The register
//       file is read for all NL lanes.
//   EX  NL ALUs compute. Results write the register file at the end of EX.
//       Loads and stores go to the LSU, which writes loads back later.
//       FP instructions go into the FPU pipeline (stage 5): NL fma32 units,
//       4 cycles from EX to write-back.
//
// FP32 and write-back (stage 5): the ALU and the FPU share write port 0.
// An FPU result writes 3 cycles after its EX cycle. The issue stage
// reserves the port: an ALU instruction cannot issue if an FP result will
// write in the cycle of its EX (perf_stall_wb counts these cycles). The
// scoreboard handles the variable latency (ALU 1, FPU 4, LSU 2 or more).
//
// Warp scheduler (stage 5): SCHED = 0 loose round-robin (LRR), 1 greedy-
// then-oldest (GTO: keep the same warp while it is ready, else the lowest
// warp number).
//
// Memory (stage 3): the LSU has a coalescer and a 2 KB L1 data cache for
// global memory, and 1 KB of banked shared memory (lds/sts) for the block.
// The global-memory port moves 32-byte lines.
//
// Divergence (stage 2): each warp has a reconvergence stack (simt_stack.v).
// The stack holds the warp's fetch PC and active mask. A divergent branch
// splits the warp in EX; the stack pops in fetch when a path reaches its
// rpc. Each instruction-buffer entry keeps the mask from fetch time, so a
// pop never changes the lanes of an instruction that is already in flight.
//
// There is no forwarding. A dependent instruction from the same warp waits
// one cycle in IS; other warps fill that slot. That is the latency-hiding
// idea of a GPU, and the perf counters measure how well it works.
module sm_core #(
    parameter NW      = 4,
    parameter NL      = 8,
    parameter CORE_ID = 0,
    parameter SCHED   = 0             // 0 = LRR, 1 = GTO
)(
    input  wire          clk,
    input  wire          rst,

    // Block launch, from the block dispatcher
    input  wire          launch_valid,
    output wire          launch_ready,
    input  wire [10:0]   launch_pc,       // kernel entry PC
    input  wire          l1_inv,          // kernel start: invalidate the L1
    input  wire [31:0]   launch_ctaid,
    input  wire [31:0]   launch_ntid,
    input  wire [31:0]   launch_nctaid,
    input  wire [127:0]  launch_params,
    output reg           block_done,

    // Instruction memory, synchronous read
    output wire          imem_en,
    output wire [10:0]   imem_addr,
    input  wire [31:0]   imem_rdata,

    // Data memory: 32-byte lines, a word mask for writes
    output wire          dmem_req_valid,
    input  wire          dmem_req_ready,
    output wire          dmem_req_we,
    output wire [31:0]   dmem_req_addr,
    output wire [7:0]    dmem_req_wmask,
    output wire [255:0]  dmem_req_wdata,
    input  wire          dmem_resp_valid,
    input  wire [255:0]  dmem_resp_data,

    output reg           err,
    output reg  [3:0]    err_code,

    // Performance counters (count while a block runs)
    output reg  [31:0]   perf_cycles,
    output reg  [31:0]   perf_warp_instrs,
    output reg  [31:0]   perf_thread_instrs,
    output reg  [31:0]   perf_stall_dep,     // a warp has an instruction, but a register is pending
    output reg  [31:0]   perf_stall_mem,     // a warp has a memory instruction, but the LSU is busy
    output reg  [31:0]   perf_stall_bar,     // warps wait at a barrier
    output reg  [31:0]   perf_stall_empty,   // no instruction buffer has an instruction
    output reg  [31:0]   perf_diverge,       // divergent branches
    output reg  [31:0]   perf_mem_txn,       // global transactions (32-byte lines)
    output reg  [31:0]   perf_l1_hit,        // load transactions that hit in L1
    output reg  [31:0]   perf_l1_miss,       // load transactions that miss
    output reg  [31:0]   perf_bank_conflict, // extra shared-memory cycles
    output reg  [31:0]   perf_fp_instrs,     // FP warp instructions
    output reg  [31:0]   perf_stall_wb       // an ALU instruction waits for write port 0
);
    localparam WB = (NW > 1) ? $clog2(NW) : 1;
    localparam D  = 8;            // reconvergence stack entries per warp
    localparam SMEM_WORDS = 256;  // 1 KB shared memory

    // ------------------------------------------------------------------
    // Block and warp state
    // ------------------------------------------------------------------
    reg            running;
    reg [31:0]     ctaid, ntid, nctaid;
    reg [127:0]    params;        // param0..param3

    reg [NW-1:0]   w_active;      // warp launched and not exited
    reg [NW-1:0]   ib_valid;      // instruction buffer full
    reg [NW-1:0]   f_pend;        // fetch in flight
    reg [NW-1:0]   ctrl_wait;     // control instruction fetched, not resolved
    reg [NW-1:0]   bar_wait;      // waiting at a barrier
    reg [31:0]     ib_instr [0:NW-1];
    reg [NL-1:0]   ib_mask  [0:NW-1];  // active lanes at fetch time

    // From the reconvergence stacks
    wire [NW*11-1:0] st_pc;           // next PC to fetch
    wire [NW*NL-1:0] st_mask;         // active lanes of the current path
    wire [NW*NL-1:0] st_alive;        // lanes that have not exited
    wire [NW-1:0]    st_need_pop, st_at_base, st_ovf;

    assign launch_ready = !running && !err;
    wire launch = launch_valid && launch_ready;

    // ------------------------------------------------------------------
    // Decode every instruction buffer (the scheduler needs all of them)
    // ------------------------------------------------------------------
    wire [NW*4-1:0] dw_ra, dw_rb, dw_rc, dw_rd;
    wire [NW-1:0]   dw_use_ra, dw_use_rb, dw_use_rc, dw_wr_rd, dw_mem;
    wire [NW-1:0]   dw_alu, dw_s2r, dw_fp;

    genvar gw;
    generate
        for (gw = 0; gw < NW; gw = gw + 1) begin : ibdec
            decode d (
                .instr(ib_instr[gw]),
                .is_alu(dw_alu[gw]), .alu_op(), .alu_imm(), .is_ld(), .is_st(),
                .is_s2r(dw_s2r[gw]),
                .is_jmp(), .is_br(), .br_nz(), .is_bar(), .is_exit(), .is_ctrl(),
                .is_mem(dw_mem[gw]), .is_shared(), .is_fp(dw_fp[gw]), .fp_op(), .illegal(),
                .rd(dw_rd[gw*4 +: 4]), .ra(dw_ra[gw*4 +: 4]), .rb(dw_rb[gw*4 +: 4]),
                .rc(dw_rc[gw*4 +: 4]),
                .use_ra(dw_use_ra[gw]), .use_rb(dw_use_rb[gw]), .use_rc(dw_use_rc[gw]),
                .wr_rd(dw_wr_rd[gw]),
                .imm(), .target(), .rpc(), .sreg()
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // Scoreboard and the ready check
    // ------------------------------------------------------------------
    wire [NW*16-1:0] pending;
    wire [NW-1:0]    hazard;
    wire [NW-1:0]    ready;

    reg              e_valid;
    wire             e_is_mem;
    wire             lsu_busy;
    wire             lsu_free = !lsu_busy && !(e_valid && e_is_mem);

    // FPU pipeline control: v1..v3 = an FP instruction is 1..3 cycles past EX
    reg              fp_v1, fp_v2, fp_v3;
    // ALU-type instructions that write port 0 in their EX cycle
    wire [NW-1:0]    dw_p0 = (dw_alu | dw_s2r) & dw_wr_rd;

    generate
        for (gw = 0; gw < NW; gw = gw + 1) begin : rdy
            assign hazard[gw] = (dw_use_ra[gw] && pending[gw*16 + dw_ra[gw*4 +: 4]])
                              | (dw_use_rb[gw] && pending[gw*16 + dw_rb[gw*4 +: 4]])
                              | (dw_use_rc[gw] && pending[gw*16 + dw_rc[gw*4 +: 4]])
                              | (dw_wr_rd[gw]  && pending[gw*16 + dw_rd[gw*4 +: 4]]);
            // fp_v2 now = an FP result writes port 0 next cycle, which is
            // the EX cycle of an instruction that issues now
            assign ready[gw]  = w_active[gw] && ib_valid[gw] && !bar_wait[gw] && !hazard[gw]
                              && (!dw_mem[gw] || lsu_free)
                              && !(dw_p0[gw] && fp_v2);
        end
    endgenerate

    // ------------------------------------------------------------------
    // Warp scheduler (issue) and fetch arbiter
    // ------------------------------------------------------------------
    wire          i_go;
    wire [WB-1:0] i_w;
    wire [NW-1:0] i_req = (running && !err) ? ready : {NW{1'b0}};
    generate
        if (SCHED == 1) begin : gto
            gto_arb #(.N(NW), .WB(WB)) issue_arb (
                .clk(clk), .rst(rst), .req(i_req), .take(1'b1), .gnt_valid(i_go), .gnt(i_w)
            );
        end else begin : lrr
            rr_arb #(.N(NW), .WB(WB)) issue_arb (
                .clk(clk), .rst(rst), .req(i_req), .take(1'b1), .gnt_valid(i_go), .gnt(i_w)
            );
        end
    endgenerate
    wire [NW-1:0] issue_oh = i_go ? ({{NW-1{1'b0}}, 1'b1} << i_w) : {NW{1'b0}};

    wire [NW-1:0] f_req = (running && !err)
                        ? (w_active & ~f_pend & ~ctrl_wait & ~st_need_pop
                           & (~ib_valid | issue_oh))
                        : {NW{1'b0}};
    wire          f_go;
    wire [WB-1:0] f_w;
    rr_arb #(.N(NW), .WB(WB)) fetch_arb (
        .clk(clk), .rst(rst), .req(f_req), .take(1'b1), .gnt_valid(f_go), .gnt(f_w)
    );
    assign imem_en   = f_go;
    assign imem_addr = st_pc[f_w*11 +: 11];

    reg           f_v;            // imem_rdata is valid this cycle
    reg [WB-1:0]  f_wq;
    reg [NL-1:0]  f_maskq;
    wire          ret_ctrl;
    decode fdec (
        .instr(imem_rdata),
        .is_alu(), .alu_op(), .alu_imm(), .is_ld(), .is_st(), .is_s2r(),
        .is_jmp(), .is_br(), .br_nz(), .is_bar(), .is_exit(), .is_ctrl(ret_ctrl),
        .is_mem(), .is_shared(), .is_fp(), .fp_op(), .illegal(), .rd(), .ra(), .rb(), .rc(),
        .use_ra(), .use_rb(), .use_rc(), .wr_rd(),
        .imm(), .target(), .rpc(), .sreg()
    );

    // ------------------------------------------------------------------
    // EX stage registers and decode
    // ------------------------------------------------------------------
    reg [WB-1:0]    e_w;
    reg [31:0]      e_instr;
    reg [NL-1:0]    e_mask;
    reg [NL*32-1:0] e_a, e_b, e_c;

    wire        e_is_alu, e_alu_imm, e_is_ld, e_is_st, e_is_s2r, e_is_jmp, e_is_br;
    wire        e_br_nz, e_is_bar, e_is_exit, e_illegal, e_wr_rd, e_is_shared, e_is_fp;
    wire [1:0]  e_fp_op;
    wire [3:0]  e_alu_op, e_rd, e_sreg;
    wire [31:0] e_imm;
    wire [10:0] e_target, e_rpc;
    decode edec (
        .instr(e_instr),
        .is_alu(e_is_alu), .alu_op(e_alu_op), .alu_imm(e_alu_imm), .is_ld(e_is_ld),
        .is_st(e_is_st), .is_s2r(e_is_s2r), .is_jmp(e_is_jmp), .is_br(e_is_br),
        .br_nz(e_br_nz), .is_bar(e_is_bar), .is_exit(e_is_exit), .is_ctrl(),
        .is_mem(e_is_mem), .is_shared(e_is_shared), .is_fp(e_is_fp), .fp_op(e_fp_op),
        .illegal(e_illegal), .rd(e_rd), .ra(), .rb(), .rc(),
        .use_ra(), .use_rb(), .use_rc(), .wr_rd(e_wr_rd), .imm(e_imm), .target(e_target),
        .rpc(e_rpc), .sreg(e_sreg)
    );

    // ------------------------------------------------------------------
    // The SIMD lanes: register file slice + ALU + address + branch test
    // ------------------------------------------------------------------
    wire [NL*32-1:0] rf_a, rf_b, rf_c; // operands of the issuing warp
    wire [NL*32-1:0] lane_addr;
    wire [NL-1:0]    lane_mis;        // misaligned address
    wire [NL-1:0]    lane_oob;        // shared address out of range
    wire [NL-1:0]    lane_cond;       // branch condition per lane

    wire             lsu_wb_valid;
    wire [WB-1:0]    lsu_wb_w;
    wire [3:0]       lsu_wb_rd;
    wire [NL-1:0]    lsu_wb_mask;
    wire [NL*32-1:0] lsu_wb_data;

    wire e_writes = e_valid && (e_is_alu || e_is_s2r) && e_wr_rd;

    // FPU pipeline: warp, register and lanes of the result in flight
    reg [WB-1:0]  fp_w1, fp_w2, fp_w3;
    reg [3:0]     fp_rd1, fp_rd2, fp_rd3;
    reg [NL-1:0]  fp_m1, fp_m2, fp_m3;
    reg           fp_we1, fp_we2, fp_we3;
    wire          fp_wb = fp_v3 && fp_we3;            // an FP result writes port 0 now

    genvar gl;
    generate
        for (gl = 0; gl < NL; gl = gl + 1) begin : lane
            wire [31:0] a = e_a[gl*32 +: 32];
            wire [31:0] b = e_alu_imm ? e_imm : e_b[gl*32 +: 32];
            wire [31:0] y;
            alu u_alu (.op(e_alu_op), .a(a), .b(b), .y(y));

            // FPU lane: every FP instruction is one fused multiply-add
            wire [31:0] rb_v = e_b[gl*32 +: 32];
            reg  [31:0] fb, fc;
            always @(*) begin
                case (e_fp_op)
                    2'd0:    begin fb = 32'h3F800000; fc = rb_v;                end  // a*1 + b
                    2'd1:    begin fb = 32'h3F800000; fc = rb_v ^ 32'h80000000; end  // a*1 - b
                    2'd2:    begin fb = rb_v;         fc = 32'h80000000;        end  // a*b + (-0)
                    default: begin fb = rb_v;         fc = e_c[gl*32 +: 32];    end  // a*b + c
                endcase
            end
            wire [31:0] fy;
            fma32 u_fma (.clk(clk), .a(a), .b(fb), .c(fc), .y(fy));

            reg [31:0] sv;
            always @(*) begin
                case (e_sreg)
                    `SR_TID:    sv = e_w * NL + gl;
                    `SR_CTAID:  sv = ctaid;
                    `SR_NTID:   sv = ntid;
                    `SR_NCTAID: sv = nctaid;
                    `SR_LANEID: sv = gl;
                    `SR_WARPID: sv = e_w;
                    `SR_COREID: sv = CORE_ID;
                    4'd8, 4'd9, 4'd10, 4'd11: sv = params[e_sreg[1:0]*32 +: 32];
                    default:    sv = 32'd0;
                endcase
            end

            assign lane_addr[gl*32 +: 32] = a + e_imm;
            assign lane_mis[gl]  = e_mask[gl] && (lane_addr[gl*32 +: 2] != 2'b00);
            assign lane_oob[gl]  = e_mask[gl] && e_is_shared
                                && (lane_addr[gl*32 +: 32] >= SMEM_WORDS * 4);
            assign lane_cond[gl] = e_br_nz ? (a != 0) : (a == 0);

            regfile_lane #(.NW(NW), .WB(WB)) rf (
                .clk(clk),
                .rw(i_w), .ra(dw_ra[i_w*4 +: 4]), .rb(dw_rb[i_w*4 +: 4]),
                .rc(dw_rc[i_w*4 +: 4]),
                .da(rf_a[gl*32 +: 32]), .db(rf_b[gl*32 +: 32]), .dc(rf_c[gl*32 +: 32]),
                .we0((e_writes && e_mask[gl]) || (fp_wb && fp_m3[gl])),
                .ww0(fp_wb ? fp_w3 : e_w), .wr0(fp_wb ? fp_rd3 : e_rd),
                .wd0(fp_wb ? fy : e_is_s2r ? sv : y),
                .we1(lsu_wb_valid && lsu_wb_mask[gl]), .ww1(lsu_wb_w), .wr1(lsu_wb_rd),
                .wd1(lsu_wb_data[gl*32 +: 32])
            );
        end
    endgenerate

    scoreboard #(.NW(NW), .WB(WB)) sb (
        .clk(clk), .clear_all(launch),
        .set_en(i_go && dw_wr_rd[i_w]), .set_w(i_w), .set_r(dw_rd[i_w*4 +: 4]),
        .clr0_en(e_writes || fp_wb), .clr0_w(fp_wb ? fp_w3 : e_w),
        .clr0_r(fp_wb ? fp_rd3 : e_rd),
        .clr1_en(lsu_wb_valid), .clr1_w(lsu_wb_w), .clr1_r(lsu_wb_rd),
        .pending(pending)
    );

    // ------------------------------------------------------------------
    // Load/store unit
    // ------------------------------------------------------------------
    wire mis_any = |lane_mis;
    wire oob_any = |lane_oob;
    wire ev_txn, ev_hit, ev_miss, ev_bank_conflict;
    lsu #(.NL(NL), .WB(WB), .SMEM_WORDS(SMEM_WORDS)) u_lsu (
        .clk(clk), .rst(rst), .l1_inv(l1_inv),
        .in_valid(e_valid && e_is_mem && !mis_any && !oob_any && !err),
        .in_store(e_is_st), .in_shared(e_is_shared),
        .in_w(e_w), .in_rd(e_rd), .in_mask(e_mask), .in_addr(lane_addr), .in_wdata(e_b),
        .busy(lsu_busy),
        .mem_req_valid(dmem_req_valid), .mem_req_ready(dmem_req_ready),
        .mem_req_we(dmem_req_we), .mem_req_addr(dmem_req_addr),
        .mem_req_wmask(dmem_req_wmask), .mem_req_wdata(dmem_req_wdata),
        .mem_resp_valid(dmem_resp_valid), .mem_resp_data(dmem_resp_data),
        .wb_valid(lsu_wb_valid), .wb_w(lsu_wb_w), .wb_rd(lsu_wb_rd),
        .wb_mask(lsu_wb_mask), .wb_data(lsu_wb_data),
        .ev_txn(ev_txn), .ev_hit(ev_hit), .ev_miss(ev_miss),
        .ev_bank_conflict(ev_bank_conflict)
    );

    // ------------------------------------------------------------------
    // Branch resolution
    // ------------------------------------------------------------------
    wire [NL-1:0] taken   = lane_cond & e_mask;
    wire          br_all  = (taken == e_mask);
    wire          br_none = (taken == {NL{1'b0}});
    wire          ex_ctl  = e_valid && !err;
    wire          e_div   = e_is_br && !br_all && !br_none;

    // ------------------------------------------------------------------
    // Reconvergence stacks, one per warp
    // ------------------------------------------------------------------
    generate
        for (gw = 0; gw < NW; gw = gw + 1) begin : stk
            wire          me = ex_ctl && (e_w == gw);
            wire [NL-1:0] init_mask;
            genvar k;
            for (k = 0; k < NL; k = k + 1) begin : im
                assign init_mask[k] = (gw * NL + k < launch_ntid);
            end
            simt_stack #(.NL(NL), .D(D)) st (
                .clk(clk),
                .init(launch), .init_mask(init_mask), .init_pc(launch_pc),
                .fetch(f_go && f_w == gw),
                .jump(me && (e_is_jmp || (e_is_br && br_all))), .jump_pc(e_target),
                .div(me && e_div && !st_ovf[gw]),
                .div_target(e_target), .div_rpc(e_rpc), .div_taken(taken),
                .div_overflow(st_ovf[gw]),
                .exit(me && e_is_exit), .exit_mask(e_mask),
                .pop(running && !err && w_active[gw] && st_need_pop[gw]
                     && !ctrl_wait[gw] && !f_pend[gw]),
                .pc(st_pc[gw*11 +: 11]), .mask(st_mask[gw*NL +: NL]),
                .need_pop(st_need_pop[gw]), .at_base(st_at_base[gw]),
                .alive(st_alive[gw*NL +: NL])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // Sequential control
    // ------------------------------------------------------------------
    integer w;
    always @(posedge clk) begin
        block_done <= 1'b0;
        if (rst) begin
            running   <= 1'b0;
            w_active  <= 0;
            ib_valid  <= 0;
            f_pend    <= 0;
            ctrl_wait <= 0;
            bar_wait  <= 0;
            e_valid   <= 1'b0;
            f_v       <= 1'b0;
            fp_v1     <= 1'b0;
            fp_v2     <= 1'b0;
            fp_v3     <= 1'b0;
            err       <= 1'b0;
            err_code  <= 4'd0;
        end else begin
            // ---- launch a block ----
            if (launch) begin
                running <= 1'b1;
                ctaid   <= launch_ctaid;
                ntid    <= launch_ntid;
                nctaid  <= launch_nctaid;
                params  <= launch_params;
                ib_valid  <= 0;
                f_pend    <= 0;
                ctrl_wait <= 0;
                bar_wait  <= 0;
                for (w = 0; w < NW; w = w + 1)
                    w_active[w] <= (w * NL < launch_ntid);
            end

            // ---- IS: issue one warp instruction ----
            e_valid <= i_go;
            if (i_go) begin
                ib_valid[i_w] <= 1'b0;
                e_w     <= i_w;
                e_instr <= ib_instr[i_w];
                e_mask  <= ib_mask[i_w];
                e_a     <= rf_a;
                e_b     <= rf_b;
                e_c     <= rf_c;
            end

            // ---- FPU pipeline control ----
            fp_v1  <= e_valid && e_is_fp && !err;
            fp_w1  <= e_w;   fp_rd1 <= e_rd;   fp_m1 <= e_mask; fp_we1 <= e_wr_rd;
            fp_v2  <= fp_v1;
            fp_w2  <= fp_w1; fp_rd2 <= fp_rd1; fp_m2 <= fp_m1;  fp_we2 <= fp_we1;
            fp_v3  <= fp_v2;
            fp_w3  <= fp_w2; fp_rd3 <= fp_rd2; fp_m3 <= fp_m2;  fp_we3 <= fp_we2;

            // ---- IF: send a fetch ----
            f_v <= f_go;
            if (f_go) begin
                f_pend[f_w] <= 1'b1;
                f_wq        <= f_w;
                f_maskq     <= st_mask[f_w*NL +: NL];
            end

            // ---- IB: the fetched instruction arrives ----
            if (f_v) begin
                ib_valid[f_wq] <= 1'b1;
                ib_instr[f_wq] <= imem_rdata;
                ib_mask[f_wq]  <= f_maskq;
                f_pend[f_wq]   <= 1'b0;
                if (ret_ctrl) ctrl_wait[f_wq] <= 1'b1;
            end

            // ---- EX: resolve control instructions ----
            // The PC and mask changes happen in the warp's simt_stack.
            if (ex_ctl) begin
                if (e_is_jmp || e_is_br || e_is_bar || e_is_exit)
                    ctrl_wait[e_w] <= 1'b0;
                if (e_is_bar)
                    bar_wait[e_w] <= 1'b1;
                if (e_is_exit && (st_alive[e_w*NL +: NL] & ~e_mask) == 0)
                    w_active[e_w] <= 1'b0;          // the last lanes of the warp exit

                if (e_illegal) begin
                    err <= 1'b1; err_code <= `ERR_ILLEGAL;
                end else if (e_div && st_ovf[e_w]) begin
                    err <= 1'b1; err_code <= `ERR_STACK;
                end else if (e_is_bar && !st_at_base[e_w]) begin
                    err <= 1'b1; err_code <= `ERR_BAR_DIV;
                end else if (e_is_mem && mis_any) begin
                    err <= 1'b1; err_code <= `ERR_MISALIGNED;
                end else if (e_is_mem && oob_any) begin
                    err <= 1'b1; err_code <= `ERR_SMEM_RANGE;
                end
            end

            // ---- barrier: release when every live warp has arrived ----
            if (running && (bar_wait != 0) && ((bar_wait | ~w_active) == {NW{1'b1}}))
                bar_wait <= 0;

            // ---- block done: all warps exited and the pipeline is empty ----
            if (running && w_active == 0 && !e_valid && !lsu_busy && f_pend == 0 && !f_v
                && !fp_v1 && !fp_v2 && !fp_v3) begin
                running    <= 1'b0;
                block_done <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Performance counters
    // ------------------------------------------------------------------
    function [31:0] popcount;
        input [NL-1:0] m;
        integer j;
        begin
            popcount = 0;
            for (j = 0; j < NL; j = j + 1) popcount = popcount + m[j];
        end
    endfunction

    wire [NW-1:0] has_instr = w_active & ib_valid & ~bar_wait;

    always @(posedge clk) begin
        if (rst) begin
            perf_cycles <= 0; perf_warp_instrs <= 0; perf_thread_instrs <= 0;
            perf_stall_dep <= 0; perf_stall_mem <= 0; perf_stall_bar <= 0;
            perf_stall_empty <= 0; perf_diverge <= 0;
            perf_mem_txn <= 0; perf_l1_hit <= 0; perf_l1_miss <= 0; perf_bank_conflict <= 0;
            perf_fp_instrs <= 0; perf_stall_wb <= 0;
        end else if (running) begin
            perf_cycles <= perf_cycles + 1;
            if (ev_txn)           perf_mem_txn       <= perf_mem_txn + 1;
            if (ev_hit)           perf_l1_hit        <= perf_l1_hit + 1;
            if (ev_miss)          perf_l1_miss       <= perf_l1_miss + 1;
            if (ev_bank_conflict) perf_bank_conflict <= perf_bank_conflict + 1;
            if (ex_ctl && e_div)
                perf_diverge <= perf_diverge + 1;
            if (i_go) begin
                perf_warp_instrs   <= perf_warp_instrs + 1;
                perf_thread_instrs <= perf_thread_instrs + popcount(ib_mask[i_w]);
                if (dw_fp[i_w]) perf_fp_instrs <= perf_fp_instrs + 1;
            end else if (|(has_instr & hazard))
                perf_stall_dep <= perf_stall_dep + 1;
            else if (|(has_instr & dw_mem))
                perf_stall_mem <= perf_stall_mem + 1;
            else if (|(has_instr & dw_p0) && fp_v2)
                perf_stall_wb <= perf_stall_wb + 1;
            else if (|bar_wait)
                perf_stall_bar <= perf_stall_bar + 1;
            else
                perf_stall_empty <= perf_stall_empty + 1;
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk)
        if (!rst && e_writes && fp_wb)
            $display("ERROR: core %0d: ALU and FPU write port 0 in the same cycle", CORE_ID);
`endif
endmodule

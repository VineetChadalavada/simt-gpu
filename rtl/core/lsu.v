`timescale 1ns/1ps

// Load/store unit, stage 3 version. One warp instruction at a time.
//
// Global memory (ld, st): a coalescer and an L1 data cache.
//   Each cycle the coalescer takes the lowest lane that still waits (the
//   leader) and groups all waiting lanes in the same 32-byte line. The
//   group is one transaction:
//     load hit   the lanes take their words from the cache line (1 cycle)
//     load miss  read the line from memory, fill the cache, and give the
//                lanes their words from the returned line
//     store      write the line to memory with a word mask (write-through);
//                if the line is in the cache, update it there too
//   A fully coalesced warp (8 lanes, 8 consecutive words) is 1 transaction.
//   One miss at a time: the unit waits for the line before it goes on.
//
// Shared memory (lds, sts): 8 banks of one word, with conflict handling.
//   Each cycle, each bank serves the word of its lowest waiting lane, and
//   all lanes that want that same word (broadcast). Lanes that want a
//   different word in the same bank wait for a later cycle: a bank
//   conflict. The smem banks have a synchronous read, so the data of the
//   lanes served in one cycle arrives in the next cycle.
//
// When two lanes store to the same word in one instruction, the highest
// lane wins, in global and in shared memory (the golden model does the same).
//
// A load writes all lanes to the register file in one cycle at the end.
module lsu #(
    parameter NL         = 8,
    parameter WB         = 2,
    parameter SETS       = 32,       // L1: SETS x 2 ways x 32 bytes
    parameter SMEM_WORDS = 256       // shared memory: 1 KB in 8 banks
)(
    input  wire           clk,
    input  wire           rst,
    input  wire           l1_inv,       // invalidate the L1 (only when idle)
    // from EX (only when busy == 0)
    input  wire           in_valid,
    input  wire           in_store,
    input  wire           in_shared,
    input  wire [WB-1:0]  in_w,
    input  wire [3:0]     in_rd,
    input  wire [NL-1:0]  in_mask,
    input  wire [NL*32-1:0] in_addr,
    input  wire [NL*32-1:0] in_wdata,
    output reg            busy,
    // memory port: 32-byte lines, valid/ready requests, in-order read responses
    output wire           mem_req_valid,
    input  wire           mem_req_ready,
    output wire           mem_req_we,
    output wire [31:0]    mem_req_addr,
    output wire [7:0]     mem_req_wmask,
    output wire [255:0]   mem_req_wdata,
    input  wire           mem_resp_valid,
    input  wire [255:0]   mem_resp_data,
    // register write-back (one cycle pulse at the end of a load)
    output wire           wb_valid,
    output reg  [WB-1:0]  wb_w,
    output reg  [3:0]     wb_rd,
    output reg  [NL-1:0]  wb_mask,
    output reg  [NL*32-1:0] wb_data,
    // events for the perf counters (one cycle each)
    output wire           ev_txn,             // a global transaction starts
    output wire           ev_hit,             // a load transaction hits in L1
    output wire           ev_miss,            // a load transaction misses
    output wire           ev_bank_conflict    // an extra shared-memory cycle
);
    localparam LB   = (NL > 1) ? $clog2(NL) : 1;
    localparam NB   = 8;                       // shared-memory banks
    localparam ROWS = SMEM_WORDS / NB;
    localparam RB   = $clog2(ROWS);

    localparam S_GLOBAL = 2'd0, S_FILL_REQ = 2'd1, S_FILL_WAIT = 2'd2, S_SHARED = 2'd3;

    reg [1:0]       state;
    reg             store;
    reg             first;            // shared: the first bank cycle
    reg [NL-1:0]    left;             // lanes that are not served yet
    reg [NL-1:0]    rd_pend;          // shared loads: bank data arrives this cycle
    reg [NL*32-1:0] addr, wdata;

    function [LB-1:0] lowest;
        input [NL-1:0] m;
        integer j;
        begin
            lowest = 0;
            for (j = NL - 1; j >= 0; j = j - 1)
                if (m[j]) lowest = j[LB-1:0];
        end
    endfunction

    integer lg, lb, lw;              // one loop variable per always block

    // ------------------------------------------------------------------
    // Coalescer: the leader's line and the lanes in it
    // ------------------------------------------------------------------
    wire [LB-1:0] lead      = lowest(left);
    wire [26:0]   lead_line = addr[lead*32 + 5 +: 27];

    reg [NL-1:0]  group;
    reg [7:0]     line_wmask;
    reg [255:0]   line_wdata;
    always @(*) begin
        group      = 0;
        line_wmask = 0;
        line_wdata = 0;
        for (lg = 0; lg < NL; lg = lg + 1)
            if (left[lg] && addr[lg*32 + 5 +: 27] == lead_line) begin
                group[lg] = 1'b1;
                line_wmask[addr[lg*32 + 2 +: 3]] = 1'b1;
                line_wdata[addr[lg*32 + 2 +: 3]*32 +: 32] = wdata[lg*32 +: 32];  // higher lane overwrites
            end
    end

    // ------------------------------------------------------------------
    // L1 cache and the global-memory control
    // ------------------------------------------------------------------
    wire         c_hit;
    wire [255:0] c_data;

    wire g_go      = busy && state == S_GLOBAL && left != 0;
    wire g_ld_hit  = g_go && !store && c_hit;
    wire g_ld_miss = g_go && !store && !c_hit;
    wire g_st_go   = g_go && store && mem_req_ready;
    wire fill      = busy && state == S_FILL_WAIT && mem_resp_valid;

    l1_cache #(.SETS(SETS)) l1 (
        .clk(clk), .rst(rst), .inv(l1_inv), .line(lead_line), .hit(c_hit), .hit_data(c_data),
        .touch(g_ld_hit), .wr_en(g_st_go), .wr_mask(line_wmask), .wr_data(line_wdata),
        .fill_en(fill), .fill_data(mem_resp_data)
    );

    assign mem_req_valid = (g_go && store) || (busy && state == S_FILL_REQ);
    assign mem_req_we    = store;
    assign mem_req_addr  = {lead_line, 5'b0};
    assign mem_req_wmask = line_wmask;
    assign mem_req_wdata = line_wdata;

    // The line that a load group reads: from the cache, or from memory on a fill
    wire [255:0] ld_line = fill ? mem_resp_data : c_data;

    // ------------------------------------------------------------------
    // Shared memory: one leader per bank, and the lanes that share its word
    // ------------------------------------------------------------------
    reg [NL-1:0]    serve;
    reg [NB-1:0]    b_en;
    reg [NB*RB-1:0] b_row;
    reg [NB*32-1:0] b_wdata;
    always @(*) begin
        serve = 0; b_en = 0; b_row = 0; b_wdata = 0;
        for (lb = NL - 1; lb >= 0; lb = lb - 1)          // the lowest lane is written last
            if (left[lb]) begin
                b_en[addr[lb*32 + 2 +: 3]] = 1'b1;
                b_row[addr[lb*32 + 2 +: 3]*RB +: RB] = addr[lb*32 + 5 +: RB];
            end
        for (lb = 0; lb < NL; lb = lb + 1)
            if (left[lb] && addr[lb*32 + 5 +: RB] == b_row[addr[lb*32 + 2 +: 3]*RB +: RB]) begin
                serve[lb] = 1'b1;
                b_wdata[addr[lb*32 + 2 +: 3]*32 +: 32] = wdata[lb*32 +: 32];  // higher lane overwrites
            end
    end

    wire s_go = busy && state == S_SHARED && left != 0;
    wire [NB*32-1:0] s_rdata;

    smem #(.NB(NB), .ROWS(ROWS)) u_smem (
        .clk(clk), .en(s_go ? b_en : {NB{1'b0}}), .we(store),
        .row(b_row), .wdata(b_wdata), .rdata(s_rdata)
    );

    // ------------------------------------------------------------------
    // Done, write-back, events
    // ------------------------------------------------------------------
    wire done = busy && left == 0 && rd_pend == 0
             && (state == S_GLOBAL || state == S_SHARED);
    assign wb_valid = done && !store;

    assign ev_txn           = g_ld_hit || g_ld_miss || g_st_go;
    assign ev_hit           = g_ld_hit;
    assign ev_miss          = g_ld_miss;
    assign ev_bank_conflict = s_go && !first;

    always @(posedge clk) begin
        if (rst) begin
            busy    <= 1'b0;
            left    <= 0;
            rd_pend <= 0;
            state   <= S_GLOBAL;
        end else if (!busy) begin
            if (in_valid) begin
                busy    <= 1'b1;
                state   <= in_shared ? S_SHARED : S_GLOBAL;
                store   <= in_store;
                first   <= 1'b1;
                left    <= in_mask;
                rd_pend <= 0;
                addr    <= in_addr;
                wdata   <= in_wdata;
                wb_w    <= in_w;
                wb_rd   <= in_rd;
                wb_mask <= in_mask;
            end
        end else if (done) begin
            busy <= 1'b0;
        end else begin
            case (state)
                S_GLOBAL: begin
                    if (g_ld_hit || g_st_go)
                        left <= left & ~group;
                    if (g_ld_miss)
                        state <= S_FILL_REQ;
                end
                S_FILL_REQ:
                    if (mem_req_ready) state <= S_FILL_WAIT;
                S_FILL_WAIT:
                    if (fill) begin
                        left  <= left & ~group;
                        state <= S_GLOBAL;
                    end
                S_SHARED: begin
                    if (s_go) begin
                        left  <= left & ~serve;
                        first <= 1'b0;
                    end
                    rd_pend <= (s_go && !store) ? serve : {NL{1'b0}};
                end
            endcase

            // load data into the lanes
            for (lw = 0; lw < NL; lw = lw + 1) begin
                if ((g_ld_hit || fill) && group[lw])
                    wb_data[lw*32 +: 32] <= ld_line[addr[lw*32 + 2 +: 3]*32 +: 32];
                if (rd_pend[lw])
                    wb_data[lw*32 +: 32] <= s_rdata[addr[lw*32 + 2 +: 3]*32 +: 32];
            end
        end
    end
endmodule

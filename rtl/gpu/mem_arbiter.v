`timescale 1ns/1ps

// Memory arbiter: NC core ports -> one global-memory port.
//
// Requests: round-robin between the cores that have a request. The winner
// sees ready when memory accepts. A read also puts the core number into a
// FIFO. Memory returns read data in order, so the head of the FIFO tells
// which core gets each response. Writes have no response.
//
// Each core has a maximum of one read in flight (the L1 miss is blocking),
// so the FIFO never holds more than NC entries.
module mem_arbiter #(
    parameter NC = 2,
    parameter CB = 1                 // core index width
)(
    input  wire              clk,
    input  wire              rst,
    // core side
    input  wire [NC-1:0]     c_req_valid,
    output wire [NC-1:0]     c_req_ready,
    input  wire [NC-1:0]     c_req_we,
    input  wire [NC*32-1:0]  c_req_addr,
    input  wire [NC*8-1:0]   c_req_wmask,
    input  wire [NC*256-1:0] c_req_wdata,
    output wire [NC-1:0]     c_resp_valid,
    output wire [255:0]      c_resp_data,     // the same data to every core
    // memory side
    output wire              m_req_valid,
    input  wire              m_req_ready,
    output wire              m_req_we,
    output wire [31:0]       m_req_addr,
    output wire [7:0]        m_req_wmask,
    output wire [255:0]      m_req_wdata,
    input  wire              m_resp_valid,
    input  wire [255:0]      m_resp_data,
    output wire              fifo_error       // a response with no read in flight
);
    localparam FD = NC;               // FIFO depth
    localparam FB = (FD > 1) ? $clog2(FD) : 1;

    wire          g_valid;
    wire [CB-1:0] g;
    rr_arb #(.N(NC), .WB(CB)) arb (
        .clk(clk), .rst(rst), .req(c_req_valid),
        .take(m_req_ready), .gnt_valid(g_valid), .gnt(g)
    );

    assign m_req_valid = g_valid;
    assign m_req_we    = c_req_we[g];
    assign m_req_addr  = c_req_addr[g*32 +: 32];
    assign m_req_wmask = c_req_wmask[g*8 +: 8];
    assign m_req_wdata = c_req_wdata[g*256 +: 256];
    assign c_req_ready = (g_valid && m_req_ready) ? ({{NC-1{1'b0}}, 1'b1} << g) : {NC{1'b0}};

    // ---- FIFO of the cores that wait for read data ----
    reg [CB-1:0] fifo [0:FD-1];
    reg [FB-1:0] rp, wp;
    reg [FB:0]   cnt;

    wire push = g_valid && m_req_ready && !m_req_we;
    wire pop  = m_resp_valid;

    assign c_resp_valid = (pop && cnt != 0) ? ({{NC-1{1'b0}}, 1'b1} << fifo[rp]) : {NC{1'b0}};
    assign c_resp_data  = m_resp_data;
    assign fifo_error   = pop && cnt == 0;

    always @(posedge clk) begin
        if (rst) begin
            rp <= 0; wp <= 0; cnt <= 0;
        end else begin
            if (push) begin
                fifo[wp] <= g;
                wp <= (wp == FD - 1) ? 0 : wp + 1;
            end
            if (pop && cnt != 0)
                rp <= (rp == FD - 1) ? 0 : rp + 1;
            cnt <= cnt + push - (pop && cnt != 0);
        end
    end
endmodule

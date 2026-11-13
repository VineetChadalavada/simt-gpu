`timescale 1ns/1ps

// L1 data cache: SETS sets x 2 ways x 32-byte lines (2 KB with SETS = 32).
//
// Write-through, no write-allocate:
//   - a store always goes to memory. If the line is in the cache, the cache
//     updates the stored words too, so the cache never holds old data.
//   - a store miss does not bring the line in.
// Thus the cache never holds dirty data and never writes a line back. That
// keeps it simple, and it makes the cache safe for 2 cores with one rule:
// the dispatcher invalidates every L1 at kernel start (inv). After that, a
// core can only read old data if a block of the same kernel on the other
// core wrote it, and the programming model does not allow that.
//
// Replacement: an invalid way first, else the least recently used way
// (one LRU bit per set).
//
// The lookup is combinational (tags and data in flip-flop arrays). The LSU
// FSM controls all writes.
module l1_cache #(
    parameter SETS = 32
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          inv,         // clear all valid bits (kernel start)
    input  wire [26:0]   line,        // address bits [31:5]
    output wire          hit,
    output wire [255:0]  hit_data,
    input  wire          touch,       // a load hit: update LRU
    input  wire          wr_en,       // a store: update the words of a hit line
    input  wire [7:0]    wr_mask,
    input  wire [255:0]  wr_data,
    input  wire          fill_en,     // a miss: put the line in the victim way
    input  wire [255:0]  fill_data
);
    localparam SB = $clog2(SETS);
    localparam TB = 27 - SB;

    wire [SB-1:0] set = line[SB-1:0];
    wire [TB-1:0] tag = line[26:SB];

    reg [SETS-1:0] v0, v1, lru;       // lru[s] = the way to replace next
    reg [TB-1:0]   tag0  [0:SETS-1];
    reg [TB-1:0]   tag1  [0:SETS-1];
    reg [255:0]    data0 [0:SETS-1];
    reg [255:0]    data1 [0:SETS-1];

    wire h0 = v0[set] && (tag0[set] == tag);
    wire h1 = v1[set] && (tag1[set] == tag);
    assign hit      = h0 | h1;
    assign hit_data = h0 ? data0[set] : data1[set];

    wire victim = !v0[set] ? 1'b0 : !v1[set] ? 1'b1 : lru[set];

    // The hit line with the stored words merged in
    reg [255:0] merged;
    integer i;
    always @(*) begin
        merged = hit_data;
        for (i = 0; i < 8; i = i + 1)
            if (wr_mask[i]) merged[i*32 +: 32] = wr_data[i*32 +: 32];
    end

    always @(posedge clk) begin
        if (rst || inv) begin
            v0  <= 0;
            v1  <= 0;
            lru <= 0;
        end else if (fill_en) begin
            if (victim == 1'b0) begin
                v0[set] <= 1'b1; tag0[set] <= tag; data0[set] <= fill_data;
            end else begin
                v1[set] <= 1'b1; tag1[set] <= tag; data1[set] <= fill_data;
            end
            lru[set] <= ~victim;
        end else if (hit && (touch || wr_en)) begin
            if (wr_en) begin
                if (h0) data0[set] <= merged;
                else    data1[set] <= merged;
            end
            lru[set] <= h0;               // way 0 used -> way 1 goes next
        end
    end
endmodule

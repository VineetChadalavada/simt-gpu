`timescale 1ns/1ps

// Testbench for the GPU (gpu_top: NC shader cores, dispatcher, arbiter).
//
// It reads the files that tools/build_tests.py made (in the current
// directory): prog.hex, mem.hex, expect.hex, launch.hex. For each kernel
// launch it writes the launch registers like a driver, starts the kernel
// and waits for the irq. At the end it compares all of global memory with
// the golden model and checks the counts that the model predicts.
//
// launch.hex (see tools/build_tests.py):
//   [0] launches [1] memory latency [2] backpressure [3] expected error code
//   [4] warp instructions [5] memory transactions [6] bank-conflict cycles
//   [7] 1 = check the L1 counts [8] L1 hits [9] L1 misses
//   [16 + 8k ..] launch k: entry, blocks, threads, param0..param3
module tb_gpu;
    parameter NC = 2;                  // number of shader cores
    parameter SCHED = 0;               // 0 = LRR, 1 = GTO
    localparam NW = 4, NL = 8;
    localparam MEM_WORDS = 16384;
    localparam TIMEOUT = 2_000_000;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg [31:0] imem    [0:2047];
    reg [31:0] gmem    [0:MEM_WORDS-1];
    reg [31:0] exp_mem [0:MEM_WORDS-1];
    reg [31:0] cfg     [0:79];

    // ---------------- DUT ----------------
    reg          reg_we = 0;
    reg  [3:0]   reg_addr = 0;
    reg  [31:0]  reg_wdata = 0;
    wire [31:0]  reg_rdata;
    wire         irq;
    wire [NC-1:0]    imem_en;
    wire [NC*11-1:0] imem_addr;
    reg  [NC*32-1:0] imem_rdata;
    wire         req_valid, req_we;
    wire [31:0]  req_addr;
    wire [7:0]   req_wmask;
    wire [255:0] req_wdata;
    reg          req_ready;
    reg          resp_valid;
    reg  [255:0] resp_data;
    wire         fifo_error;
    wire [NC*14*32-1:0] perf;

    gpu_top #(.NC(NC), .NW(NW), .NL(NL), .SCHED(SCHED)) dut (
        .clk(clk), .rst(rst),
        .reg_we(reg_we), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .irq(irq),
        .imem_en(imem_en), .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .mem_req_valid(req_valid), .mem_req_ready(req_ready), .mem_req_we(req_we),
        .mem_req_addr(req_addr), .mem_req_wmask(req_wmask), .mem_req_wdata(req_wdata),
        .mem_resp_valid(resp_valid), .mem_resp_data(resp_data),
        .mem_fifo_error(fifo_error), .perf(perf)
    );

    // ---------------- instruction memory: one read port per core ----------------
    genvar gc;
    generate
        for (gc = 0; gc < NC; gc = gc + 1) begin : ip
            always @(posedge clk)
                if (imem_en[gc]) imem_rdata[gc*32 +: 32] <= imem[imem_addr[gc*11 +: 11]];
        end
    endgenerate

    // ---------------- global memory model ----------------
    // Requests move 32-byte lines. A write changes the words in its mask
    // when accepted. A read takes the line when accepted and returns it LAT
    // cycles later. Responses come back in order.
    int unsigned lat;
    bit          bp;
    int unsigned now = 0;
    int unsigned q_time[$];
    logic [255:0] q_data[$];
    logic [255:0] rline;
    integer      k;
    bit          mem_error = 0;

    always @(posedge clk) now <= now + 1;

    initial req_ready = 1;
    always @(posedge clk) req_ready <= !bp || ($urandom_range(0, 3) != 0);

    always @(posedge clk) begin
        if (req_valid && req_ready) begin
            if (req_addr[4:0] != 0 || req_addr >= MEM_WORDS * 4) begin
                $display("ERROR: memory access out of range: %h", req_addr);
                mem_error = 1;
            end else if (req_we) begin
                for (k = 0; k < 8; k = k + 1)
                    if (req_wmask[k]) gmem[(req_addr >> 2) + k] <= req_wdata[k*32 +: 32];
            end else begin
                for (k = 0; k < 8; k = k + 1)
                    rline[k*32 +: 32] = gmem[(req_addr >> 2) + k];
                q_time.push_back(now + lat);
                q_data.push_back(rline);
            end
        end
        if (fifo_error) begin
            $display("ERROR: read response with no read in flight");
            mem_error = 1;
        end
    end

    always @(posedge clk) begin
        resp_valid <= 0;
        if (q_time.size() > 0 && q_time[0] <= now) begin
            resp_valid <= 1;
            resp_data  <= q_data[0];
            void'(q_time.pop_front());
            void'(q_data.pop_front());
        end
    end

    // ---------------- driver ----------------
    task reg_write(input [3:0] a, input [31:0] d);
        begin
            @(posedge clk);
            reg_we <= 1; reg_addr <= a; reg_wdata <= d;
            @(posedge clk);
            reg_we <= 0;
        end
    endtask

    // Sum of counter n over all cores
    function [31:0] psum(input integer n);
        integer c;
        begin
            psum = 0;
            for (c = 0; c < NC; c = c + 1) psum = psum + perf[(c*14 + n)*32 +: 32];
        end
    endfunction

    // ---------------- test sequence ----------------
    integer ln, i, j, errors, base;
    reg [31:0] status;
    integer kcycles;
    reg [31:0] p_cyc, p_wi, p_ti, p_dep, p_mem, p_bar, p_empty, p_div;
    reg [31:0] p_txn, p_hit, p_miss, p_bank, p_fp, p_wb;
    initial begin
        $readmemh("prog.hex",   imem);
        $readmemh("mem.hex",    gmem);
        $readmemh("expect.hex", exp_mem);
        $readmemh("launch.hex", cfg);
        lat = (cfg[1] < 1) ? 1 : cfg[1] - 1;   // the response register adds 1
        bp  = cfg[2][0];

        repeat (3) @(posedge clk);
        rst <= 0;

        kcycles = 0;
        status  = 0;
        for (ln = 0; ln < cfg[0]; ln = ln + 1) begin
            base = 16 + 8 * ln;
            reg_write(4'd2, cfg[base + 0]);               // entry
            reg_write(4'd3, cfg[base + 1]);               // grid
            reg_write(4'd4, cfg[base + 2]);               // block
            for (j = 0; j < 4; j = j + 1)
                reg_write(4'd5 + j, cfg[base + 3 + j]);   // params
            reg_write(4'd0, 32'd1);                       // start
            @(posedge clk);
            while (!irq && !mem_error && now < TIMEOUT) @(posedge clk);
            reg_addr <= 4'd1;
            #1 status = reg_rdata;
            reg_addr <= 4'd9;
            #1 kcycles = kcycles + reg_rdata;
            if (status[2] || mem_error || now >= TIMEOUT) break;
        end

        p_cyc = psum(0);  p_wi = psum(1);  p_ti = psum(2);  p_dep = psum(3);
        p_mem = psum(4);  p_bar = psum(5); p_empty = psum(6); p_div = psum(7);
        p_txn = psum(8);  p_hit = psum(9); p_miss = psum(10); p_bank = psum(11);
        p_fp  = psum(12); p_wb  = psum(13);

        errors = 0;
        if (now >= TIMEOUT) begin
            $display("ERROR: timeout");
            errors = errors + 1;
        end else if (cfg[3] != 0) begin
            // Negative test: only the error code matters.
            if (!status[2] || status[7:4] != cfg[3]) begin
                $display("ERROR: expected error code %0d, got error=%0d code %0d",
                         cfg[3], status[2], status[7:4]);
                errors = errors + 1;
            end
        end else if (status[2]) begin
            $display("ERROR: core %0d stopped with error code %0d", status[11:8], status[7:4]);
            errors = errors + 1;
        end else if (!mem_error) begin
            for (i = 0; i < MEM_WORDS; i = i + 1) begin
                if (gmem[i] !== exp_mem[i]) begin
                    if (errors < 10)
                        $display("MISMATCH addr %h: got %h, expected %h", i * 4, gmem[i], exp_mem[i]);
                    errors = errors + 1;
                end
            end
            if (p_wi !== cfg[4]) begin
                $display("MISMATCH warp instructions: got %0d, expected %0d", p_wi, cfg[4]);
                errors = errors + 1;
            end
            if (p_txn !== cfg[5]) begin
                $display("MISMATCH memory transactions: got %0d, expected %0d", p_txn, cfg[5]);
                errors = errors + 1;
            end
            if (p_bank !== cfg[6]) begin
                $display("MISMATCH bank conflicts: got %0d, expected %0d", p_bank, cfg[6]);
                errors = errors + 1;
            end
            if (cfg[7] != 0 && (p_hit !== cfg[8] || p_miss !== cfg[9])) begin
                $display("MISMATCH L1: got %0d hits %0d misses, expected %0d hits %0d misses",
                         p_hit, p_miss, cfg[8], cfg[9]);
                errors = errors + 1;
            end
        end

        // cycles = kernel cycles (all launches, wall clock); ipc = warp
        // instructions per cycle for the whole GPU; simd_eff = active lanes
        // per issued instruction / NL; stalls are summed over the cores.
        $display("cycles=%0d warp_instrs=%0d ipc=%0.3f simd_eff=%0.3f diverge=%0d stall_dep=%0d stall_mem=%0d stall_wb=%0d stall_bar=%0d stall_empty=%0d txn=%0d l1_hit=%0d l1_miss=%0d bank_conflict=%0d fp=%0d",
                 kcycles, p_wi, (kcycles == 0) ? 0.0 : real'(p_wi) / real'(kcycles),
                 (p_wi == 0) ? 0.0 : real'(p_ti) / real'(p_wi * NL), p_div,
                 p_dep, p_mem, p_wb, p_bar, p_empty, p_txn, p_hit, p_miss, p_bank, p_fp);
        if (!mem_error && errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end
endmodule

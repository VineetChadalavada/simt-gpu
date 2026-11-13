# Plan

Written in ASD-STE100 Simplified Technical English.

## 1. Goal

Design a small GPU with 2 shader cores in Verilog. The design shows the
skills of a GPU RTL design engineer:

- GPU schedulers (warp scheduler, block dispatcher)
- execution units (SIMD integer lanes, a pipelined FP32 unit)
- caches (L1 data cache, shared memory, a shared L2 path)
- SIMT architecture (warps, divergence, reconvergence, latency hiding)

Each stage must work and be easy to explain by itself.

## 2. Target design

```
                 +-----------------------------------------+
  launch regs -> |            block dispatcher             |
                 +-------------------+---------------------+
                                     |
            +------------------------+------------------------+
            |                                                 |
   +--------v---------+                              +--------v---------+
   |  shader core 0   |                              |  shader core 1   |
   | fetch + I-buffer |                              |       ...        |
   | warp scheduler   |                              |                  |
   | scoreboard       |                              |                  |
   | 8 SIMD lanes     |                              |                  |
   | FP32 unit        |                              |                  |
   | LSU + coalescer  |                              |                  |
   | L1 D$ + shared   |                              |                  |
   +--------+---------+                              +--------+---------+
            |                                                 |
            +--------------------+----------------------------+
                                 |
                       +---------v----------+
                       |  arbiter / L2 path |
                       +---------+----------+
                                 |
                          global memory
```

Each core: 4 warps x 8 lanes = 32 threads, 16 registers per thread.

## 3. Stages

| Stage | Content | Status |
|---|---|---|
| 1 | ISA, assembler, golden model. One shader core: fetch, instruction buffers, round-robin warp scheduler, scoreboard, 8 integer lanes, serial LSU, barrier, perf counters. | Done |
| 2 | Branch divergence: a reconvergence (IPDOM) stack for each warp. if/else, nested branches, divergent loops, divergent exit. Random tests with branches. | Done |
| 3 | Memory: a coalescer (8 lane addresses -> line requests), an L1 data cache, shared memory with banks and a bank-conflict counter. | Done |
| 4 | Two cores: block dispatcher, memory arbiter, kernel launch registers. L1 rule for many cores (write-through, invalidate at kernel start), compared with the MESI design in TinyTrust. | Done |
| 5 | FP32 execution unit: pipelined add, multiply, fused multiply-add. Variable latency in the scoreboard, write-back port arbitration. A second scheduler policy (greedy-then-oldest) and a comparison with round-robin. | Done (integration mutation run open) |
| 6 | Hardware: Vivado synthesis on the ZedBoard (area, fmax), and an IHP SG13G2 synthesis for gate counts. | Partly done (SG13G2 block areas; Vivado open) |

## 4. Verification method

- A Python golden model (`tools/golden.py`) runs each kernel at warp level.
- The testbench compares all 64 KB of memory with the model after the run.
- The testbench also compares the number of warp instructions. A wrong
  branch or a lost warp changes this number even when memory looks correct.
- Random programs stress the scoreboard and the scheduler.
- Mutation checks: put a known bug in a copy of the RTL and make sure that
  a test fails. This finds tests that cannot fail.

# simt-gpu

A small GPU in Verilog: 2 SIMT shader cores with warp schedulers, branch
divergence, a coalescing load/store unit, L1 data caches, banked shared
memory, a pipelined FP32 fused multiply-add unit, a block dispatcher, and a
memory arbiter. A Python golden model checks every test bit by bit and
also predicts the exact performance counts.

Written in ASD-STE100 Simplified Technical English.

## Results

| Area | Result |
|---|---|
| Tests | 98 of 98 pass (Icarus Verilog) with 2 cores and with 1 core, with the round-robin and with the GTO scheduler |
| Multi-core | Compute kernels 1.9-2.0x faster on 2 cores than on 1; memory-bound random programs 1.6-1.75x (one shared memory port) |
| Coalescer + L1 | `matmul`: 1088 memory requests -> 136 line transactions, 104 of 128 load transactions hit in L1; 2.4x faster than the per-lane LSU |
| Shared memory | Transpose with bank conflicts: 112 extra cycles; with a padded row: 0, 20% faster |
| FP32 FMA | Bit-exact against an independent reference on 229,642 directed and random vectors |
| Write-back arbitration | ALU and FPU share one write port; the reservation costs 194 cycles in all 98 tests (~0.1%) |
| Scheduler | GTO: 6% faster on memory-bound code (better L1 reuse), 14-21% slower on loop kernels (round-robin fetch cannot feed one warp) |
| Mutation testing | Stage 3: 14 of 14 bugs found. Stage 4: 7 of 7. FMA: 13 of 13 wrong designs found, and the 2 equivalent mutants match the proven alignment limits |
| Gate count (IHP SG13G2 130 nm) | FMA lane 0.076 mm^2 (6,462 cells); ALU lane 0.040 mm^2; LSU with L1 and shared memory 2.16 mm^2 (storage in flip-flops) |

Open work: the Vivado run on the ZedBoard part (utilization and fmax), the
full-core SG13G2 run, the stage 5 integration mutation run, and an xsim run
of stages 4 and 5 (xsim passed for stages 1 to 3). See
[docs/stage6.md](docs/stage6.md).

## Architecture

```
   launch registers (entry PC, grid, block, 4 params, status, irq)
          |
   block dispatcher -- gives each block to the first free core,
          |            invalidates every L1 at kernel start
     +----+-----------------------------+
     v                                  v
  shader core 0                     shader core 1
  +--------------------------------+
  | fetch (round-robin) -> 1-entry |
  |   instruction buffer per warp  |
  | 4 warps x reconvergence stack  |
  | issue: LRR or GTO scheduler,   |
  |   scoreboard, write-port       |
  |   reservation                  |
  | 8 lanes: register file slice,  |
  |   integer ALU, FP32 FMA (4 st.)|
  | LSU: coalescer, L1 2 KB 2-way, |
  |   shared memory 1 KB, 8 banks  |
  +---------------+----------------+
                  |                     |
                  +--> memory arbiter <-+   round-robin, in-order response FIFO
                            |
                      global memory (32-byte lines)
```

Each core: 4 warps x 8 lanes = 32 threads, 16 registers per thread.

| Stage | Content | Report |
|---|---|---|
| 1 | ISA, assembler, golden model; one core: fetch, instruction buffers, warp scheduler, scoreboard, integer lanes, barrier, perf counters | [stage1.md](docs/stage1.md) |
| 2 | Branch divergence: an IPDOM reconvergence stack per warp | [stage2.md](docs/stage2.md) |
| 3 | Coalescer, L1 data cache, shared memory with bank-conflict handling | [stage3.md](docs/stage3.md) |
| 4 | Two cores, block dispatcher, memory arbiter, launch registers, the L1 rule for many cores | [stage4.md](docs/stage4.md) |
| 5 | FP32 FMA unit, variable latency, write-back port arbitration, GTO scheduler | [stage5.md](docs/stage5.md) |
| 6 | Synthesis: IHP SG13G2 gate counts (Vivado open) | [stage6.md](docs/stage6.md) |

Each report has the design decisions, the measured numbers, the
verification results, the limits, and interview questions with answers.
[docs/ISA.md](docs/ISA.md) is the instruction set; [docs/PLAN.md](docs/PLAN.md)
is the plan.

## Verification

- **Golden model** (`tools/golden.py`): runs each kernel at warp level with
  the same reconvergence rules as the RTL. The testbench compares all 64 KB
  of memory and these exact counts: warp instructions, memory transactions,
  bank-conflict cycles, and (where the access order is fixed) L1 hits and
  misses. A wrong coalescer or a lost warp changes a count even when the
  data is correct.
- **Race check**: the model stops if two blocks of one kernel share a word
  that one of them writes. Blocks run in parallel on the cores, so such a
  test would pass or fail by chance.
- **Random programs**: straight-line integer code (`rand_*`), nested
  divergent control flow with loops and early exit (`rbr_*`), and FP code
  mixed with integer and memory code (`rfp_*`); with random memory latency
  and back-pressure.
- **FP32**: `tools/fp32.py` computes a * b + c exactly with integers and
  rounds once. The RTL uses a different method (76-bit window with a
  sticky-bit replacement), so the two do not share a mistake.
- **Mutation testing**: put one known bug into a copy of the RTL and check
  that a test fails. This found tests that could not fail, and each gap
  got a new test (for example a vector class for the carry-ripple case of
  the FMA alignment, and L1 hit/miss checks for replacement bugs that only
  cost time).

## Quick start

Requirements: Python 3 and Icarus Verilog (or Vivado 2021.1 for xsim).

```powershell
.\scripts\run_tests.ps1                  # build all tests, run them on 2 cores (Icarus)
.\scripts\run_tests.ps1 -Cores 1         # the same on a 1-core GPU
.\scripts\run_tests.ps1 -Sched gto       # greedy-then-oldest warp scheduler
.\scripts\run_tests.ps1 -Sim xsim        # Vivado xsim
.\scripts\run_tests.ps1 -Only fp_        # a subset
```

## A kernel

```asm
# y[i] = a * x[i] + y[i] in FP32 (tests/fp_saxpy.s)
.blocks 4
.threads 32
.param 0 0x1000                  # x
.param 1 0x1400                  # y
.param 2 f(-1.75)                # a
        s2r  r1, tid
        s2r  r2, ctaid
        shli r2, r2, 5
        add  r1, r1, r2
        shli r1, r1, 2           # i * 4
        s2r  r2, param0
        add  r2, r2, r1
        ld   r3, 0(r2)           # x[i]
        s2r  r4, param1
        add  r4, r4, r1
        ld   r5, 0(r4)           # y[i]
        s2r  r6, param2
        ffma r5, r6, r3, r5      # a * x[i] + y[i], one rounding
        st   r5, 0(r4)
        exit
```

## Layout

| Folder | Content |
|---|---|
| `rtl/core/` | Shader core: `sm_core`, `simt_stack`, `scoreboard`, `rr_arb`, `gto_arb`, `decode`, `alu`, `fma32`, `regfile_lane`, `lsu`, `l1_cache`, `smem` |
| `rtl/gpu/` | `gpu_top`, `block_dispatcher`, `mem_arbiter` |
| `dv/` | `tb_gpu.sv` (full GPU), `tb_fma.sv` (FMA unit) |
| `tests/` | Test kernels (assembly + set-up directives) |
| `tools/` | Assembler, golden model, FP32 reference, test and vector generators |
| `scripts/` | Test runner |
| `synth/` | Yosys (IHP SG13G2) and Vivado scripts, reports |
| `docs/` | Plan, ISA, stage reports |

## Limits

No L2 cache, no atomics, no instruction cache (one instruction-memory port
per core), one outstanding L1 miss per core, storage in flip-flops (no SRAM
macros), FP32 without compare, conversion, division or square root.

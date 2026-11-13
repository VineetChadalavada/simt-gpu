# Stage 1: One shader core

Written in ASD-STE100 Simplified Technical English.

## 1. Result

- One shader core runs integer kernels: 4 warps x 8 SIMD lanes.
- The core has a round-robin warp scheduler, a scoreboard, a barrier, and
  performance counters.
- All 30 tests pass on Icarus Verilog and on Vivado xsim: 10 kernels that we
  wrote by hand and 20 random programs.
- For each test, all 64 KB of memory and the warp-instruction count agree
  with the golden model.
- With 4 warps per block, matmul is 1.50 times faster than with 1 warp per
  block (2146 cycles, not 3216). The work is the same.

## 2. Commands

| Task | Command |
|---|---|
| Build the tests and run them (Icarus) | `.\scripts\run_tests.ps1` |
| Run on Vivado xsim | `.\scripts\run_tests.ps1 -Sim xsim` |
| Run some tests only | `.\scripts\run_tests.ps1 -Only matmul` |
| More random tests | `.\scripts\run_tests.ps1 -Random 200` |
| Assemble one file | `python tools\asm.py tests\vec_add.s` |

## 3. What we built

### 3.1 Tools (`tools/`)

| File | Function |
|---|---|
| `isa.py` | Opcodes, encodings, and the ALU. The single source for the Python tools. |
| `asm.py` | Two-pass assembler. It also reads the test set-up directives (`.blocks`, `.param`, `.random`, ...). |
| `golden.py` | The golden model. It runs a kernel at warp level, with the full reconvergence stack (stage 2 needs it). |
| `build_tests.py` | Makes the memory images and the expected results for each test. Makes the random programs. |

### 3.2 RTL (`rtl/core/`)

| File | Lines | Function |
|---|---|---|
| `sm_core.v` | 415 | The shader core. Connects all blocks. Holds the warp state. |
| `decode.v` | 62 | Instruction decoder. |
| `rr_arb.v` | 38 | Round-robin arbiter: the warp scheduler and the fetch arbiter. |
| `scoreboard.v` | 34 | One pending bit for each (warp, register). |
| `regfile_lane.v` | 38 | The register file of one lane: 4 warps x 16 registers. |
| `alu.v` | 33 | The integer ALU of one lane. |
| `lsu.v` | 109 | Load/store unit: one request for each active lane. |

### 3.3 Verification (`dv/`, `tests/`)

`tb_core.sv` holds the instruction memory and a global memory model. The
memory model has a latency setting and a backpressure setting (the memory
refuses a request at random, 1 time in 4).

## 4. The pipeline

```
 IF          IB              IS                     EX
 fetch  ->  instruction ->  warp scheduler  ->  8 x ALU  -> register file
 arbiter    buffer, one     + scoreboard        address      (port 0)
            per warp        + operand read      branch
                                                   |
                                                   +-> LSU -> register file
                                                             (port 1)
```

1. **IF.** The fetch arbiter picks a warp that has an empty instruction
   buffer. It sends the warp's PC to the instruction memory.
2. **IB.** The instruction arrives in the buffer of that warp. If it is a
   control instruction (`jmp`, `brz`, `brnz`, `bar`, `exit`), the warp
   stops its fetch until EX resolves the instruction.
3. **IS.** The warp scheduler looks at all 4 buffers. A warp is ready when
   its instruction has no pending register, the warp does not wait at a
   barrier, and the LSU is free (for a memory instruction). The scheduler
   picks one ready warp, round-robin. The core reads the two operands for
   all 8 lanes.
4. **EX.** 8 ALUs compute. The result goes into the register file at the
   end of the cycle. Loads and stores go to the LSU.

## 5. Decisions

### 5.1 Stop fetch after a control instruction, no branch prediction

A CPU predicts branches because it has only one thread. A GPU has other
warps that can use the cycle. The core stops the fetch for one warp only,
so it never fetches a wrong path. This removes the flush logic completely.
The cost for one warp is 2 cycles per branch. Other warps hide that cost.

### 5.2 A scoreboard, no forwarding

The core has no forwarding paths. A dependent instruction from the same
warp waits in IS until the result is in the register file. Forwarding for
8 lanes would need 8 copies of every bypass multiplexer. A GPU uses the
other warps to fill the gap, not wires. The `stall_dep` counter shows the
cycles where this failed: no other warp was ready.

The scoreboard checks the destination register too (WAW). A load and a
later ALU instruction can write the same register. The ALU result arrives
first, and the slow load must not overwrite it. The `no_waw` mutant
(section 7) proves that the random tests find this case.

### 5.3 Two write ports in the register file

EX writes ALU results. The LSU writes load data, at any time. Two write
ports remove the arbitration between them. The scoreboard makes sure the
two ports never write the same register. On an FPGA with flip-flop
register files, a second write port is cheap. A real GPU uses banked SRAM
and an operand collector instead. Stage 5 comes back to this.

### 5.4 A 1-entry instruction buffer

With one entry, one warp can issue at most one instruction each 2 cycles.
This is acceptable because 4 warps share the issue slot. A second entry is
a small change if the numbers later show that fetch limits the IPC.

### 5.5 The golden model counts warp instructions

The testbench compares the count with the RTL. A wrong branch can give a
correct memory image by chance. It cannot give the correct count.

## 6. Numbers

| Test | Warps/block | Cycles | Warp instr. | IPC | Stall: dep | Stall: mem | Stall: empty |
|---|---|---|---|---|---|---|---|
| matmul | 4 | 2146 | 672 | 0.31 | 798 | 652 | 24 |
| matmul_1warp | 1 | 3216 | 672 | 0.21 | 832 | 832 | 880 |
| vec_add | 4 | 808 | 272 | 0.34 | 192 | 296 | 48 |
| vec_add_slow (20-cycle memory) | 4 | 1439 | 272 | 0.19 | 491 | 618 | 58 |
| loop_sum | 4 | 1436 | 744 | 0.52 | 628 | 40 | 24 |

What the numbers show:

- **Warps hide latency.** With 1 warp, 880 cycles have no instruction to
  issue (`stall_empty`), because the warp waits for fetch and for branch
  resolution. With 4 warps, this falls to 24.
- **The LSU is the bottleneck.** In matmul, 652 of 2146 cycles wait for the
  LSU. The LSU sends one request for each lane, so one warp load takes 8 or
  more memory cycles. Stage 3 adds a coalescer: 8 neighbor addresses become
  one line request.
- **Slow memory hurts more.** vec_add_slow uses 20-cycle memory. The cycles
  go from 808 to 1439. 4 warps do not have enough independent work to hide
  20 cycles. This is why real GPUs keep 32 to 64 warps on each core.

## 7. Verification

The first full run passed. A first-run pass can mean that the tests cannot
fail. To check this, we put one bug at a time into a copy of the RTL and
ran all tests:

| Mutant | Bug | Tests that fail |
|---|---|---|
| `no_scoreboard` | The scoreboard never sets a pending bit. | 11 of 15 |
| `no_waw` | No check of the destination register. | 2 |
| `no_ctrl_wait` | Fetch continues after a branch. | 4 |
| `alu_sra` | `sra` shifts in zeros. | 2 |
| `partial_mask` | All lanes active in a partial warp. | 1 |
| `bar_ignored` | `bar` does nothing. | 1 (after the fix below) |
| `bar_early` | The barrier releases too early. | 1 (after the fix below) |
| `lsu_lane_mask` | Load data goes to inactive lanes too. | 0 (see below) |

Two results needed action:

- **`bar_ignored` passed all tests at first.** The barrier test was too
  gentle: round-robin issue kept the warps in step, so all stores came
  before all loads without the barrier. We added a delay loop that makes
  warp 0 the slowest writer, and warp 3 reads the words of warp 0. Now the
  test fails without the barrier.
- **`lsu_lane_mask` passes all tests.** In stage 1, inactive lanes exist
  only in a partial warp, and no instruction can read them. The bug cannot
  change a result yet. Stage 2 makes lanes inactive inside a full warp
  (divergence), and its tests must catch this mutant.

## 8. Limits of stage 1

- A divergent branch stops the core with error code 2. Stage 2 fixes this.
- The LSU handles one warp instruction at a time, one lane per request.
- One core only. The testbench launches the blocks one after another.
- No synthesis numbers yet (stage 6).

## 9. Interview questions

**Q: What is the difference between SIMD and SIMT?**
A: SIMD exposes the vector width to the program: one instruction works on a
vector register. SIMT shows a scalar program for each thread. The hardware
groups threads into warps and runs them on SIMD lanes. Each thread has its
own PC in the model, so threads can take different branches. The hardware
handles that with active masks and a reconvergence stack.

**Q: Why does a GPU not use forwarding or branch prediction?**
A: It has many warps. When one warp waits, the scheduler issues another.
Area that a CPU spends on forwarding and prediction, a GPU spends on more
lanes and more warps. In this core, the 1-warp matmul has 880 empty issue
cycles, and the 4-warp matmul has 24.

**Q: Why does the scoreboard check the destination register?**
A: Two units write the register file with different latencies. A load can
finish after a later ALU instruction to the same register. Without the WAW
check, the old load value overwrites the new ALU value.

**Q: How does the warp scheduler pick a warp?**
A: Loose round-robin. The search starts at the warp after the last winner.
It is fair and simple. Stage 5 adds greedy-then-oldest (GTO), which keeps
one warp until it stalls. GTO often gives better cache locality.

**Q: How does the barrier work?**
A: `bar` sets a wait bit for the warp. The core releases all wait bits when
every warp that has not exited has its bit set. The barrier must be in code
where the warp does not diverge.

**Q: How do you know that your tests can find bugs?**
A: Mutation checks. I put known bugs into the RTL and made sure each one
fails a test. This found a weak barrier test, and I fixed it.

**Q: What limits the IPC now?**
A: The LSU. It sends one memory request for each lane. The perf counters
show 652 of 2146 matmul cycles stalled on the LSU. The fix is a coalescer
and an L1 cache (stage 3).

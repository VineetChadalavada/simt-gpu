# Stage 4: Two cores, block dispatcher, memory arbiter

Written in ASD-STE100 Simplified Technical English.

## 1. Result

- The design is now a GPU: `gpu_top` has **2 shader cores**, a **block
  dispatcher**, a **memory arbiter**, and **kernel launch registers**.
- A kernel launch has an entry PC, a grid size, a block size and 4
  parameters. One program can hold more than one kernel.
- The dispatcher gives each block to the first free core. A core with short
  blocks takes more blocks, so the load balances by itself.
- The two cores share one global-memory port. The arbiter is round-robin
  and sends each read response back to the core that asked for it.
- **The L1 rule for 2 cores**: write-through, and the dispatcher
  invalidates every L1 at kernel start. There is no coherence protocol.
- The golden model now finds **data races between blocks**. Blocks run in
  parallel, so a test where one block reads data that a different block of
  the same launch writes is a test bug. The check found one such test
  (`l1_reuse`), and that test now uses two launches.
- 73 of 73 tests pass with 2 cores and with 1 core (Icarus Verilog).
  Compute kernels run 1.9x to 2.0x faster on 2 cores.

## 2. Commands

```powershell
.\scripts\run_tests.ps1               # 2 cores (the default)
.\scripts\run_tests.ps1 -Cores 1      # the same tests on a 1-core GPU
.\scripts\run_tests.ps1 -Sim xsim     # Vivado xsim
```

The `cycles` value in the result line is now the kernel time of the whole
GPU (all launches). The other counts are the sums over the cores.

## 3. What changed

| File | Change |
|---|---|
| `rtl/gpu/gpu_top.v` | New. Launch registers, 2 cores, dispatcher, arbiter, irq. |
| `rtl/gpu/block_dispatcher.v` | New. IDLE -> INV -> RUN FSM, block counter, error capture. |
| `rtl/gpu/mem_arbiter.v` | New. Round-robin request arbiter, FIFO that routes the read responses. |
| `rtl/core/sm_core.v` | Inputs `launch_pc` (entry PC) and `l1_inv`. |
| `rtl/core/simt_stack.v` | The base entry starts at `init_pc`, not at 0. |
| `rtl/core/l1_cache.v`, `lsu.v` | `inv` input: clear all valid bits. |
| `dv/tb_gpu.sv` | New testbench (replaces `tb_core.sv`). It writes the launch registers like a driver. |
| `tools/asm.py` | `.launch ENTRY BLOCKS THREADS [P0..P3]` directive, up to 8 launches. |
| `tools/golden.py` | Runs a list of launches. Finds races between blocks. |
| `tests/` | `l1_inv`, `blocks_uneven`. `l1_reuse` uses two launches. |

## 4. How it works

### 4.1 Block diagram

```
   reg bus -->  launch registers  --start-->  block dispatcher
                (entry, grid, block,           |  launch_valid[c], ctaid
                 params, status)               |  l1_inv (kernel start)
                                     +---------+----------+
                                     v                    v
                              shader core 0         shader core 1
                              (4 warps x 8 lanes,   (same)
                               L1 2 KB, smem 1 KB)
                                     |                    |
                                     +------> mem_arbiter <+
                                              |  round-robin requests
                                              |  FIFO: who gets the next read response
                                              v
                                        global memory (32-byte lines)
```

### 4.2 Launch registers

| Word | Name | Access | Content |
|---|---|---|---|
| 0 | CTRL | W | 1 = start the kernel (ignored while busy) |
| 1 | STATUS | R | [0] busy, [1] done, [2] error, [7:4] error code, [11:8] core |
| 2 | ENTRY | RW | entry PC |
| 3 | GRID | RW | blocks in the grid |
| 4 | BLOCK | RW | threads per block (1..32) |
| 5-8 | PARAM0-3 | RW | kernel arguments (`s2r rX, paramN`) |
| 9 | CYCLES | R | cycles of the last kernel |

The registers do not change while a kernel runs. `irq` is a 1-cycle pulse
when a kernel ends.

### 4.3 The dispatcher

```
IDLE --start--> INV (1 cycle: every L1 clears its valid bits) --> RUN --all blocks done--> IDLE
                                                                   |
                                                                   +--core error--> ERR (until reset)
```

In RUN, each cycle: if blocks are left and a core is free, the lowest free
core gets the next `ctaid`. The dispatcher counts `block_done` pulses. When
the count equals the grid size, the kernel is done. A core is free again
in the same cycle as its `block_done` pulse, so the next block starts at
once.

### 4.4 The memory arbiter

- Requests: a round-robin arbiter (the same `rr_arb` as the warp
  scheduler) picks one core. The core sees `ready` only when memory
  accepts its request.
- Responses: memory returns reads in order. When the arbiter sends a read,
  it puts the core number into a FIFO. Each response goes to the core at
  the head of the FIFO.
- Each core has a maximum of one read in flight (the L1 miss is blocking),
  so a FIFO of NC entries is enough. An output flag shows a response with
  an empty FIFO; the testbench stops on it.

## 5. Decisions

**Why write-through + invalidate, and not a coherence protocol?**
TinyTrust (my other project) has MESI caches with a snoop bus. A GPU does
not need that, for these reasons:

1. The programming model has no sharing between blocks inside a kernel
   (except atomics, which this design does not have). The only time a core
   can see another core's data is in a later kernel.
2. Write-through means that memory always has the newest data. The only
   problem is old data in an L1. Invalidate at kernel start removes it.
3. The cost is small: one cycle per kernel, and the first read of each line
   in each kernel misses. MESI costs a snoop on each miss, state bits, and
   a much larger verification job.

Real GPUs do the same: the L1 is not coherent, and the L2 (shared) is the
point of coherence. The cost of write-through is memory traffic: each store
goes to memory. A GPU has an L2 to absorb that traffic; this design does
not (see section 8).

**Why does the golden model check races between blocks?**
The model runs the blocks one after another. The GPU runs them in parallel,
in an order that depends on timing. A test where block 1 reads what block 0
wrote passes in the model, and it passes or fails on the GPU by chance.
That is a test bug, so the model stops on it. It found `l1_reuse`, which
did exactly that (it was correct for 1 core, which runs blocks in order).

**Why the lowest free core, and not round-robin?**
It is the simplest rule, and it is deterministic. The load balance comes
from the `block_done` timing, not from the pick order. For 2 cores the
difference is small.

**Why does each core have its own instruction port?**
Each core fetches one instruction per cycle. A shared instruction port would
halve the fetch rate. A real GPU has an instruction cache per core; here the
program memory is outside `gpu_top`, with one read port per core.

## 6. Numbers

Cycles of the kernel (all launches), Icarus, memory latency 4 unless the
test sets it.

| Test | 1 core | 2 cores | Speedup |
|---|---|---|---|
| vec_add (4 blocks) | 510 | 257 | 1.98 |
| matmul (2 blocks) | 897 | 464 | 1.93 |
| matmul_smem | 1170 | 607 | 1.93 |
| transpose | 572 | 288 | 1.99 |
| smem_reduce | 1258 | 631 | 1.99 |
| collatz | 6618 | 3540 | 1.87 |
| blocks_uneven (24 blocks) | 6146 | 3150 | 1.95 |
| saxpy (3 blocks) | 284 | 190 | 1.49 |
| l1_inv (3 launches) | 560 | 319 | 1.76 |
| rand_* (mean of 20) | | | 1.73 |

- Compute kernels with an even number of equal blocks come close to 2.0.
- `saxpy` has 3 blocks: one core runs 2 blocks and the other runs 1. The
  best possible speedup is 1.5.
- The random tests are memory-bound (about 1 transaction for each warp
  instruction). The two cores share one memory port, so they wait for each
  other. This is why a real GPU has a wide L2 with many banks.
- `l1_inv`: on 1 core, the second block of each launch hits in L1 (16
  hits). On 2 cores, each block is on its own core and all 40 reads miss.

## 7. Verification

- The same 73 tests pass on 1 core and on 2 cores. A test result must not
  depend on the number of cores.
- The race check in the golden model makes sure that each test is a valid
  parallel program.
- `l1_inv` is the test for the L1 rule: without the invalidate, each core
  reads old data for one half of the array.
- `blocks_uneven`: 24 blocks with 4 different lengths. It checks that the
  dispatcher gives each block once, also when cores finish out of order.

Mutation check (one known bug per RTL copy, all 73 tests, 2 cores):

| Mutant | Bug | Tests that fail |
|---|---|---|
| none | (no change) | 0 |
| no_l1_inv | the L1s are never invalidated | 1 (`l1_inv`) |
| entry_zero | the entry PC is ignored (always 0) | 1 (`l1_inv`) |
| dup_block | ctaid does not advance when core 1 takes a block | 64 |
| lost_block | a block goes to a core that is not free | 9 |
| done_on_dispatch | kernel done when the last block starts, not ends | 73 |
| resp_wrong_core | read response goes to the core that has the grant now | 57 |
| ready_to_all | both cores see ready, one request is lost | 43 |

`no_l1_inv` and `entry_zero` fail only one test. That is expected: only
`l1_inv` has more than one kernel and more than one entry PC. These two
features need a dedicated test; random tests do not reach them.

## 8. Limits

- No L2 cache. Every miss and every store goes to global memory through
  one port. The random tests show the cost: 1.73x on 2 cores, not 2x.
- No atomics. Blocks cannot share data inside a kernel.
- A core error stops the kernel; only a reset clears it.
- One kernel at a time. The dispatcher does not overlap the end of one
  kernel with the start of the next.

## 9. Interview questions

**Q: Why is the GPU L1 not coherent?**
A: Blocks in one kernel do not share writable data (without atomics), so
coherence inside a kernel is not needed. Between kernels, an invalidate at
kernel start is enough because the L1 is write-through: memory always has
the newest data. That is much cheaper than snooping on every miss.

**Q: What breaks if the L1 were write-back?**
A: A dirty line in core 0's L1 would not be in memory. The next kernel on
core 1 would read old data. Then you need a flush of all dirty lines at
kernel end (time proportional to the cache size), or a coherence protocol.

**Q: How do you send read responses to the right core?**
A: The memory returns reads in order, so a FIFO of requester IDs is
enough: push at the request, pop at the response. If memory could return
out of order, each request would need a tag, and the response would carry
the tag back.

**Q: How large must that FIFO be?**
A: The number of reads that can be in flight. Each core has one (blocking
miss), so NC entries. With a non-blocking cache (MSHRs), it is NC x the
number of MSHRs.

**Q: How do you know that a test is a valid parallel program?**
A: The golden model records which block wrote each word and which blocks
read it, per launch. If two blocks share a word and one of them writes it,
the result depends on timing, and the model stops.

**Q: Why is the speedup on the random tests only 1.73x?**
A: They are memory-bound and the two cores share one memory port. The
`stall_mem` counter goes up. The fix in a real GPU is an L2 with many banks
and a crossbar, so different cores can use memory in parallel.

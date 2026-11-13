# Stage 2: Branch divergence

Written in ASD-STE100 Simplified Technical English.

## 1. Result

- The lanes of one warp can now take different paths. Each warp has a
  reconvergence stack (IPDOM stack) with 8 entries in `simt_stack.v`.
- The core supports nested if/else, if without else, loops with a
  different trip count in each lane, `switch` chains, and `exit` in
  divergent code.
- Two negative tests prove that the core stops with the correct error
  code: stack overflow (code 2) and `bar` in divergent code (code 4).
- All 61 tests pass on Icarus Verilog and on Vivado xsim: 21 hand-written
  kernels, 20 random straight-line programs, and 20 random programs with
  branches (`rbr_*`).
- 13 deliberate bugs (mutants), and each one fails at least one test.
- The mutant that stage 1 could not catch (load data into inactive lanes)
  now fails 18 tests.

## 2. Commands

No change from stage 1. `.\scripts\run_tests.ps1` builds and runs all tests.
`-Random N` sets the number of random tests of each kind.

## 3. What changed

| File | Change |
|---|---|
| `rtl/core/simt_stack.v` | New, 125 lines. The reconvergence stack of one warp. It owns the warp's fetch PC and active mask. |
| `rtl/core/sm_core.v` | One `simt_stack` per warp. Each instruction-buffer entry keeps its mask. New errors and a `perf_diverge` counter. |
| `rtl/core/decode.v` | New output `rpc`. |
| `tools/golden.py` | The same two stack rules as the RTL, the stack limit, and error codes. |
| `tools/build_tests.py` | Random structured programs with branches (`BranchGen`). The `.expect_err` directive for negative tests. |
| `dv/tb_core.sv` | Checks the error code of negative tests. Prints SIMD efficiency. |

## 4. How the stack works

Each entry has three fields: `pc` (where the path continues), `rpc` (where
the path ends), and `mask` (the lanes on the path). The top entry is the
path that runs now. It lives in registers. The other entries live in a small
memory below it.

```
  before            brz r7, ELSE, JOIN          after ELSE path reaches JOIN
                    (lanes 0,2,4,6 jump)
  +-------------+   +--------------------+      +--------------------+
  | pc   = 10   |   | pc=ELSE rpc=JOIN   | top  | pc=11   rpc=JOIN   | top
  | mask = ff   |   |   mask=55 (taken)  |      |   mask=aa          |
  +-------------+   +--------------------+      +--------------------+
     top            | pc=11   rpc=JOIN   |      | pc=JOIN            |
                    |   mask=aa (not tkn)|      |   mask=ff          |
                    +--------------------+      +--------------------+
                    | pc=JOIN            |
                    |   mask=ff          |
                    +--------------------+
```

1. **Divergent branch (EX).** The old top entry stays, with its pc set to
   the rpc. The not-taken path and the taken path go on top. The taken
   path runs first.
2. **Pop (fetch).** When the fetch PC of the top entry equals its rpc, the
   core pops the entry and does not fetch. The next entry continues.
3. **exit (EX).** The exiting lanes leave the `alive` mask. The stack memory
   does not change. A popped entry is ANDed with `alive`, so exited lanes
   never come back. An entry with no lanes pops at once.

## 5. Decisions

### 5.1 The compiler gives the rpc

Each branch holds its reconvergence PC in the instruction (`rpc` field).
The hardware does not need to find the immediate post-dominator. That
analysis belongs in the compiler, where it is cheap. Real GPUs do the same:
NVIDIA has used `SSY`/`SYNC` and later `BSSY`/`BSYNC` instructions.

### 5.2 Two rules keep the stack small

A plain IPDOM stack pushes 2 entries for each divergent branch. In a loop
where lanes leave one at a time, the stack grows on each iteration. Two
rules stop this:

1. No entry for a path that starts at the rpc. The path has no
   instructions, so it would pop at once. Example: `if` without `else`.
2. If the top entry already ends at the same rpc, the new paths replace
   it. Nothing goes under it. Example: a loop exit, or a `switch` chain.

| Test | Peak depth with the rules | Without rule 2 | Without rule 1 |
|---|---|---|---|
| switch | 8 | 14 | 8 |
| loop_in_if | 5 | 9 | 10 |
| collatz | 3 | 8 | 3 |
| div_loop | 1 | 7 | 8 |

The golden model uses the same rules. Thus the RTL and the model agree on
the depth and on the point of overflow.

### 5.3 Each instruction carries its own mask

The fetch unit can pop the stack while older instructions of the same warp
are still in the buffer, in EX, or in the LSU. Each instruction-buffer
entry keeps the mask from fetch time. A pop cannot change the lanes of an
instruction that is already in flight. The `mask_at_issue` mutant reads the
mask at issue time, and 11 random tests fail.

### 5.4 No pop while a fetch is in flight

The fetch that is in flight can be a branch. If the stack popped in that
cycle, the branch would later split the wrong top entry. The core pops only
when the warp has no fetch in flight and no unresolved control instruction.
The `pop_during_fetch` mutant removes this check, and 15 tests fail.

### 5.5 exit does not clear the stack memory

Clearing the exited lanes in all 8 entries in one cycle needs 8 mask
writes. The `alive` mask does the same job with one AND at pop time. Only
the top entry can hold exited lanes, and a top entry with no lanes pops.

## 6. Numbers

`simd_eff` is the mean fraction of the 8 lanes that do useful work in each
issued instruction.

| Test | Cycles | Warp instr. | IPC | simd_eff | Divergent branches |
|---|---|---|---|---|---|
| if_else | 284 | 152 | 0.54 | 0.87 | 8 |
| nested | 286 | 218 | 0.76 | 0.56 | 26 |
| div_loop | 1653 | 936 | 0.57 | 0.69 | 84 |
| switch | 420 | 328 | 0.78 | 0.55 | 56 |
| loop_in_if | 680 | 584 | 0.86 | 0.53 | 104 |
| collatz | 6628 | 4577 | 0.69 | 0.38 | 241 |

What the numbers show:

- **IPC alone hides the cost of divergence.** collatz has a high IPC
  (0.69), but only 38% of the lanes do work. The useful work is
  0.69 x 0.38 x 8 = 2.1 lane-operations per cycle, from a peak of 8.
- **Divergence costs issue slots, not correctness.** Each path of a branch
  runs in turn, so a warp issues both paths. In `switch`, 8 lanes take 8
  different cases, and the warp runs all 8 cases one after the other.
- **Pops cost fetch cycles.** In collatz, 2051 of 6628 cycles have no
  instruction ready (`stall_empty`). A pop takes one fetch cycle, and a
  control instruction stops the fetch for its warp until EX.

## 7. Verification

### 7.1 Tests

| Kind | Tests | What they cover |
|---|---|---|
| Hand-written, stage 2 | if_else, if_only, nested, div_loop, collatz, div_exit, div_bar, switch, loop_in_if | Each stack case on purpose |
| Negative | err_stack, err_bar | Error code 2 and error code 4 |
| Random with branches | rbr_00..19 | Nested if/else (some with no else), loops with 1-4 trips per lane, early exit, loads and stores in each path, partial warps, memory latency and backpressure |

The random generator knows the structure of each program, so it writes the
correct rpc for each branch. It keeps the nesting at 4 or less, so a
correct core never overflows.

### 7.2 Mutation checks

| Mutant | Bug | Tests that fail |
|---|---|---|
| `lsu_lane_mask` | Load data goes to inactive lanes too | 18 |
| `mask_at_issue` | Uses the mask at issue time, not at fetch time | 11 |
| `pop_no_alive` | A popped entry brings exited lanes back | 12 |
| `pop_during_fetch` | Pop while a fetch is in flight | 15 |
| `nt_mask` | Not-taken path gets all lanes | 25 |
| `no_replace` | Rule 2 off | 2 (switch, loop_in_if) |
| `always_push_nt` | Rule 1 off for the not-taken path | 1 (loop_in_if) |
| `no_bar_check` | No error for `bar` in divergent code | 1 (err_bar) |
| `no_scoreboard` | No pending bits | 37 |
| `no_waw` | No destination check | 14 |
| `no_ctrl_wait` | Fetch continues after a control instruction | 34 |
| `bar_ignored` | `bar` does nothing | 2 |

Two results needed new tests:

- **`no_replace` passed all tests at first.** In collatz, the stack without
  rule 2 peaks at exactly 8, which is the limit. With 8 lanes, each
  divergent loop exit removes one lane, so the growth stops near 8. The
  new `switch` and `loop_in_if` tests need 9 to 14 entries without the
  rule.
- **The first random generator made 5 of 20 programs with no divergence.**
  It now always puts one if/else and one loop at the top level.

Mutants that hang make each test wait for the timeout. The mutation script
uses a testbench copy with a 200,000-cycle timeout. The longest real test
needs about 7,600 cycles.

### 7.3 Not done

A soak run with 200 random programs of each kind started, but the system
stopped it because the PC was low on memory. It gave no result. Run it
again with `.\scripts\run_tests.ps1 -Random 200` on a free machine.

## 8. Limits of stage 2

- `bar` must be in convergent code. Volta-class GPUs allow more (independent
  thread scheduling), but they need a different design.
- A pop takes one fetch cycle. A design that pops and fetches in the same
  cycle would save it.
- The LSU still sends one request for each lane (stage 3).

## 9. Interview questions

**Q: What happens when the threads of a warp take different branch paths?**
A: The warp runs each path in turn, with only that path's lanes active.
A reconvergence stack holds the waiting paths. When a path reaches the
reconvergence point, the stack pops and the next path runs. When all paths
reach it, the full mask comes back.

**Q: Where does the reconvergence point come from?**
A: From the compiler. It is the immediate post-dominator of the branch. In
this ISA the branch instruction holds it in the `rpc` field.

**Q: Why can the stack overflow, and how do you prevent it?**
A: Each nested divergent branch adds entries. Two rules keep the depth
low: no entry for an empty path, and replace the top entry when it already
ends at the same rpc. With these rules, a divergent loop uses 1 entry, not
1 for each iteration. If a program still needs too many, the core stops
with an error, not with wrong results.

**Q: Why is `bar` inside divergent code an error?**
A: The lanes on the other path cannot reach the barrier until the first
path finishes, and the first path waits at the barrier for them. That is a
deadlock. The core finds it and stops with error code 4.

**Q: Your IPC went up in collatz. Is the code fast?**
A: No. IPC counts warp instructions. SIMD efficiency is 0.38, so most
lanes are idle. Useful work is IPC x efficiency x lanes = 2.1 of 8. You
must look at both numbers.

**Q: How do you test a stack design like this?**
A: A golden model with the same rules, structured random programs that
know the correct rpc for each branch, negative tests for each error, and
mutation checks. The mutation checks found that my first tests could not
detect a missing stack rule.

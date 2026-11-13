# Stage 5: FP32 unit, write-back arbitration, GTO scheduler

Written in ASD-STE100 Simplified Technical English.

## 1. Result

- Four FP32 instructions: `fadd`, `fsub`, `fmul`, `ffma` (rd = rs1 * rs2 +
  rs3, one rounding). Each lane has one **fused multiply-add unit**
  (`fma32.v`), and all four instructions use it:
  `fadd` = a * 1.0 + b, `fsub` = a * 1.0 + (-b), `fmul` = a * b + (-0.0).
- The FMA unit has **4 pipeline stages** and accepts a new instruction
  every cycle. Rules: round to nearest even, denormals flushed to zero,
  one canonical NaN (the usual GPU subset of IEEE 754).
- **Variable latency**: ALU 1 cycle, FPU 4 cycles, LSU 2 or more. The
  scoreboard handles all three. The register file has a third read port
  for `ffma`.
- **Write-back port arbitration**: the ALU and the FPU share write port 0.
  The issue stage reserves the port, so the two never write in the same
  cycle. A new counter, `stall_wb`, counts the cycles that this costs.
- **A second warp scheduler**: greedy-then-oldest (GTO), next to the loose
  round-robin (LRR) scheduler. A parameter selects it.
- The FMA unit matches a bit-exact Python model on **229,642 vectors**.
  Mutation testing of the FMA found the exact safe limits of its alignment
  window (section 7.2).
- 98 of 98 tests pass with LRR and with GTO, on 2 cores and on 1 core
  (Icarus Verilog).

## 2. Commands

```powershell
.\scripts\run_tests.ps1                  # all tests, LRR scheduler
.\scripts\run_tests.ps1 -Sched gto       # the same tests with GTO
python tools\fp32.py                     # self-test of the FP model against the host FPU
python tools\fp_vectors.py 240000        # FMA vectors -> build/fpu/vectors.hex
# FMA unit test (in build/fpu):
#   iverilog -g2012 -o fma.vvp ..\..\rtl\core\fma32.v ..\..\dv\tb_fma.sv ; vvp -n fma.vvp
```

## 3. What changed

| File | Change |
|---|---|
| `rtl/core/fma32.v` | New. 4-stage FP32 fused multiply-add. |
| `rtl/core/gto_arb.v` | New. Greedy-then-oldest arbiter, same ports as `rr_arb`. |
| `rtl/core/sm_core.v` | FPU lanes, FPU pipeline control, port-0 reservation, `SCHED` parameter, counters `perf_fp_instrs` and `perf_stall_wb`. |
| `rtl/core/decode.v` | `is_fp`, `fp_op`, third source `rc` (bits [13:10]), `use_rc`. |
| `rtl/core/regfile_lane.v` | Third read port. |
| `tools/fp32.py` | New. Bit-exact FP32 reference (exact integer arithmetic, one rounding). |
| `tools/fp_vectors.py` | New. FMA vector generator with 8 vector classes. |
| `dv/tb_fma.sv` | New. FMA unit test, one vector per cycle. |
| `tools/asm.py`, `golden.py` | FP instructions, `f(x)` in expressions, `.floats` and `.randf` directives. |
| `tools/build_tests.py` | `rfp_*` random FP programs; FP ops inside the `rbr_*` branch programs. |
| `tests/` | `fp_saxpy`, `fp_matmul`, `fp_dot`, `fp_special`, `fp_wb`. |

## 4. How it works

### 4.1 One datapath for four instructions

A fused multiply-add computes a * b + c exactly and rounds once. Add and
multiply are special cases:

| Instruction | a | b | c |
|---|---|---|---|
| `fadd` | rs1 | 1.0 | rs2 |
| `fsub` | rs1 | 1.0 | rs2 with the sign bit flipped |
| `fmul` | rs1 | rs2 | -0.0 |
| `ffma` | rs1 | rs2 | rs3 |

`fmul` uses -0.0, not +0.0: x + (-0) = x for every x, also for x = -0. With
+0.0, (-2) * 0 would give +0 and not -0.

### 4.2 The FMA pipeline

```
 EX   stage 1  unpack, special cases (NaN, inf, zero), 24x24 multiply -> P (48 bits)
      stage 2  align the addend C to P, add or subtract       (76-bit window)
      stage 3  leading-zero count, normalize
 WB   stage 4  round to nearest even, overflow / flush to zero, pack
```

Stages 1 to 3 end in registers. Stage 4 is combinational from the stage-3
registers, and its result writes the register file at the end of that
cycle. So an FP instruction in EX in cycle t writes in cycle t+3.

**The alignment window.** s = (exponent of the lsb of C) - (exponent of
the lsb of P). The exact sum can need hundreds of bits when s is large. The
datapath uses a fixed 76-bit window with one rule:

- s >= 0 (C is above P): shift C left by s. If s > 50, P cannot change
  anything but the sticky bit. Then C shifts by 50 only, and P is replaced
  by the value 1.
- s < 0 (P is above C): shift P left by -s. If -s > 26, C is replaced by 1
  in the same way.

The replacement gives the same top 24 bits, the same round bit and the
same sticky bit, also for a subtraction (the borrow makes the same
pattern of ones). Section 7.2 shows the exact limits.

### 4.3 Write-back port 0

The ALU writes port 0 in its EX cycle. The FPU writes port 0 three cycles
after its EX cycle. The control keeps three valid bits, `fp_v1..fp_v3`, for
the FP instructions in flight. When `fp_v2` is set now, an FP result writes
port 0 in the next cycle, and the next cycle is the EX cycle of an
instruction that issues now. Thus an ALU instruction (a register write in
EX) is not ready when `fp_v2` is set. Other instructions (memory, branch,
FP) can still issue in that cycle.

```
cycle        t      t+1     t+2     t+3
ffma         EX     F2      F3      F4/WB(port 0)
add (ALU)                   IS      EX/WB(port 0)   <- conflict: held for 1 cycle
```

The scoreboard has no change: it sets a bit at issue and clears it at the
write. Variable latency is free for a scoreboard design.

### 4.4 GTO scheduler

`gto_arb.v` keeps the last winner. If that warp is ready again, it wins
again (greedy). If not, the lowest ready warp number wins (oldest: all
warps of a block start together). The fetch arbiter stays round-robin.

## 5. Decisions

**Why one FMA for all FP instructions?** One datapath to design and
verify. A separate adder and multiplier would be smaller for `fadd` and
`fmul` only, but a GPU needs `ffma` for matrix work, and then the FMA is
there anyway. Real GPU FP32 pipes work the same way.

**Why flush denormals to zero?** Denormals need a second normalize path
(or a long, variable latency). GPUs give FTZ as the fast mode for FP32.
The Python model has the same rule, so the tests are bit-exact.

**Why reserve the port and not add a third write port?** A write port on a
flip-flop register file costs a 2:1 mux on every bit of every register and
a wider decode. The reservation costs only the cycles in which the
conflict occurs. The measurement: 194 `stall_wb` cycles in all 98 tests
(about 0.1% of the cycles). Even in `fp_wb`, which is made to hit the
conflict, it is 36 of 370 cycles.

**Why a 76-bit window and not a full 3 x 24-bit + exponent-range shifter?**
The sticky-bit replacement keeps the adder at 76 bits and the shifts at a
maximum of 50 bits. That is the standard trick in FMA designs.

## 6. Numbers

### 6.1 FP kernels (2 cores, LRR)

| Test | Cycles | Warp instructions | FP instructions |
|---|---|---|---|
| fp_saxpy (128 elements) | 243 | 240 | 16 |
| fp_matmul (8 x 8) | 444 | 600 | 64 |
| fp_dot (256 elements, tree in shared memory) | 611 | 644 | 44 |
| fp_wb (port-conflict test) | 370 | 296 | 48 |

`fp_matmul` (444 cycles) is a little faster than the integer `matmul` (464
cycles): one `ffma` replaces `mul` + `add`.

### 6.2 GTO compared with LRR (2 cores, cycles)

| Test | LRR | GTO | GTO / LRR |
|---|---|---|---|
| matmul | 464 | 541 | 1.17 |
| loop_sum | 392 | 474 | 1.21 |
| fp_matmul | 444 | 508 | 1.14 |
| transpose | 288 | 282 | 0.98 |
| rand_* (mean of 20, memory-bound) | | | 0.94 (0.88 .. 1.00) |
| rfp_* (mean of 20) | | | 0.98 (0.89 .. 1.10) |
| rbr_* (mean of 20, divergent) | | | 1.03 (0.93 .. 1.17) |
| all 98 tests (sum of cycles) | 156,463 | 152,260 | 0.97 |

Two effects, both visible in the counters:

1. **Memory-bound code: GTO is better (6% on `rand_*`).** GTO keeps one warp
   on its data, so a line in L1 is used again before other warps evict it.
   Example: `rand_04` has 386 L1 hits and 198 misses with GTO, and 329 hits
   and 255 misses with LRR. That is the known reason for GTO.
2. **Loops with short dependency chains: GTO is worse (14-21%).** The
   counter `stall_empty` goes up (in `loop_sum` from 10 to 166 cycles). The
   reason: each warp has a 1-entry instruction buffer, and fetch stays
   round-robin. GTO wants the same warp again, but its next instruction is
   not fetched yet, while the other warps have instructions ready. The
   issue policy and the fetch policy do not agree.

The lesson: a scheduler policy is not only an issue-stage choice. With a
small instruction buffer, the fetch arbiter must follow the same priority
(or the buffer must be deeper). This is the next step for a better GTO.

### 6.3 1 core compared with 2 cores (LRR)

All 98 tests: 262,588 cycles on 1 core, 156,463 on 2 cores (1.68x). Compute
kernels: 1.9-2.0x (see stage 4). Random programs: 1.73x (`rand_*`), 1.75x
(`rbr_*`), 1.59x (`rfp_*`); these share one memory port.

## 7. Verification

### 7.1 Method

- **FP reference.** `tools/fp32.py` computes the exact value of a * b + c
  with Python integers and rounds once. This is a different method from
  the RTL (fixed window, sticky replacement), so the two do not share a
  mistake. A self-test compares 350,038 `fadd`/`fmul` results with the host
  FPU (where no denormal or overflow occurs).
- **FMA unit test.** 229,642 vectors in 8 classes: random bits, special
  values, cancellation (c = -round(a * b), only the rounding error of the
  product remains: an unfused design fails here), addends near the
  alignment limits, carry-ripple patterns, products near overflow and
  underflow, `fadd` and `fmul`.
- **Kernels.** `fp_special` has 32 rows of special cases through all 4
  instructions. `fp_dot` and `fp_matmul` fix the order of the adds, so the
  results are bit-exact.
- **Random programs.** 20 `rfp_*` programs mix FP, integer and memory
  instructions in 4 warps (three latencies, port-0 conflicts, NaN and
  denormal bit patterns from integer ops). The `rbr_*` programs now have FP
  instructions inside divergent code, so an FP write to an inactive lane
  changes the result.
- Every test passes with both schedulers. The scheduler changes the timing
  but must not change any result or count.

### 7.2 FMA mutation check and the alignment limits

| Mutant | Bug | Failing vectors |
|---|---|---|
| none | (no change) | 0 |
| truncate | no rounding (round toward zero) | 77,483 |
| no_sticky | sticky bit ignored | 38,272 |
| ties_away | ties go away from zero | 765 |
| unfused | product rounded to 24 bits before the add | 99,596 |
| lzc_off | leading-zero count off by one | 195,373 |
| no_ftz | small results not flushed | 1,444 |
| inf_minus_inf | inf - inf does not give NaN | 84 |
| cancel_neg_zero | exact cancellation gives -0 | 21 |
| nan_sign | NaN with the sign bit set | 8,642 |
| align_s_40 | addend limit 40, not 50 | 4,123 |
| align_s_48 | addend limit 48 | 21 |
| align_s_49 | addend limit 49 | 0 (correct design) |
| align_t_20 | product limit 20, not 26 | 1,615 |
| align_t_22 | product limit 22 | 540 |
| align_t_23 | product limit 23 | 0 (correct design) |

The first run had `align_t_20` at 0 failing vectors. It is a real bug: if C
overlaps the low bits of P, a carry can run up to the round bit, but only
when those bits of P are all ones. Random vectors almost never make that.
A new vector class makes it on purpose: for a random odd ma, it takes
mb = -1/ma mod 2^23, so the low 23 bits of P = ma * mb are all ones. After
that, the mutation results agree with the theory:

- The replacement of P is exact when the round bit is above P: s >= 50.
  The smallest correct limit is "s > 49". The RTL uses "s > 50".
- The replacement of C is exact when C is fully below P: -s >= 24. The
  smallest correct limit is "-s > 23". The RTL uses "-s > 26".

The two "0" rows are not test gaps: they are correct designs, and the
mutation check proves that the vectors find the first wrong limit on
each side.

### 7.3 Integration mutation check: not complete

The mutation run for the core integration (10 mutants: no port
reservation, no hazard check on rs3, FP write to all lanes, scoreboard
clear for the wrong warp, `fsub` without the sign flip, `fmul` with +0,
rs3 not latched, block done with FP in flight, FP during an error) was
stopped because the computer ran low on memory. Only the "no change" run
finished (0 of 98 fail). The script is ready; this is open work.

## 8. Limits

- No FP compare, min/max, conversion (int <-> float), division or square
  root. Kernels load FP constants with `li rd, f(x)`.
- One rounding mode, no exception flags.
- The FPU computes every cycle; there is no clock gating of idle lanes.
- GTO with a round-robin fetch loses on loop kernels (section 6.2).

## 9. Interview questions

**Q: Why is fmul = a * b + (-0) and not a * b + 0?**
A: Because -0 is the identity of addition in IEEE 754: x + (-0) = x for
all x. With +0, a product of -0 would turn into +0.

**Q: What is the difference between an FMA and a multiply then an add?**
A: One rounding instead of two. Test case: c = -round(a * b). The FMA gives
the exact rounding error of the product; a multiply-then-add gives 0. The
`unfused` mutant fails 99,596 vectors.

**Q: How wide must the FMA adder be?**
A: Without a trick, the full exponent range. With the sticky replacement:
the product (48 bits) plus the addend shifted over it, plus guard bits.
The exact limits come from the place of the round bit: the addend side is
exact for s >= 50, the product side for -s >= 24. This design uses 76 bits.

**Q: How do you handle results with different latencies?**
A: The scoreboard sets a pending bit at issue and clears it at the write,
so the latency does not matter for hazards. The write port is the problem:
two results can arrive in the same cycle. Here the issue stage reserves the
shared port. Other options: more write ports, or a result buffer.

**Q: When is GTO better than round-robin?**
A: When warps reuse their own data (cache locality): GTO keeps one warp on
its lines. Round-robin is better when all warps need the same latency
hiding and the front end cannot feed one warp alone, as here with a
1-entry instruction buffer and a round-robin fetch.

**Q: Why flush denormals?**
A: A denormal input needs a pre-normalize step, a denormal output a
right shift before the rounding. Both cost area or latency. GPUs give
FTZ as the default fast mode for FP32 graphics and ML work.

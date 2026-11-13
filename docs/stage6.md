# Stage 6: Hardware results (synthesis)

Written in ASD-STE100 Simplified Technical English.

Status: **partly done.** The IHP SG13G2 gate counts of the main blocks are
complete. The full-core SG13G2 run and the Vivado (ZedBoard) run are not
done yet. Their scripts are ready; section 4 lists them.

## 1. Commands

```powershell
.\synth\run_sg13g2.ps1 -Tops fma32,alu,l1_cache,lsu        # Yosys -> IHP SG13G2 cells
vivado -mode batch -source synth/vivado_synth.tcl -tclargs gpu_top 10   # ZedBoard, 100 MHz target
```

The SG13G2 Liberty file is part of the IHP open PDK; it is not in this
repository (see the header of `synth/run_sg13g2.ps1`). The reports go to
`synth/reports/`.

## 2. IHP SG13G2 (130 nm), Yosys + ABC, typical corner 1.2 V 25 C

Area is the sum of the cell areas from the Liberty file. There is no
placement, so no wire area and no timing.

| Block | Cells | Area (um^2) | Flip-flops | Sequential share |
|---|---|---|---|---|
| `fma32` (one lane, 4 stages) | 6,462 | 76,404 | 282 | 18% |
| `alu` (one lane, with 32x32 multiply) | 3,992 | 39,948 | 0 | 0% |
| `l1_cache` (2 KB, 2-way) | 61,205 | 1,375,407 | 17,888 | 64% |
| `lsu` (coalescer + L1 + 1 KB shared memory) | 119,203 | 2,163,296 | 27,125 | 61% |

What the numbers say:

- **The storage is in flip-flops, and it is most of the area.** The L1 has
  2 KB of data (16,384 bits) plus tags in flip-flops: 64% of its area is
  sequential, and the rest is mostly the read muxes. A real chip uses SRAM
  macros for the L1 data, the shared memory and the register file. An SRAM
  bit cell is about 10x smaller than a flip-flop plus its share of the read
  mux. This is the first change for a real implementation.
- **One FP32 FMA lane is about 2x the integer ALU lane** (76,404 against
  39,948 um^2). The ALU is large because of its 32x32 multiplier; the FMA
  has a 24x24 multiplier, the 76-bit adder, the leading-zero counter and
  the shifters. 8 FMA lanes per core: about 0.61 mm^2.
- The FMA pipeline registers are only 18% of its area. The 3 register
  stages are cheap; the deep logic is the multiplier and the alignment.

## 3. Estimate for the full GPU (not a synthesis result)

From the block numbers, per core: LSU 2.16 mm^2, 8 FMA lanes 0.61 mm^2,
8 ALU lanes 0.32 mm^2, plus the register file (8 lanes x 64 registers x
32 bits = 16,384 bits in flip-flops, similar to the L1 data: about 1 mm^2)
and the control. That gives roughly 4-5 mm^2 per core in flip-flop
storage, 8-10 mm^2 for 2 cores. This is an estimate from the parts, not a
measured number; the full-core run (section 4) gives the real number.

## 4. Open work

| Run | Status | Note |
|---|---|---|
| SG13G2, `sm_core` (full core, flattened) | stopped | The computer ran low on memory. The flattened core with all storage in flip-flops is large for Yosys + ABC. Run it alone, or synthesize the storage as black boxes. |
| Vivado, `gpu_top` on xc7z020 (ZedBoard) | not run | `synth/vivado_synth.tcl` does out-of-context synthesis, place and route, and reports utilization, WNS and fmax. Expected risk: the LUT count, because the register file (2 write ports) and the L1 data (combinational read) cannot use block RAM. |
| Vivado, `sm_core` and `fma32` alone | not run | Same script, for the per-block fmax. |

## 5. Lint

Verilator `--lint-only -Wall` on `gpu_top` gives no errors. The warnings
are:

- `PINCONNECTEMPTY` (52): decoder outputs that a stage does not use, left
  open on purpose.
- `WIDTHEXPAND` / `WIDTHTRUNC` (20): intended width changes in arithmetic
  (for example a 2-bit count added to a 4-bit pointer).
- `UNUSEDSIGNAL` (3): one unused decode output and unused bits of loop
  variables and of the rounding sum.

Yosys found one real defect during this stage: the LSU and the dispatcher
used one loop variable (`integer`) in more than one `always` block, so the
variable had more than one driver. Simulation was correct, but synthesis
reports a driver conflict. Each block now has its own loop variable.

# The SIMT ISA

Written in ASD-STE100 Simplified Technical English.

## 1. Model

- A kernel runs as a grid of thread blocks. A block has 1 to 32 threads.
  A launch sets the entry PC, the grid size, the block size and 4
  parameters (the launch registers, see docs/stage4.md). One program can
  hold more than one kernel.
- The blocks of a kernel run in parallel on the cores, in any order. A
  block must not read or write a global word that a different block of the
  same kernel writes (the golden model stops on such a race). A later
  kernel sees all the writes of an earlier kernel.
- The core runs a block as warps of 8 threads. Warp `w` holds threads
  `8w` to `8w+7`. One warp instruction does the same operation on all 8 lanes.
- Each thread has 16 registers of 32 bits. `r0` is always 0.
- Registers are not set at launch. A kernel must write a register before it
  reads it. The golden model stops with an error on a read before a write.
- Global memory is 64 KB, byte addresses, 32-bit words only. An address
  must be a multiple of 4.
- Shared memory is 1 KB for each block (256 words). Only the threads of
  the block can use it, with `lds` and `sts`. It is not set at block start.
  A kernel must write a shared word before it reads it.
- The PC counts instructions, not bytes. A program has a maximum of 2048
  instructions.

## 2. Encoding

All instructions are 32 bits.

```
         31    26 25   22 21   18 17   14 13                 0
R-type  |  op    |  rd   |  rs1  |  rs2  |  rs3  |     0      |   (rs3: ffma only)
I-type  |  op    |  rd   |  rs1  |        imm18 (signed)      |
         31    26 25   22 21          11 10                   0
Branch  |  op    |  rs   |   target     |    rpc              |
```

`op[5] = 0` means an ALU operation. Then `op[4]` selects the operand b:
0 = `rs2`, 1 = `imm18`. `op[3:0]` is the ALU function. One small decoder
handles all 31 ALU instructions.

## 3. Instructions

### 3.1 ALU (op 0x01-0x0F register, 0x11-0x1F immediate)

| op[3:0] | R-type | I-type | Result |
|---|---|---|---|
| 0x0 | (`nop` = 0x00) | `lui rd, imm` | rd = imm18 << 14 |
| 0x1 | `add` | `addi` | a + b |
| 0x2 | `sub` | `subi` | a - b |
| 0x3 | `mul` | `muli` | low 32 bits of a * b |
| 0x4 | `and` | `andi` | a & b |
| 0x5 | `or`  | `ori`  | a \| b |
| 0x6 | `xor` | `xori` | a ^ b |
| 0x7 | `shl` | `shli` | a << b[4:0] |
| 0x8 | `shr` | `shri` | a >> b[4:0], logical |
| 0x9 | `sra` | `srai` | a >> b[4:0], arithmetic |
| 0xA | `slt` | `slti` | 1 if a < b (signed) |
| 0xB | `sltu`| `sltui`| 1 if a < b (unsigned) |
| 0xC | `min` | `mini` | signed minimum |
| 0xD | `max` | `maxi` | signed maximum |
| 0xE | `seq` | `seqi` | 1 if a == b |
| 0xF | `sne` | `snei` | 1 if a != b |

### 3.2 Memory and special registers

| op | Syntax | Operation |
|---|---|---|
| 0x20 | `ld rd, imm(rs1)` | rd = mem[rs1 + imm] |
| 0x21 | `st rs2, imm(rs1)` | mem[rs1 + imm] = rs2 (rs2 is in the rd field) |
| 0x22 | `lds rd, imm(rs1)` | rd = shared[rs1 + imm] |
| 0x23 | `sts rs2, imm(rs1)` | shared[rs1 + imm] = rs2 |
| 0x24 | `s2r rd, sreg` | rd = special register |

In the memory opcodes, `op[0]` = store and `op[1]` = shared memory.
If two lanes of one store write the same word, the highest lane wins.

Special registers: `tid` (0), `ctaid` (1, block index), `ntid` (2, threads
per block), `nctaid` (3, blocks in the grid), `laneid` (4), `warpid` (5),
`coreid` (6), `param0`-`param3` (8-11, kernel arguments).

A kernel must not let its result depend on `coreid`, because the dispatcher
can put a block on any core.

### 3.3 FP32 (op 0x28-0x2B)

| op | Syntax | Operation |
|---|---|---|
| 0x28 | `fadd rd, rs1, rs2` | rd = rs1 + rs2 |
| 0x29 | `fsub rd, rs1, rs2` | rd = rs1 - rs2 |
| 0x2A | `fmul rd, rs1, rs2` | rd = rs1 * rs2 |
| 0x2B | `ffma rd, rs1, rs2, rs3` | rd = rs1 * rs2 + rs3, one rounding. rs3 is in bits [13:10]. |

`op[5:2] = 1010` means FP. The hardware has one fused multiply-add unit
per lane, and all four instructions use it: `fadd` = rs1 * 1.0 + rs2,
`fsub` = rs1 * 1.0 + (-rs2), `fmul` = rs1 * rs2 + (-0.0).

Rules (the usual GPU subset of IEEE 754):

- Round to nearest, ties to even. No other rounding modes, no flags.
- Denormals are zero: a denormal input is read as a zero of the same sign.
  A result below 2^-126 after rounding becomes a zero of its sign.
- A NaN result is always the quiet NaN `0x7FC00000`. inf * 0 and
  inf + (-inf) give NaN.
- An exact zero sum of nonzero values is +0.

`tools/fp32.py` is the bit-exact reference. In the assembler, `f(x)` gives
the FP32 bits of x: `li r4, f(0.5)`.

### 3.4 Control

| op | Syntax | Operation |
|---|---|---|
| 0x30 | `jmp target` | Jump for all active lanes. |
| 0x31 | `brz rs, target, rpc` | Lanes with rs == 0 go to target. |
| 0x32 | `brnz rs, target, rpc` | Lanes with rs != 0 go to target. |
| 0x33 | `bar` | Wait until all live warps of the block arrive. |
| 0x3F | `exit` | The active lanes stop. |

`rpc` is the reconvergence PC: the first instruction that both paths of the
branch run again. The compiler (here: the programmer) knows it, so the
hardware does not need to find it. For a loop branch, the assembler sets the
rpc to the next instruction when you leave it out.

If the lanes of a warp do not agree on a branch, the warp diverges. The
warp runs each path in turn, and the paths join again at the rpc. Each warp
has a reconvergence stack of 8 entries (see docs/stage2.md).

`bar` must be in code where the warp does not diverge.

### 3.5 Error codes

| Code | Cause |
|---|---|
| 1 | Illegal instruction |
| 2 | Reconvergence stack overflow |
| 3 | Misaligned address |
| 4 | `bar` in divergent code |
| 5 | Shared-memory address of 1024 or more |

## 4. Pseudo-instructions

| Syntax | Expansion |
|---|---|
| `li rd, value` | `addi rd, r0, value` if the value fits in 18 bits, else `lui` + `ori` |
| `mov rd, rs` | `add rd, rs, r0` |

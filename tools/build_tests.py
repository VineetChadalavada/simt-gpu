"""Build every test into build/tests/<name>/.

For each test the script writes:
    prog.hex    the program, one instruction per line
    mem.hex     global memory before the kernel runs
    expect.hex  global memory after the kernel runs (from the golden model)
    launch.hex  the test set-up and the expected counts (see LAUNCH_HEX_WORDS)

Sources: tests/*.s, plus random programs made here: rand_* (straight-line
integer code), rbr_* (nested if/else, divergent loops, early exit) and
rfp_* (FP32 mixed with integer and memory code).

    python tools/build_tests.py [--random N]
"""
import argparse
import random
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from asm import assemble, AsmError          # noqa: E402
from golden import run, MEM_WORDS, ModelError  # noqa: E402
from isa import ALU_NAMES                   # noqa: E402
from fp32 import f2bits                     # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def build_mem(cfg, seed):
    mem = [0] * MEM_WORDS
    rng = random.Random(seed)
    for kind, a in cfg["mem"]:
        base = a[0] >> 2
        if kind == "words":
            vals = a[1:]
        elif kind == "floats":
            vals = [f2bits(x) for x in a[1:]]
        elif kind == "randf":
            vals = [f2bits(rng.uniform(a[2], a[3])) for _ in range(int(a[1]))]
        elif kind == "seq":
            vals = [a[2] + i * a[3] for i in range(a[1])]
        else:
            vals = [rng.getrandbits(32) for _ in range(a[1])]
        for i, v in enumerate(vals):
            mem[base + i] = v & 0xFFFFFFFF
    return mem


# launch.hex layout. dv/tb_gpu.sv reads the same words.
#   [0] number of launches   [1] memory latency   [2] backpressure (1 = on)
#   [3] expected error code (0 = the kernel must finish)
#   [4] expected warp instructions   [5] expected memory transactions
#   [6] expected bank-conflict cycles
#   [7] 1 = check the L1 counts   [8] expected L1 hits   [9] expected L1 misses
#   [16 + 8k ..] launch k: entry PC, blocks, threads, param0..param3, 0
LAUNCH_HEX_WORDS = 16 + 8 * 8


def write_hex(path, words):
    path.write_text("".join(f"{w:08x}\n" for w in words))


def build_one(name, text, out_root):
    words, cfg = assemble(text)
    seed = zlib.crc32(name.encode())
    mem = build_mem(cfg, seed)
    final = list(mem)
    stats = {}
    try:
        count = run(words, final, cfg["launches"], stats=stats)
        if cfg["expect_err"]:
            raise ModelError(f"expected error {cfg['expect_err']}, but the kernel finished")
    except ModelError as e:
        if not cfg["expect_err"] or e.code != cfg["expect_err"]:
            raise
        count = 0                       # the testbench checks only the error code
        stats = {"txn": 0, "bank_conflict": 0}
    d = out_root / name
    d.mkdir(parents=True, exist_ok=True)
    write_hex(d / "prog.hex", words)
    write_hex(d / "mem.hex", mem)
    write_hex(d / "expect.hex", final)
    lh = [len(cfg["launches"]), cfg["memlat"], int(cfg["backpressure"]), cfg["expect_err"],
          count, stats["txn"], stats["bank_conflict"],
          int(cfg["expect_l1"] is not None), *(cfg["expect_l1"] or [0, 0])]
    lh += [0] * (16 - len(lh))
    for la in cfg["launches"]:
        lh += [la["entry"], la["blocks"], la["threads"], *la["params"], 0]
    lh += [0] * (LAUNCH_HEX_WORDS - len(lh))
    write_hex(d / "launch.hex", lh)
    return len(words), count, stats


def shared_own(rng):
    """Each thread owns 4 shared words, at r1 + offset. Two layouts:
    interleaved (word tid + 32k, no bank conflicts) or blocked (word
    4*tid + k, 4 lanes on each bank pair: 3 extra cycles)."""
    if rng.random() < 0.5:
        return "shli r1, r1, 2", [k * 128 for k in range(4)]
    return "shli r1, r1, 4", [k * 4 for k in range(4)]


def random_program(seed):
    """Straight-line ALU and memory code. 4 warps, so the scheduler and the
    scoreboard see many hazards: RAW on loads, WAW between a load and an ALU
    write, and long dependency chains.

    Memory: loads at the same offset in each lane (coalesced), gather loads
    (a random word in each lane), the thread's own output row and shared
    words, and a shared table (words 128..255). All threads write the table
    before a bar, and after the bar it is read-only, at random addresses.
    r15 points to a line that only this warp uses. Scatter stores put the
    lanes on random words of it, so lanes often store to the same word (the
    highest lane must win)."""
    rng = random.Random(seed)
    IN, OUT, SCAT = 0x1000, 0x4000, 0x8000
    lines = [".blocks 2", ".threads 32", f".param 0 {IN}", f".param 1 {OUT}",
             f".random {IN} 256", f".memlat {rng.choice([1, 2, 4, 9])}"]
    if rng.random() < 0.5:
        lines.append(".backpressure")
    lines += ["s2r r1, tid", "s2r r2, ctaid", "shli r3, r2, 5", "add r1, r1, r3",
              "shli r1, r1, 2",                       # r1 = global id * 4
              "s2r r2, param0", "add r2, r2, r1",     # r2 = &in[gid]
              "s2r r3, param1", "shli r4, r1, 4", "add r3, r3, r4"]  # r3 = &out[gid*16]
    shl, own = shared_own(rng)
    lines += ["s2r r1, tid", shl]                     # r1 = my shared words
    lines += ["s2r r15, ctaid", "shli r15, r15, 2", "s2r r4, warpid", "add r15, r15, r4",
              "shli r15, r15, 5", f"addi r15, r15, {SCAT}"]   # r15 = this warp's line
    for r in range(4, 15):
        lines.append(f"li r{r}, {rng.getrandbits(32)}")
    lines += [f"sts r{4 + k}, {own[k]}(r1)" for k in range(4)]
    lines += ["s2r r14, tid", "shli r14, r14, 2"]
    lines += [f"sts r{8 + j}, {512 + 128 * j}(r14)" for j in range(4)]
    lines += [f"li r14, {rng.getrandbits(32)}", "bar"]
    # r1..r3 and r15 hold addresses: random code writes only r4..r14.
    for _ in range(rng.randint(40, 120)):
        rd = rng.randint(4, 14)
        rs1, rs2 = rng.randint(4, 14), rng.randint(4, 14)
        if rs2 == rd:
            rs2 = 4 + (rd - 3) % 11
        x = rng.random()
        if x < 0.15:
            lines.append(f"ld r{rd}, {rng.randrange(0, 128) * 4 - 256}(r2)")
        elif x < 0.20:
            # A store into this thread's own output row, read back later.
            lines.append(f"st r{rs1}, {rng.randrange(16) * 4}(r3)")
        elif x < 0.25:
            lines.append(f"ld r{rd}, {rng.randrange(16) * 4}(r3)")
        elif x < 0.30:
            lines.append(f"s2r r{rd}, {rng.choice(['tid', 'laneid', 'warpid', 'ntid', 'ctaid'])}")
        elif x < 0.35:
            lines.append(f"andi r{rd}, r{rs1}, 1020")       # gather: a random word of in[]
            lines.append(f"ld r{rd}, {IN}(r{rd})")
        elif x < 0.40:
            lines.append(f"lds r{rd}, {rng.choice(own)}(r1)")
        elif x < 0.44:
            lines.append(f"sts r{rs1}, {rng.choice(own)}(r1)")
        elif x < 0.50:
            lines.append(f"andi r{rd}, r{rs1}, 508")        # a random word of the table
            lines.append(f"lds r{rd}, 512(r{rd})")
        elif x < 0.55:
            lines.append(f"andi r{rd}, r{rs1}, 28")         # scatter into the warp's line
            lines.append(f"add r{rd}, r{rd}, r15")
            lines.append(f"st r{rs2}, 0(r{rd})")
        elif x < 0.58:
            lines.append(f"andi r{rd}, r{rs1}, 28")
            lines.append(f"add r{rd}, r{rd}, r15")
            lines.append(f"ld r{rd}, 0(r{rd})")
        elif x < 0.78:
            lines.append(f"{rng.choice(ALU_NAMES[1:])} r{rd}, r{rs1}, r{rs2}")
        else:
            lines.append(f"{rng.choice(ALU_NAMES[1:])}i r{rd}, r{rs1}, "
                         f"{rng.randrange(-(1 << 17), 1 << 17)}")
    for r in range(4, 16):
        lines.append(f"st r{r}, {(r - 4) * 4}(r3)")
    lines.append("exit")
    return "\n".join(lines) + "\n"


FP_SPECIAL = [0x00000000, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0x00000001,
              0x00800000, 0x7F7FFFFF, 0x3F800001]


def fp_program(seed):
    """Straight-line FP32 code mixed with integer and memory code, 4 warps.

    An FP result writes 3 cycles after its EX cycle, an ALU result in EX,
    and both use write port 0, so the issue stage must hold ALU
    instructions back (the reservation). The scoreboard sees three
    latencies (ALU 1, FPU 4, LSU 2 or more). Integer ops on FP values make
    random bit patterns (NaN, denormals), and the FPU must handle them too."""
    rng = random.Random(seed)
    IN, OUT = 0x1000, 0x4000
    lines = [".blocks 2", ".threads 32", f".param 0 {IN}", f".param 1 {OUT}",
             f".randf {IN} 256 -8.0 8.0", f".memlat {rng.choice([1, 2, 4, 9])}"]
    if rng.random() < 0.5:
        lines.append(".backpressure")
    lines += ["s2r r1, tid", "s2r r2, ctaid", "shli r3, r2, 5", "add r1, r1, r3",
              "shli r1, r1, 2",                       # r1 = global id * 4
              "s2r r2, param0", "add r2, r2, r1",     # r2 = &in[gid]
              "s2r r3, param1", "shli r4, r1, 4", "add r3, r3, r4"]  # r3 = &out[gid*16]
    for r in range(4, 16):
        x = rng.random()
        if x < 0.75:
            v = f2bits(rng.uniform(-4.0, 4.0))
        elif x < 0.9:
            v = rng.choice(FP_SPECIAL)
        else:
            v = rng.getrandbits(32)
        lines.append(f"li r{r}, {v}")
    lines.append("ld r15, 0(r2)")
    for _ in range(rng.randint(60, 150)):
        rd, rs1, rs2, rs3 = (rng.randint(4, 15) for _ in range(4))
        x = rng.random()
        if x < 0.30:
            lines.append(f"{rng.choice(['fadd', 'fsub', 'fmul'])} r{rd}, r{rs1}, r{rs2}")
        elif x < 0.45:
            lines.append(f"ffma r{rd}, r{rs1}, r{rs2}, r{rs3}")
        elif x < 0.65:
            lines.append(f"{rng.choice(ALU_NAMES[1:])} r{rd}, r{rs1}, r{rs2}")
        elif x < 0.72:
            lines.append(f"{rng.choice(['addi', 'xori', 'andi', 'shri'])} r{rd}, r{rs1}, "
                         f"{rng.randrange(0, 1 << 12)}")
        elif x < 0.82:
            lines.append(f"ld r{rd}, {rng.randrange(0, 128) * 4 - 256}(r2)")
        elif x < 0.88:
            lines.append(f"st r{rs1}, {rng.randrange(16) * 4}(r3)")
        elif x < 0.92:
            lines.append(f"ld r{rd}, {rng.randrange(16) * 4}(r3)")
        else:
            lines.append(f"s2r r{rd}, {rng.choice(['tid', 'laneid', 'warpid'])}")
    for r in range(4, 16):
        lines.append(f"st r{r}, {(r - 4) * 4}(r3)")
    lines.append("exit")
    return "\n".join(lines) + "\n"


class BranchGen:
    """Random structured control flow. Every branch gets the correct rpc,
    because the generator knows where each if/else and each loop ends.

    Registers: r1..r3 addresses, r4..r11 data, r12..r14 loop counters
    (one for each loop level), r15 branch condition.
    The total nesting (if + loop) stays at 4 or less, so the stack needs at
    most 8 entries: the limit of the RTL."""

    MAX_NEST = 4

    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.lines = []
        self.n = 0

    def label(self, kind):
        self.n += 1
        return f"{kind}{self.n}"

    def data_reg(self):
        return f"r{self.rng.randint(4, 11)}"

    def op(self):
        rng, d = self.rng, self.data_reg
        x = rng.random()
        if x < 0.04:
            r = d()
            self.lines.append(f"andi {r}, {d()}, 1020")     # gather load
            self.lines.append(f"ld {r}, 4096({r})")
        elif x < 0.08:
            self.lines.append(f"lds {d()}, {rng.choice(self.own)}(r1)")
        elif x < 0.11:
            self.lines.append(f"sts {d()}, {rng.choice(self.own)}(r1)")
        elif x < 0.12:
            self.lines.append(f"ld {d()}, {rng.randrange(0, 128) * 4 - 256}(r2)")
        elif x < 0.20:
            self.lines.append(f"st {d()}, {rng.randrange(16) * 4}(r3)")
        elif x < 0.26:
            self.lines.append(f"ld {d()}, {rng.randrange(16) * 4}(r3)")
        elif x < 0.32:
            # FP inside divergent code: inactive lanes must keep their value
            if rng.random() < 0.3:
                self.lines.append(f"ffma {d()}, {d()}, {d()}, {d()}")
            else:
                self.lines.append(f"{rng.choice(['fadd', 'fsub', 'fmul'])} {d()}, {d()}, {d()}")
        elif x < 0.65:
            self.lines.append(f"{rng.choice(ALU_NAMES[1:])} {d()}, {d()}, {d()}")
        else:
            self.lines.append(f"{rng.choice(ALU_NAMES[1:])}i {d()}, {d()}, "
                              f"{rng.randrange(-2048, 2048)}")

    def cond(self):
        # A condition that differs between lanes most of the time.
        a, b = self.data_reg(), self.data_reg()
        self.lines.append(f"xor r15, {a}, {b}")
        self.lines.append(f"andi r15, r15, {1 << self.rng.randrange(0, 6)}")

    def block(self, nest, loops, size):
        for _ in range(size):
            x = self.rng.random()
            if x < 0.15 and nest < self.MAX_NEST:
                self.if_else(nest, loops)
            elif x < 0.22 and nest < self.MAX_NEST and loops < 3:
                self.loop(nest, loops)
            elif x < 0.24 and nest > 0:
                self.lines.append("exit")       # some lanes leave early
                return
            else:
                self.op()

    def if_else(self, nest, loops):
        els, join = self.label("else"), self.label("join")
        self.cond()
        self.lines.append(f"{self.rng.choice(['brz', 'brnz'])} r15, {els}, {join}")
        self.block(nest + 1, loops, self.rng.randint(1, 5))
        if self.rng.random() < 0.8:
            self.lines.append(f"jmp {join}")
            self.lines.append(f"{els}:")
            self.block(nest + 1, loops, self.rng.randint(1, 5))
        else:
            self.lines.append(f"{els}:")        # if without else: target == rpc
        self.lines.append(f"{join}:")

    def loop(self, nest, loops):
        top = self.label("loop")
        cnt = f"r{12 + loops}"
        self.lines.append(f"andi {cnt}, {self.data_reg()}, 3")
        self.lines.append(f"addi {cnt}, {cnt}, 1")     # 1..4 trips, per lane
        self.lines.append(f"{top}:")
        self.block(nest + 1, loops + 1, self.rng.randint(1, 4))
        self.lines.append(f"addi {cnt}, {cnt}, -1")
        self.lines.append(f"brnz {cnt}, {top}")

    def program(self):
        rng = self.rng
        IN, OUT = 0x1000, 0x4000
        L = [".blocks 2", f".threads {rng.choice([32, 32, 27, 13])}",
             f".param 0 {IN}", f".param 1 {OUT}", f".random {IN} 256",
             f".memlat {rng.choice([1, 2, 4, 9])}"]
        if rng.random() < 0.5:
            L.append(".backpressure")
        L += ["s2r r1, tid", "s2r r2, ctaid", "shli r3, r2, 5", "add r1, r1, r3",
              "shli r1, r1, 2", "s2r r2, param0", "add r2, r2, r1",
              "s2r r3, param1", "shli r4, r1, 4", "add r3, r3, r4",
              "ld r4, 0(r2)", "s2r r5, tid", "ld r6, 4(r2)", "s2r r7, laneid"]
        for r in range(8, 12):
            L.append(f"li r{r}, {rng.getrandbits(32)}")
        shl, self.own = shared_own(rng)
        L += ["s2r r1, tid", shl]
        L += [f"sts r{4 + k}, {self.own[k]}(r1)" for k in range(4)]
        self.lines = L
        self.if_else(0, 0)              # at least one if/else and one loop
        self.block(0, 0, rng.randint(4, 12))
        self.loop(0, 0)
        for r in range(4, 12):
            self.lines.append(f"st r{r}, {(r - 4) * 4}(r3)")
        self.lines.append("exit")
        return "\n".join(self.lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--random", type=int, default=20, help="number of random tests of each kind")
    args = ap.parse_args()
    out_root = ROOT / "build" / "tests"
    srcs = [(p.stem, p.read_text()) for p in sorted((ROOT / "tests").glob("*.s"))]
    srcs += [(f"rand_{i:02d}", random_program(1000 + i)) for i in range(args.random)]
    srcs += [(f"rbr_{i:02d}", BranchGen(2000 + i).program()) for i in range(args.random)]
    srcs += [(f"rfp_{i:02d}", fp_program(3000 + i)) for i in range(args.random)]
    ok = True
    for name, text in srcs:
        try:
            n, count, st = build_one(name, text, out_root)
            print(f"built {name:<16} {n:4d} instructions, {count:6d} warp instructions, "
                  f"{st['txn']:5d} txn, {st['bank_conflict']:4d} bank conflicts")
        except (AsmError, ModelError) as e:
            print(f"ERROR {name}: {e}")
            ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

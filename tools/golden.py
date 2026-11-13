"""Golden model: runs a kernel at warp level and gives the final memory.

The model is the reference for the RTL. The testbench compares the RTL's
final memory with the model's, word for word, and it also compares the
number of warp instructions issued.

Semantics the RTL must match:
- A block has ceil(threads / lanes) warps. tid = warp * lanes + lane.
- Each warp runs in SIMT style with an IPDOM reconvergence stack. Each stack
  entry is (pc, rpc, mask). A divergent branch sets the top entry's pc to the
  rpc and pushes the not-taken path, then the taken path. An entry pops when
  its pc reaches its rpc. Two rules keep the stack small (see the branch
  code below).
- Registers are undefined at launch. Reading one before a write is a test
  bug, and the model stops with an error.
- FP32 instructions follow tools/fp32.py (FTZ, round to nearest even).
- Stores from one instruction go out in lane order, so the highest lane wins
  when two lanes write the same word.
- bar waits until every warp of the block that has not exited arrives.
- The stack holds STACK_DEPTH entries below the top entry. A divergent
  branch that needs more stops the kernel (error code 2).
- Shared memory (lds/sts) belongs to one block. It is not set at block
  start, so a read before a write is a test bug, as for registers.
- A test runs one or more kernel launches, in order. Each launch has an
  entry PC, a grid size, a block size and 4 parameters.
- The model runs the blocks of a launch one after another, but the GPU
  runs them in parallel on 2 cores, in an order that the test cannot know.
  Thus a block must not read or write a global word that a different block
  of the same launch writes. The model stops with an error (a test bug) if
  this occurs. A later launch can read everything an earlier launch wrote.

Two counts are exact and the testbench checks them (stage 3):
- txn: global memory transactions. One ld/st makes one transaction for
  each different 32-byte line that its active lanes touch (the coalescer).
- bank_conflict: extra shared-memory cycles. Shared memory has 8 banks of
  one word; the bank is (address / 4) % 8. Lanes that use the same word
  share one access. An lds/sts takes as many cycles as the busiest bank
  has different words; each cycle after the first counts.
"""
from isa import decode, alu, MASK32, SREGS
from fp32 import fadd, fsub, fmul, fma

MEM_WORDS = 16384           # 64 KB global memory
STACK_DEPTH = 8
SMEM_WORDS = 256            # 1 KB shared memory per block
SMEM_BANKS = 8
LINE_SHIFT = 5              # 32-byte lines

# Error codes, the same numbers as the RTL err_code. 0 = a test bug that
# the RTL does not detect (read before write, infinite loop, ...).
ERR_ILLEGAL, ERR_STACK, ERR_MISALIGNED, ERR_BAR_DIV, ERR_SMEM_RANGE = 1, 2, 3, 4, 5


class ModelError(Exception):
    def __init__(self, msg, code=0):
        super().__init__(msg)
        self.code = code


class Entry:
    def __init__(self, pc, rpc, mask):
        self.pc, self.rpc, self.mask = pc, rpc, mask


def run(prog, mem, launches, lanes=8, warps=4, max_steps=10_000_000, stats=None):
    """Run the kernel launches in order. Each launch is a dict with the keys
    entry, blocks, threads, params. Changes mem in place. Returns the
    warp-instruction count. If stats is a dict, the model adds the "txn"
    and "bank_conflict" counts."""
    if stats is None:
        stats = {}
    stats.setdefault("txn", 0)
    stats.setdefault("bank_conflict", 0)
    count = 0
    for k, la in enumerate(launches):
        if not 1 <= la["threads"] <= lanes * warps:
            raise ModelError(f"launch {k}: threads must be 1..{lanes * warps}")
        race = Races(k)
        for ctaid in range(la["blocks"]):
            race.ctaid = ctaid
            count += _run_block(prog, mem, la["entry"], ctaid, la["blocks"], la["threads"],
                                la["params"], lanes, max_steps, stats, race)
    return count


class Races:
    """Finds global words that two blocks of one launch share, when one of
    them writes the word. The GPU runs the blocks in parallel, so the result
    would depend on timing."""

    def __init__(self, launch):
        self.launch = launch
        self.ctaid = 0
        self.writer = {}          # word -> the block that wrote it
        self.readers = {}         # word -> the blocks that read it

    def _fail(self, word, other):
        raise ModelError(f"launch {self.launch}: blocks {other} and {self.ctaid} share "
                         f"global word {word * 4:#x} and one writes it (a race)")

    def read(self, word):
        if self.writer.get(word, self.ctaid) != self.ctaid:
            self._fail(word, self.writer[word])
        self.readers.setdefault(word, set()).add(self.ctaid)

    def write(self, word):
        if self.writer.get(word, self.ctaid) != self.ctaid:
            self._fail(word, self.writer[word])
        others = self.readers.get(word, set()) - {self.ctaid}
        if others:
            self._fail(word, min(others))
        self.writer[word] = self.ctaid


def _run_block(prog, mem, entry, ctaid, nctaid, ntid, params, lanes, max_steps, stats, race):
    nwarps = (ntid + lanes - 1) // lanes
    W = []
    for w in range(nwarps):
        mask = sum(1 << l for l in range(lanes) if w * lanes + l < ntid)
        W.append({"id": w, "stack": [Entry(entry, -1, mask)], "done": False, "bar": False,
                  "regs": [[0] + [None] * 15 for _ in range(lanes)]})

    def sreg(w, lane, n):
        vals = {SREGS["tid"]: w["id"] * lanes + lane, SREGS["ctaid"]: ctaid,
                SREGS["ntid"]: ntid, SREGS["nctaid"]: nctaid, SREGS["laneid"]: lane,
                SREGS["warpid"]: w["id"], SREGS["coreid"]: 0}
        for i in range(4):
            vals[SREGS[f"param{i}"]] = params[i]
        return vals.get(n, 0) & MASK32

    smem = [None] * SMEM_WORDS
    count = 0
    steps = 0
    while not all(w["done"] for w in W):
        live = [w for w in W if not w["done"]]
        if all(w["bar"] for w in live):
            for w in live:
                w["bar"] = False
        for w in live:
            if w["bar"] or w["done"]:
                continue
            _step(w, prog, mem, smem, lanes, sreg, stats, race)
            count += 1
        steps += 1
        if steps > max_steps:
            raise ModelError("too many steps (infinite loop?)")
    return count


def _step(w, prog, mem, smem, lanes, sreg, stats, race):
    st = w["stack"]
    top = st[-1]
    pc = top.pc
    if pc >= len(prog):
        raise ModelError(f"warp {w['id']}: pc {pc} is past the end of the program")
    d = decode(prog[pc])
    act = [l for l in range(lanes) if top.mask >> l & 1]
    R = w["regs"]

    def rd_reg(l, r):
        v = R[l][r]
        if v is None:
            raise ModelError(f"warp {w['id']} lane {l} pc {pc}: r{r} read before write")
        return v

    def wr_reg(l, r, v):
        if r:
            R[l][r] = v & MASK32

    k = d["kind"]
    next_pc = pc + 1
    if k == "alu":
        for l in act:
            a = 0 if d["alu"] == 0 else rd_reg(l, d["rs1"])
            b = (d["uimm"] << 14 if d["op"] == 0x10 else d["imm"] & MASK32) \
                if d["use_imm"] else rd_reg(l, d["rs2"])
            wr_reg(l, d["rd"], alu(d["alu"], a, b))
    elif k in ("ld", "st", "lds", "sts"):
        addr = {l: (rd_reg(l, d["rs1"]) + d["imm"]) & MASK32 for l in act}
        for l in act:
            if addr[l] & 3:
                raise ModelError(f"warp {w['id']} lane {l} pc {pc}: misaligned {addr[l]:#x}",
                                 ERR_MISALIGNED)
        if k in ("ld", "st"):
            for l in act:
                if addr[l] >= MEM_WORDS * 4:
                    raise ModelError(f"warp {w['id']} lane {l} pc {pc}: bad address {addr[l]:#x}")
            stats["txn"] += len({a >> LINE_SHIFT for a in addr.values()})
            for l in act:                       # lane order: the highest lane wins
                if k == "ld":
                    race.read(addr[l] >> 2)
                    wr_reg(l, d["rd"], mem[addr[l] >> 2])
                else:
                    race.write(addr[l] >> 2)
                    mem[addr[l] >> 2] = rd_reg(l, d["rd"])
        else:
            for l in act:
                if addr[l] >= SMEM_WORDS * 4:
                    raise ModelError(f"warp {w['id']} lane {l} pc {pc}: shared address "
                                     f"{addr[l]:#x} out of range", ERR_SMEM_RANGE)
            banks = {}
            for a in addr.values():
                banks.setdefault((a >> 2) % SMEM_BANKS, set()).add(a >> 2)
            if banks:
                stats["bank_conflict"] += max(len(b) for b in banks.values()) - 1
            for l in act:
                i = addr[l] >> 2
                if k == "lds":
                    if smem[i] is None:
                        raise ModelError(f"warp {w['id']} lane {l} pc {pc}: shared word "
                                         f"{addr[l]:#x} read before write")
                    wr_reg(l, d["rd"], smem[i])
                else:
                    smem[i] = rd_reg(l, d["rd"])
    elif k in ("fadd", "fsub", "fmul", "ffma"):
        f = {"fadd": fadd, "fsub": fsub, "fmul": fmul}.get(k)
        for l in act:
            a, b = rd_reg(l, d["rs1"]), rd_reg(l, d["rs2"])
            wr_reg(l, d["rd"], fma(a, b, rd_reg(l, d["rs3"])) if k == "ffma" else f(a, b))
    elif k == "s2r":
        for l in act:
            wr_reg(l, d["rd"], sreg(w, l, d["uimm"]))
    elif k == "jmp":
        next_pc = d["target"]
    elif k in ("brz", "brnz"):
        taken = 0
        for l in act:
            z = rd_reg(l, d["rd"]) == 0
            if z == (k == "brz"):
                taken |= 1 << l
        if taken == top.mask:
            next_pc = d["target"]
        elif taken:
            # Divergence. Two rules keep the stack small (the RTL uses the
            # same rules, so the depth and the overflow point agree):
            # - no push of a path that starts at the rpc (it pops at once);
            # - if the top entry already reconverges at this rpc, the paths
            #   replace it (a divergent loop does not grow the stack).
            rpc = d["rpc"]
            new = []
            if pc + 1 != rpc:
                new.append(Entry(pc + 1, rpc, top.mask & ~taken))
            if d["target"] != rpc:
                new.append(Entry(d["target"], rpc, taken))
            if len(st) > 1 and top.rpc == rpc:
                st.pop()
            else:
                top.pc = rpc
            if len(st) - 1 + len(new) > STACK_DEPTH:
                raise ModelError(f"warp {w['id']} pc {pc}: reconvergence stack overflow",
                                 ERR_STACK)
            st.extend(new)
            _pop(st)
            return
    elif k == "bar":
        if len(st) > 1:
            raise ModelError(f"warp {w['id']} pc {pc}: bar inside divergent code",
                             ERR_BAR_DIV)
        w["bar"] = True
    elif k == "exit":
        gone = top.mask
        for e in st:
            e.mask &= ~gone
        st[:] = [e for e in st if e.mask]
        if not st:
            w["done"] = True
            return
        _pop(st)
        return
    elif k == "illegal":
        raise ModelError(f"warp {w['id']} pc {pc}: illegal instruction {prog[pc]:#010x}",
                         ERR_ILLEGAL)
    top.pc = next_pc
    _pop(st)


def _pop(st):
    while len(st) > 1 and st[-1].pc == st[-1].rpc:
        st.pop()

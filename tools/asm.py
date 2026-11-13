"""Two-pass assembler for the SIMT ISA.

A source file holds the kernel code and the test set-up directives:

    .blocks N              number of thread blocks in the grid
    .threads N             threads per block (1 .. warps*lanes)
    .param I EXPR          kernel parameter I (0..3), read with s2r rX, paramI
    .launch ENTRY BLOCKS THREADS [P0 P1 P2 P3]
                           one kernel launch. A test can have up to 8; they
                           run in order. Without .launch, the test has one
                           launch at PC 0 from .blocks, .threads and .param.
    .equ NAME EXPR         a named constant (define it before use)
    .words ADDR V V ...    put words in global memory
    .seq ADDR N START STEP put N words START, START+STEP, ...
    .random ADDR N         put N random words (seed comes from the file name)
    .floats ADDR X X ...   put FP32 values in global memory
    .randf ADDR N LO HI    put N random FP32 values in [LO, HI)
    .memlat N              memory latency in cycles for this test
    .backpressure          the memory model sometimes refuses requests
    .expect_err N          the kernel must stop with error code N (negative test)
    .expect_l1 H M         the RTL must count H L1 hits and M misses (only for
                           tests where the access order is fixed, e.g. one warp)

Pseudo-instructions: li rd, value / mov rd, rs.
In an expression, f(x) gives the FP32 bits of x, e.g. "li r4, f(0.5)".
A branch is "brz rs, target, rpc". The rpc (reconvergence PC) may be left
out only for a backward branch (a loop); then it is the next instruction.
"""
import re
import sys

from isa import OPS, SREGS, enc_r, enc_r4, enc_i, enc_b, NUM_REGS, PC_BITS
from fp32 import f2bits


class AsmError(Exception):
    pass


def _reg(tok):
    m = re.fullmatch(r"r(\d+)", tok.strip().lower())
    if not m or int(m.group(1)) >= NUM_REGS:
        raise AsmError(f"bad register '{tok}'")
    return int(m.group(1))


def _value(tok, syms):
    try:
        return int(eval(tok, {"__builtins__": {}, "f": f2bits}, syms))
    except Exception:
        raise AsmError(f"bad value '{tok}'")


def _split_ops(text):
    return [t.strip() for t in text.split(",")] if text.strip() else []


def _li_words(rd, v):
    v &= 0xFFFFFFFF
    sv = v - (1 << 32) if v >> 31 else v
    if -(1 << 17) <= sv < (1 << 17):
        return [enc_i(OPS["addi"], rd, 0, sv)]
    return [enc_i(OPS["lui"], rd, 0, v >> 14),
            enc_i(OPS["ori"], rd, rd, v & 0x3FFF)]


def assemble(text):
    """Return (words, config). config holds the directives."""
    cfg = {"blocks": 1, "threads": 8, "params": [0, 0, 0, 0], "mem": [],
           "memlat": 4, "backpressure": False, "expect_err": 0, "expect_l1": None}
    raw_launches = []
    syms = {}
    lines = []                                   # (lineno, mnemonic, operands)
    for n, raw in enumerate(text.splitlines(), 1):
        line = re.split(r"[#;]", raw, maxsplit=1)[0].strip()
        while line:
            m = re.match(r"([A-Za-z_]\w*):\s*(.*)", line)
            if not m:
                break
            lines.append((n, "label", m.group(1)))
            line = m.group(2)
        if line:
            parts = line.split(None, 1)
            lines.append((n, parts[0].lower(), parts[1] if len(parts) > 1 else ""))

    # Pass 1: directives, label addresses, instruction sizes.
    pc = 0
    labels = {}
    for n, mn, ops in lines:
        try:
            if mn == "label":
                labels[ops] = pc
                syms[ops] = pc
            elif mn.startswith("."):
                args = ops.split()
                if mn == ".equ":
                    syms[args[0]] = _value(args[1], syms)
                elif mn in (".blocks", ".threads", ".memlat", ".expect_err"):
                    cfg[mn[1:]] = _value(args[0], syms)
                elif mn == ".backpressure":
                    cfg["backpressure"] = True
                elif mn == ".expect_l1":
                    cfg["expect_l1"] = [_value(a, syms) for a in args[:2]]
                elif mn == ".launch":
                    if not 3 <= len(args) <= 7:
                        raise AsmError(".launch needs ENTRY BLOCKS THREADS [P0..P3]")
                    raw_launches.append((n, args))
                elif mn == ".param":
                    cfg["params"][_value(args[0], syms)] = _value(args[1], syms) & 0xFFFFFFFF
                elif mn in (".words", ".seq", ".random"):
                    cfg["mem"].append((mn[1:], [_value(a, syms) for a in args]))
                elif mn in (".floats", ".randf"):
                    vals = [_value(args[0], syms)] + [float(eval(a, {"__builtins__": {}}, syms))
                                                      for a in args[1:]]
                    cfg["mem"].append((mn[1:], vals))
                else:
                    raise AsmError(f"unknown directive {mn}")
            elif mn == "li":
                rd, v = _split_ops(ops)
                pc += len(_li_words(_reg(rd), _value(v, syms)))
            else:
                pc += 1
        except AsmError as e:
            raise AsmError(f"line {n}: {e}")

    # Launches. Labels are known now, so ENTRY can be a label.
    if raw_launches:
        cfg["launches"] = []
        for n, args in raw_launches:
            try:
                v = [_value(a, syms) for a in args]
            except AsmError as e:
                raise AsmError(f"line {n}: {e}")
            cfg["launches"].append({"entry": v[0], "blocks": v[1], "threads": v[2],
                                    "params": [p & 0xFFFFFFFF for p in (v[3:] + [0] * 4)[:4]]})
        if len(cfg["launches"]) > 8:
            raise AsmError("more than 8 launches")
    else:
        cfg["launches"] = [{"entry": 0, "blocks": cfg["blocks"], "threads": cfg["threads"],
                            "params": list(cfg["params"])}]

    # Pass 2: encode.
    words = []
    for n, mn, ops in lines:
        if mn == "label" or mn.startswith("."):
            continue
        try:
            words += _encode(mn, _split_ops(ops), len(words), syms)
        except AsmError as e:
            raise AsmError(f"line {n}: {mn} {ops}: {e}")
    if len(words) > (1 << PC_BITS):
        raise AsmError("program too long")
    return words, cfg


def _encode(mn, a, pc, syms):
    def need(k):
        if len(a) != k:
            raise AsmError(f"expects {k} operands")
    if mn in ("nop", "bar", "exit"):
        need(0)
        return [OPS[mn] << 26]
    if mn == "li":
        need(2)
        return _li_words(_reg(a[0]), _value(a[1], syms))
    if mn == "mov":
        need(2)
        return [enc_r(OPS["add"], _reg(a[0]), _reg(a[1]), 0)]
    if mn == "lui":
        need(2)
        return [enc_i(OPS["lui"], _reg(a[0]), 0, _value(a[1], syms))]
    if mn == "s2r":
        need(2)
        if a[1].lower() not in SREGS:
            raise AsmError(f"unknown special register '{a[1]}'")
        return [enc_i(OPS["s2r"], _reg(a[0]), 0, SREGS[a[1].lower()])]
    if mn in ("ld", "st", "lds", "sts"):
        need(2)
        m = re.fullmatch(r"(.*)\((\s*r\d+\s*)\)", a[1])
        if not m:
            raise AsmError("address must be imm(rs)")
        imm = _value(m.group(1), syms) if m.group(1).strip() else 0
        return [enc_i(OPS[mn], _reg(a[0]), _reg(m.group(2)), imm)]
    if mn == "jmp":
        need(1)
        return [enc_b(OPS["jmp"], 0, _value(a[0], syms), 0)]
    if mn in ("brz", "brnz"):
        if len(a) not in (2, 3):
            raise AsmError("expects rs, target[, rpc]")
        target = _value(a[1], syms)
        if len(a) == 3:
            rpc = _value(a[2], syms)
        elif target <= pc:
            rpc = pc + 1
        else:
            raise AsmError("a forward branch needs an explicit rpc")
        return [enc_b(OPS[mn], _reg(a[0]), target, rpc)]
    if mn in ("fadd", "fsub", "fmul"):
        need(3)
        return [enc_r(OPS[mn], _reg(a[0]), _reg(a[1]), _reg(a[2]))]
    if mn == "ffma":
        need(4)
        return [enc_r4(OPS[mn], _reg(a[0]), _reg(a[1]), _reg(a[2]), _reg(a[3]))]
    if mn in OPS and 0 < OPS[mn] < 0x20:
        need(3)
        if OPS[mn] & 0x10:
            imm = _value(a[2], syms)
            if not -(1 << 17) <= imm < (1 << 17):
                raise AsmError("immediate does not fit in 18 bits")
            return [enc_i(OPS[mn], _reg(a[0]), _reg(a[1]), imm)]
        return [enc_r(OPS[mn], _reg(a[0]), _reg(a[1]), _reg(a[2]))]
    raise AsmError(f"unknown instruction '{mn}'")


if __name__ == "__main__":
    words, _ = assemble(open(sys.argv[1]).read())
    for w in words:
        print(f"{w:08x}")

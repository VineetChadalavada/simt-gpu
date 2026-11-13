"""The SIMT ISA: opcodes, encodings, and the integer ALU.

This file is the single source of truth for the Python tools. The RTL copy
of the same numbers is rtl/core/isa_defs.vh. docs/ISA.md explains them.

Instruction format (32 bits):

    [31:26] op
    R-type  [25:22] rd   [21:18] rs1  [17:14] rs2  ([13:10] rs3 for ffma)
    I-type  [25:22] rd   [21:18] rs1  [17:0]  imm18 (signed)
    branch  [25:22] rs   [21:11] target  [10:0] rpc (reconvergence PC)

The PC counts instructions, not bytes. 11 bits -> 2048 instructions.
"""

MASK32 = 0xFFFFFFFF

ALU_NAMES = ["pass", "add", "sub", "mul", "and", "or", "xor", "shl",
             "shr", "sra", "slt", "sltu", "min", "max", "seq", "sne"]

OPS = {"nop": 0x00, "lui": 0x10}
for _i, _n in enumerate(ALU_NAMES):
    if _i:
        OPS[_n] = _i              # R-type: op[4] = 0
        OPS[_n + "i"] = 0x10 | _i  # I-type: op[4] = 1
OPS.update({"ld": 0x20, "st": 0x21, "lds": 0x22, "sts": 0x23, "s2r": 0x24,
            "fadd": 0x28, "fsub": 0x29, "fmul": 0x2A, "ffma": 0x2B,
            "jmp": 0x30, "brz": 0x31, "brnz": 0x32, "bar": 0x33, "exit": 0x3F})

SREGS = {"tid": 0, "ctaid": 1, "ntid": 2, "nctaid": 3,
         "laneid": 4, "warpid": 5, "coreid": 6,
         "param0": 8, "param1": 9, "param2": 10, "param3": 11}

PC_BITS = 11
NUM_REGS = 16


def sext(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def signed(x):
    return sext(x, 32)


def enc_r(op, rd, rs1, rs2):
    return (op << 26) | (rd << 22) | (rs1 << 18) | (rs2 << 14)


def enc_r4(op, rd, rs1, rs2, rs3):
    return enc_r(op, rd, rs1, rs2) | (rs3 << 10)


def enc_i(op, rd, rs1, imm):
    return (op << 26) | (rd << 22) | (rs1 << 18) | (imm & 0x3FFFF)


def enc_b(op, rs, target, rpc):
    return (op << 26) | (rs << 22) | (target << 11) | rpc


def decode(word):
    """Split one instruction word into named fields."""
    op = word >> 26
    d = {"op": op,
         "rd": (word >> 22) & 15, "rs1": (word >> 18) & 15, "rs2": (word >> 14) & 15,
         "rs3": (word >> 10) & 15,
         "imm": sext(word, 18), "uimm": word & 0x3FFFF,
         "target": (word >> 11) & 0x7FF, "rpc": word & 0x7FF}
    if op == 0:
        d["kind"] = "nop"
    elif op < 0x20:
        d["kind"] = "alu"
        d["alu"] = op & 15
        d["use_imm"] = bool(op & 0x10)
    else:
        names = {0x20: "ld", 0x21: "st", 0x22: "lds", 0x23: "sts", 0x24: "s2r",
                 0x28: "fadd", 0x29: "fsub", 0x2A: "fmul", 0x2B: "ffma", 0x30: "jmp", 0x31: "brz",
                 0x32: "brnz", 0x33: "bar", 0x3F: "exit"}
        d["kind"] = names.get(op, "illegal")
    return d


def alu(op, a, b):
    """The 16 ALU operations. a and b are unsigned 32-bit values."""
    sh = b & 31
    if op == 0:  r = b                                   # pass (LUI)
    elif op == 1:  r = a + b
    elif op == 2:  r = a - b
    elif op == 3:  r = a * b
    elif op == 4:  r = a & b
    elif op == 5:  r = a | b
    elif op == 6:  r = a ^ b
    elif op == 7:  r = a << sh
    elif op == 8:  r = a >> sh
    elif op == 9:  r = signed(a) >> sh
    elif op == 10: r = int(signed(a) < signed(b))
    elif op == 11: r = int(a < b)
    elif op == 12: r = min(signed(a), signed(b))
    elif op == 13: r = max(signed(a), signed(b))
    elif op == 14: r = int(a == b)
    else:          r = int(a != b)
    return r & MASK32

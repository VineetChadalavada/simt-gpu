"""Bit-exact FP32 reference for the FPU (golden model and test vectors).

All four instructions are one fused multiply-add, fma(a, b, c) = a * b + c
with one rounding:
    fadd a, b  = fma(a, 1.0, b)
    fsub a, b  = fma(a, 1.0, -b)
    fmul a, b  = fma(a, b, -0.0)     (-0.0 so that x * y + c keeps the sign of a zero product)
    ffma a, b, c

Rules (the usual GPU subset of IEEE 754):
- Round to nearest, ties to even.
- Denormals are zero: a denormal input is read as a zero of the same sign,
  and a result below 2^-126 (after rounding) becomes a zero of its sign.
- A NaN result is always the canonical quiet NaN 0x7FC00000.
- inf * 0, and inf + (-inf), give NaN.
- An exact zero sum of nonzero terms is +0. A sum of two zeros is -0
  only if both are -0.

This model computes the exact value with Python integers and rounds once.
The RTL (rtl/core/fma32.v) uses a fixed-width datapath with a sticky-bit
trick; the two methods are independent.
"""

QNAN = 0x7FC00000
ONE = 0x3F800000
NEG_ZERO = 0x80000000


def _unpack(x):
    s, e, m = x >> 31, (x >> 23) & 0xFF, x & 0x7FFFFF
    if e == 255:
        return s, "nan" if m else "inf", 0, 0
    if e == 0:
        return s, "zero", 0, 0                       # denormals are zero
    return s, "num", e, m | 0x800000


def fma(a, b, c):
    sa, ka, ea, ma = _unpack(a)
    sb, kb, eb, mb = _unpack(b)
    sc, kc, ec, mc = _unpack(c)
    sp = sa ^ sb
    if "nan" in (ka, kb, kc):
        return QNAN
    p_inf = "inf" in (ka, kb)
    if p_inf and "zero" in (ka, kb):
        return QNAN
    if p_inf or kc == "inf":
        if p_inf and kc == "inf" and sp != sc:
            return QNAN
        return ((sp if p_inf else sc) << 31) | 0x7F800000
    terms = []
    if "zero" not in (ka, kb):
        terms.append((sp, ma * mb, ea + eb - 300))   # value = P * 2^(ea-127-23 + eb-127-23)
    if kc != "zero":
        terms.append((sc, mc, ec - 150))
    if not terms:
        return (sp & sc) << 31
    low = min(t[2] for t in terms)
    x = sum((-1 if s else 1) * (m << (e - low)) for s, m, e in terms)
    if x == 0:
        return 0
    sign = 1 if x < 0 else 0
    x = abs(x)
    n = x.bit_length()
    exp = low + n - 1                                # value is in [2^exp, 2^(exp+1))
    if n > 24:
        sh = n - 24
        q, rem, half = x >> sh, x & ((1 << sh) - 1), 1 << (sh - 1)
        if rem > half or (rem == half and q & 1):
            q += 1
            if q == 1 << 24:
                q >>= 1
                exp += 1
    else:
        q = x << (24 - n)
    biased = exp + 127
    if biased >= 255:
        return (sign << 31) | 0x7F800000
    if biased <= 0:
        return sign << 31                            # flush to zero
    return (sign << 31) | (biased << 23) | (q & 0x7FFFFF)


def fadd(a, b):
    return fma(a, ONE, b)


def fsub(a, b):
    return fma(a, ONE, b ^ 0x80000000)


def fmul(a, b):
    return fma(a, b, NEG_ZERO)


def f2bits(v):
    """A Python float -> FP32 bits (round to nearest even)."""
    import struct
    return struct.unpack("<I", struct.pack("<f", v))[0]


def bits2f(x):
    import struct
    return struct.unpack("<f", struct.pack("<I", x & 0xFFFFFFFF))[0]


def _selftest():
    import random
    import struct
    rng = random.Random(1)

    def normal():
        while True:
            x = rng.getrandbits(32)
            if 0 < (x >> 23) & 0xFF < 255:
                return x
    # fadd and fmul of two normal numbers: Python's double gives the exact
    # result rounded once to 53 bits; one more rounding to 24 bits is exact
    # for + and * (53 >= 2*24 + 2). Compare where no denormal/overflow occurs.
    n = 0
    for _ in range(200000):
        a, b = normal(), normal()
        for op, f in ((fadd, lambda x, y: x + y), (fmul, lambda x, y: x * y)):
            r = f(bits2f(a), bits2f(b))
            try:
                ref = struct.unpack("<I", struct.pack("<f", r))[0]
            except OverflowError:
                continue
            e = (ref >> 23) & 0xFF
            if e == 0 or e == 255:
                continue
            got = op(a, b)
            assert got == ref, (op.__name__, hex(a), hex(b), hex(got), hex(ref))
            n += 1
    print(f"fp32 self-test: {n} fadd/fmul results agree with the host FPU")


if __name__ == "__main__":
    _selftest()

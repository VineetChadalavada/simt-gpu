"""Test vectors for the FMA unit (rtl/core/fma32.v), from tools/fp32.py.

    python tools/fp_vectors.py [N]   ->  build/fpu/vectors.hex

Each vector is 4 words: a, b, c, expected a*b+c. The classes aim at the
hard parts of a fused multiply-add:
  random      random bit patterns
  special     zeros of both signs, denormals, inf, NaN, 1.0, extremes
  cancel      c = -round(a*b): the result is only the rounding error of
              the product, which an unfused (two-rounding) design gets wrong
  align       c with an exponent near the product's, -60..+60 apart: this
              crosses the alignment limits of the RTL (s = 50, -s = 26)
  ripple      the product's low 23 bits are all ones (mb = -1/ma mod 2^23)
              and the addend overlaps them: a carry runs up to the round
              bit. Only this class finds a too-small alignment limit.
  ranges      products near overflow and near the denormal range
  add/mul     fadd (b = 1.0) and fmul (c = -0.0) with close exponents
"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from fp32 import fma, fmul, ONE, NEG_ZERO      # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

SPECIAL = [0x00000000, 0x80000000, 0x00000001, 0x807FFFFF, 0x00400000,   # zeros, denormals
           0x7F800000, 0xFF800000, 0x7FC00000, 0xFFC00001, 0x7F800001,   # inf, NaN
           0x3F800000, 0xBF800000, 0x00800000, 0x80800000,               # 1, -1, min normal
           0x7F7FFFFF, 0xFF7FFFFF, 0x3F7FFFFF, 0x33800000, 0x4B800000]   # max, 1-ulp, 2^-24, 2^24


def mk(rng, s, e, m=None):
    return (s << 31) | ((e & 0xFF) << 23) | (rng.getrandbits(23) if m is None else m)


def normal(rng, lo=1, hi=254):
    return mk(rng, rng.getrandbits(1), rng.randint(lo, hi))


def vectors(n, seed=7):
    rng = random.Random(seed)
    out = []
    per = n // 8
    for _ in range(per):                                     # random
        out.append((rng.getrandbits(32), rng.getrandbits(32), rng.getrandbits(32)))
    for _ in range(per):                                     # special
        pick = lambda: rng.choice(SPECIAL) if rng.random() < 0.6 else normal(rng)  # noqa: E731
        out.append((pick(), pick(), pick()))
    for _ in range(per):                                     # cancel
        a, b = normal(rng, 64, 190), normal(rng, 64, 190)
        c = fmul(a, b) ^ 0x80000000
        if rng.random() < 0.5:                               # sometimes 1 ulp away
            c = (c + rng.choice([-1, 1])) & 0xFFFFFFFF
        out.append((a, b, c))
    for _ in range(per):                                     # align
        ea, eb = rng.randint(40, 214), rng.randint(40, 214)
        ec = ea + eb - 127 + rng.randint(-60, 60)
        if 1 <= ec <= 254:
            m = rng.choice([None, 0, 0x7FFFFF])
            out.append((mk(rng, rng.getrandbits(1), ea), mk(rng, rng.getrandbits(1), eb),
                        mk(rng, rng.getrandbits(1), ec, m)))
    for _ in range(per):                                     # ripple
        ma = rng.getrandbits(23) | 0x800001                   # odd, hidden bit set
        mb = ((-pow(ma, -1, 1 << 23)) % (1 << 23)) | 0x800000
        ea, eb = rng.randint(60, 190), rng.randint(60, 190)
        t = rng.randint(15, 30)                               # lsb(P) - lsb(C)
        ec = ea + eb - 150 - t
        if 1 <= ec <= 254:
            s = rng.getrandbits(1)
            out.append(((s << 31) | (ea << 23) | (ma & 0x7FFFFF), (eb << 23) | (mb & 0x7FFFFF),
                        mk(rng, s, ec)))
    for _ in range(per):                                     # ranges
        if rng.random() < 0.5:
            ea = rng.randint(120, 254); eb = 254 + 127 - ea + rng.randint(-3, 2)
        else:
            ea = rng.randint(1, 127); eb = 127 + 1 - ea + rng.randint(-3, 3)
        if 1 <= eb <= 254:
            c = rng.choice([NEG_ZERO, 0, normal(rng, 1, 3), normal(rng, 250, 254)])
            out.append((normal(rng, ea, ea), normal(rng, eb, eb), c))
    for _ in range(per):                                     # fadd
        a = normal(rng, 2, 253)
        e = ((a >> 23) & 0xFF) + rng.randint(-60, 60)
        if 1 <= e <= 254:
            c = mk(rng, rng.getrandbits(1), e)
            out.append((a, ONE, c))
    for _ in range(per):                                     # fmul
        out.append((normal(rng), normal(rng), NEG_ZERO))
    return [(a, b, c, fma(a, b, c)) for a, b, c in out]


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200000
    v = vectors(n)
    d = ROOT / "build" / "fpu"
    d.mkdir(parents=True, exist_ok=True)
    (d / "vectors.hex").write_text("".join(f"{x:08x}\n" for t in v for x in t))
    (d / "count.hex").write_text(f"{len(v):08x}\n")
    print(f"{len(v)} FMA vectors -> {d / 'vectors.hex'}")


if __name__ == "__main__":
    main()

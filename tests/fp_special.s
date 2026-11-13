# FP32 special cases. Thread t takes a = A[t], b = B[t], c = C[t] and
# stores fadd(a,b), fsub(a,b), fmul(a,b), ffma(a,b,c) at OUT + 16t.
# The 32 rows cover: signed zeros, denormal inputs (read as zero), inf,
# NaN (any NaN gives 0x7FC00000), inf*0, inf-inf, overflow to inf,
# underflow to zero (flush), exact cancellation (+0), and a fused case
# where only the rounding error of a*b remains.
.blocks 1
.threads 32
.equ A 0x1000
.equ B 0x1080
.equ C 0x1100
.equ OUT 0x2000
.equ INF 0x7F800000
.equ NINF 0xFF800000
.equ NAN 0x7FC00000
.equ SNAN 0x7F800001
.equ DEN 0x00000001
.equ NDEN 0x807FFFFF
.equ MAX 0x7F7FFFFF
.equ MINN 0x00800000
.equ P1U 0x3F800001
.words A 0     0x80000000 f(1.0) f(-1.0) INF  INF  NAN  DEN  MAX    MINN    f(3.0) SNAN f(1e30) NINF f(1.5) f(0.1) 0 INF NINF f(1.0) f(2.0**64) f(2.0**-64) 0x80000000 DEN MAX P1U f(3.0) f(1.0) f(-2.0) f(0.5) f(7.0) MINN
.words B 0x80000000 0x80000000 f(-1.0) f(1.0) 0 NINF f(1.0) f(5.0) MAX f(0.5) f(1.0/3) f(1.0) f(1e30) INF f(1.5) f(0.1) INF INF NINF NDEN f(2.0**64) f(2.0**-64) 0 DEN f(-2.0) P1U f(-3.0) f(1.0) f(2.0) f(-0.5) f(-7.0) f(-0.5)
.words C 0 0x80000000 f(1.0) f(-1.0) f(1.0) INF f(1.0) DEN f(1.0) MINN f(-1.0) f(1.0) NINF INF f(-2.25) f(-0.01) 0 NINF INF 0x80000000 NINF 0 0x80000000 0 MAX 0xBF800002 f(9.0) f(-1.0) f(4.0) f(0.25) f(49.0) MINN
        s2r  r1, tid
        shli r2, r1, 2
        ld   r3, A(r2)
        ld   r4, B(r2)
        ld   r5, C(r2)
        shli r6, r1, 4
        fadd r7, r3, r4
        st   r7, OUT(r6)
        fsub r7, r3, r4
        st   r7, OUT+4(r6)
        fmul r7, r3, r4
        st   r7, OUT+8(r6)
        ffma r7, r3, r4, r5
        st   r7, OUT+12(r6)
        exit

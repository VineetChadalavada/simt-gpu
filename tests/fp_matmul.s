# C = A * B for 8x8 FP32 matrices, one thread per element of C, one ffma
# per step. 2 blocks x 32 threads. The order of the sums is fixed (k = 0..7),
# so the result is bit-exact.
.blocks 2
.threads 32
.equ A 0x1000
.equ B 0x1100
.equ C 0x1200
.param 0 A
.param 1 B
.param 2 C
.randf A 64 -2.0 2.0
.randf B 64 -2.0 2.0
        s2r  r1, tid
        s2r  r2, ctaid
        shli r2, r2, 5
        add  r1, r1, r2          # gid = row * 8 + col
        shri r2, r1, 3           # row
        andi r3, r1, 7           # col
        s2r  r4, param0
        shli r5, r2, 5
        add  r4, r4, r5          # &A[row][0]
        s2r  r5, param1
        shli r6, r3, 2
        add  r5, r5, r6          # &B[0][col]
        li   r6, 0               # acc = +0.0
        li   r7, 8
kloop:  ld   r8, 0(r4)
        ld   r9, 0(r5)
        ffma r6, r8, r9, r6      # acc += A[row][k] * B[k][col]
        addi r4, r4, 4
        addi r5, r5, 32
        addi r7, r7, -1
        brnz r7, kloop
        s2r  r4, param2
        shli r1, r1, 2
        add  r4, r4, r1
        st   r6, 0(r4)
        exit

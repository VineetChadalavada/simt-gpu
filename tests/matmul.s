# C = A * B for 8x8 integer matrices. One thread per element of C:
# 2 blocks x 32 threads = 64 threads.
.blocks 2
.threads 32
.equ A 0x1000
.equ B 0x1100
.equ C 0x1200
.param 0 A
.param 1 B
.param 2 C
.random A 64
.random B 64
        s2r  r1, tid
        s2r  r2, ctaid
        s2r  r3, ntid
        mul  r2, r2, r3
        add  r1, r1, r2          # gid = row * 8 + col
        shri r2, r1, 3           # row
        andi r3, r1, 7           # col
        s2r  r4, param0
        shli r5, r2, 5
        add  r4, r4, r5          # &A[row][0]
        s2r  r5, param1
        shli r6, r3, 2
        add  r5, r5, r6          # &B[0][col]
        li   r6, 0               # acc
        li   r7, 8               # k counter
kloop:  ld   r8, 0(r4)
        ld   r9, 0(r5)
        mul  r8, r8, r9
        add  r6, r6, r8
        addi r4, r4, 4
        addi r5, r5, 32
        addi r7, r7, -1
        brnz r7, kloop
        s2r  r4, param2
        shli r1, r1, 2
        add  r4, r4, r1
        st   r6, 0(r4)
        exit

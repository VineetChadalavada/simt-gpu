# Dot product of two FP32 vectors of 256 elements. Each of 2 blocks does
# half: each thread does 4 ffma steps, then the block adds the 32 partial
# sums in shared memory (a tree: 16, 8, 4, 2, 1 with bar between the steps).
# Thread 0 writes the block's sum. The tree fixes the order of the adds, so
# the result is bit-exact.
.blocks 2
.threads 32
.equ X 0x1000
.equ Y 0x1400
.equ OUT 0x1800
.param 0 X
.param 1 Y
.param 2 OUT
.randf X 256 -1.0 1.0
.randf Y 256 -1.0 1.0
        s2r  r1, tid
        s2r  r2, ctaid
        shli r2, r2, 7           # ctaid * 128 elements
        add  r2, r2, r1
        shli r2, r2, 2
        s2r  r3, param0
        add  r3, r3, r2          # &x[ctaid*128 + tid]
        s2r  r4, param1
        add  r4, r4, r2
        li   r5, 0               # partial = +0.0
        li   r6, 4
step:   ld   r7, 0(r3)
        ld   r8, 0(r4)
        ffma r5, r7, r8, r5
        addi r3, r3, 128         # stride 32 elements
        addi r4, r4, 128
        addi r6, r6, -1
        brnz r6, step
        shli r9, r1, 2           # my shared word
        sts  r5, 0(r9)
        bar
        li   r10, 16             # tree: n = 16, 8, 4, 2, 1
tree:   slt  r11, r1, r10        # tid < n ?
        brz  r11, skip, skip
        lds  r12, 0(r9)
        shli r13, r10, 2
        add  r13, r13, r9
        lds  r14, 0(r13)         # s[tid + n]
        fadd r12, r12, r14
        sts  r12, 0(r9)
skip:   bar
        shri r10, r10, 1
        brnz r10, tree
        brnz r1, done, done      # thread 0 only
        lds  r12, 0(r0)
        s2r  r13, ctaid
        shli r13, r13, 2
        s2r  r14, param2
        add  r14, r14, r13
        st   r12, 0(r14)
done:   exit

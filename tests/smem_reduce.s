# Tree sum of 32 values per block in shared memory.
# Round s = 16, 8, 4, 2, 1: threads with tid < s add S[tid + s] to S[tid].
# A bar ends each round. The "if" reconverges before the bar, so the bar
# is in convergent code. Thread 0 writes the block sum.
.blocks 4
.threads 32
.equ IN 0x1000
.equ OUT 0x2000
.param 0 IN
.param 1 OUT
.random IN 128
        s2r  r1, tid
        s2r  r2, ctaid
        shli r3, r2, 5
        add  r3, r3, r1
        shli r3, r3, 2
        s2r  r4, param0
        add  r4, r4, r3
        ld   r5, 0(r4)
        shli r6, r1, 2           # &S[tid]
        sts  r5, 0(r6)
        bar
        li   r7, 16              # s
top:    slt  r8, r1, r7
        brz  r8, skip, skip      # only tid < s
        lds  r9, 0(r6)
        shli r10, r7, 2
        add  r10, r10, r6
        lds  r11, 0(r10)         # S[tid + s]
        add  r9, r9, r11
        sts  r9, 0(r6)
skip:   bar
        shri r7, r7, 1
        brnz r7, top
        brnz r1, done, done      # only thread 0 continues
        lds  r9, 0(r0)
        s2r  r10, param1
        shli r11, r2, 2
        add  r10, r10, r11
        st   r9, 0(r10)          # out[ctaid] = sum
done:   exit

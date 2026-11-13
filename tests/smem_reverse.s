# Reverse each block's 32 words through shared memory.
# Each thread writes one shared word, waits at bar, then reads the word of
# thread 31 - tid (a word that a different warp wrote). No bank conflicts:
# the 8 lanes of a warp always use 8 different banks.
.blocks 3
.threads 32
.equ IN 0x1000
.equ OUT 0x2000
.param 0 IN
.param 1 OUT
.random IN 96
        s2r  r1, tid
        s2r  r2, ctaid
        shli r3, r2, 5
        add  r3, r3, r1
        shli r3, r3, 2           # gid * 4
        s2r  r4, param0
        add  r4, r4, r3
        ld   r5, 0(r4)
        shli r6, r1, 2
        sts  r5, 0(r6)           # S[tid] = in[gid]
        bar
        li   r7, 31
        sub  r7, r7, r1
        shli r7, r7, 2
        lds  r8, 0(r7)           # S[31 - tid]
        s2r  r4, param1
        add  r4, r4, r3
        st   r8, 0(r4)
        exit

# A uniform loop: every thread runs the same number of iterations.
# out[gid] = sum over k < N of (in[k] + tid * k)
.blocks 2
.threads 32
.param 0 0x1000
.param 1 0x2000
.param 2 10
.random 0x1000 16
        s2r  r1, tid
        s2r  r2, ctaid
        shli r3, r2, 5
        add  r3, r3, r1          # gid
        li   r4, 0               # sum
        li   r5, 0               # k
        s2r  r6, param2          # N
        s2r  r7, param0          # &in[0]
loop:   ld   r8, 0(r7)
        mul  r9, r1, r5
        add  r8, r8, r9
        add  r4, r4, r8
        addi r7, r7, 4
        addi r5, r5, 1
        sub  r10, r6, r5
        brnz r10, loop
        s2r  r7, param1
        shli r3, r3, 2
        add  r7, r7, r3
        st   r4, 0(r7)
        exit

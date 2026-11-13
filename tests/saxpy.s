# y[i] = alpha * x[i] + y[i], integer version. 24 threads per block.
.blocks 3
.threads 24
.param 0 0x1000
.param 1 0x1400
.param 2 -7
.random 0x1000 72
.random 0x1400 72
        s2r  r1, tid
        s2r  r2, ctaid
        s2r  r3, ntid
        mul  r2, r2, r3
        add  r1, r1, r2
        shli r1, r1, 2
        s2r  r4, param0
        add  r4, r4, r1
        ld   r5, 0(r4)           # x
        s2r  r4, param1
        add  r4, r4, r1
        ld   r6, 0(r4)           # y
        s2r  r7, param2          # alpha
        mul  r5, r5, r7
        add  r6, r6, r5
        st   r6, 0(r4)
        exit

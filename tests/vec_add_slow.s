# vec_add with slow memory (20 cycles) that sometimes refuses requests.
.blocks 4
.threads 32
.memlat 20
.backpressure
.equ N 128
.param 0 0x1000
.param 1 0x1400
.param 2 0x1800
.random 0x1000 N
.random 0x1400 N
        s2r  r1, tid
        s2r  r2, ctaid
        s2r  r3, ntid
        mul  r2, r2, r3
        add  r1, r1, r2          # i
        shli r1, r1, 2
        s2r  r4, param0
        add  r4, r4, r1
        ld   r5, 0(r4)
        s2r  r4, param1
        add  r4, r4, r1
        ld   r6, 0(r4)
        add  r7, r5, r6
        s2r  r4, param2
        add  r4, r4, r1
        st   r7, 0(r4)
        exit

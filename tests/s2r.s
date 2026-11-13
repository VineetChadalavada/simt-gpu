# Every thread stores its special registers. 20 threads per block, so the
# third warp has only 4 active lanes (a partial warp).
.blocks 3
.threads 20
.equ OUT 0x1000
.param 0 OUT
.param 1 0x12345678
        s2r  r1, tid
        s2r  r2, ctaid
        s2r  r3, ntid
        mul  r4, r2, r3          # ctaid * ntid
        add  r4, r4, r1          # global thread id
        shli r4, r4, 5           # 8 words per thread
        s2r  r5, param0
        add  r4, r4, r5
        st   r1, 0(r4)
        st   r2, 4(r4)
        st   r3, 8(r4)
        s2r  r6, nctaid
        st   r6, 12(r4)
        s2r  r6, laneid
        st   r6, 16(r4)
        s2r  r6, warpid
        st   r6, 20(r4)
        s2r  r6, param1
        st   r6, 24(r4)
        exit

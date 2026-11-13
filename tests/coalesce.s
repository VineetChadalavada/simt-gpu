# Coalescing: the same kernel reads memory with 6 different lane patterns.
# The testbench checks the transaction count against the golden model.
# Transactions per warp for each load:
#   a) unit stride                        1
#   b) unit stride, one word late         2  (the warp crosses a line)
#   c) stride 2 words                     2
#   d) stride 8 words                     8  (one line per lane)
#   e) all lanes read one word            1
#   f) lanes reversed inside the line     1
# g) All lanes of a warp store to one word. The highest lane must win.
.blocks 1
.threads 32
.equ IN 0x1000
.equ OUT 0x2000
.param 0 IN
.param 1 OUT
.random IN 512
        s2r  r1, tid
        shli r2, r1, 2           # tid * 4
        s2r  r3, param0
        s2r  r4, param1
        add  r5, r4, r2          # &out[tid]
        add  r6, r3, r2
        ld   r7, 0(r6)           # a)
        st   r7, 0(r5)
        ld   r7, 4(r6)           # b)
        st   r7, 128(r5)
        shli r6, r1, 3
        add  r6, r6, r3
        ld   r7, 0(r6)           # c)
        st   r7, 256(r5)
        shli r6, r1, 5
        add  r6, r6, r3
        ld   r7, 0(r6)           # d)
        st   r7, 384(r5)
        ld   r7, 0(r3)           # e)
        st   r7, 512(r5)
        s2r  r8, laneid
        li   r9, 7
        sub  r9, r9, r8
        shli r9, r9, 2           # (7 - lane) * 4
        s2r  r10, warpid
        shli r10, r10, 5
        add  r6, r3, r10
        add  r6, r6, r9
        ld   r7, 0(r6)           # f)
        st   r7, 640(r5)
        s2r  r10, warpid
        shli r10, r10, 2
        add  r6, r4, r10
        st   r1, 1024(r6)        # g) out[256 + warpid] = highest tid of the warp
        exit

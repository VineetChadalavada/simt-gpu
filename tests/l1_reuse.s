# L1 reuse and write-through.
# 1. All warps read the same 8-word table 4 times: after the first miss,
#    the reads hit.
# 2. Each warp does load / store / load on its own line. The store goes to
#    memory and must also update the cached line, else the second load
#    reads old data.
# 3. Only the odd lanes store (a partial word mask), then all lanes read
#    the line again.
# A second launch then works on the same lines that the first launch
# changed. (Two blocks of one launch must not share data that one of them
# writes: they run in parallel on the 2 cores.)
.equ T 0x1000
.equ BUF 0x1400
.equ OUT 0x2000
.launch 0 1 32 T BUF OUT
.launch 0 1 32 T BUF OUT+128
.random T 8
.random BUF 32
        s2r  r1, tid
        s2r  r2, laneid
        shli r3, r2, 2           # lane * 4
        s2r  r4, param0
        add  r4, r4, r3          # &T[lane]
        li   r5, 0
        li   r6, 4
loop:   ld   r7, 0(r4)
        add  r5, r5, r7
        addi r6, r6, -1
        brnz r6, loop
        s2r  r8, warpid
        shli r8, r8, 5
        s2r  r9, param1
        add  r9, r9, r8
        add  r9, r9, r3          # &BUF[warpid * 8 + lane]
        ld   r10, 0(r9)
        addi r10, r10, 1
        st   r10, 0(r9)
        ld   r11, 0(r9)          # must see the new value
        add  r11, r11, r5
        andi r12, r2, 1
        brz  r12, skip, skip     # odd lanes only
        st   r11, 0(r9)
skip:   ld   r13, 0(r9)
        xor  r13, r13, r11
        s2r  r14, ctaid
        shli r14, r14, 5
        add  r14, r14, r1
        shli r14, r14, 2
        s2r  r15, param2
        add  r15, r15, r14
        st   r13, 0(r15)         # out[gid]
        exit

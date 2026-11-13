# Bank conflicts. Shared memory has 8 banks; bank = word % 8.
# Each thread first writes 8 shared words (all 256 words, no conflicts).
# Then each load uses a different lane pattern. Extra cycles per warp:
#   a) stride 1 word                0
#   b) stride 2 words               1  (2 lanes on each even bank)
#   c) stride 8 words               7  (all 8 lanes on one bank)
#   d) stride 9 words               0  (9 = 1 mod 8: 8 different banks)
#   e) all lanes read one word      0  (broadcast)
#   f) 2 words in one bank          1
# g) All lanes of a warp store to one word: no conflict, the highest lane
#    wins. The warp then reads the word back.
# The testbench checks the total against the golden model.
.blocks 1
.threads 32
.equ IN 0x1000
.equ OUT 0x2000
.param 0 IN
.param 1 OUT
.random IN 256
        s2r  r1, tid
        shli r2, r1, 2           # tid * 4
        s2r  r3, param0
        add  r3, r3, r2
        li   r4, 8
        mov  r5, r2
fill:   ld   r6, 0(r3)
        sts  r6, 0(r5)           # S[tid + 32k] = in[tid + 32k]
        addi r3, r3, 128
        addi r5, r5, 128
        addi r4, r4, -1
        brnz r4, fill
        bar
        s2r  r7, param1
        add  r7, r7, r2          # &out[tid]
        lds  r8, 0(r2)           # a)
        st   r8, 0(r7)
        shli r9, r1, 3
        lds  r8, 0(r9)           # b)
        st   r8, 128(r7)
        shli r9, r1, 5
        lds  r8, 0(r9)           # c)
        st   r8, 256(r7)
        muli r9, r1, 36
        andi r9, r9, 1020
        lds  r8, 0(r9)           # d)
        st   r8, 384(r7)
        lds  r8, 20(r0)          # e)
        st   r8, 512(r7)
        andi r9, r1, 1
        shli r9, r9, 5
        lds  r8, 0(r9)           # f) word 0 or word 8
        st   r8, 640(r7)
        s2r  r10, warpid
        shli r10, r10, 4
        sts  r1, 260(r10)        # g) S[65 + 4*warpid] = highest tid of the warp
        lds  r8, 260(r10)        #    (no other step reads these words)
        st   r8, 768(r7)
        exit

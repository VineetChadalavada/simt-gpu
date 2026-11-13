# Transpose 8x8 tiles through shared memory (one tile per block).
# Thread (row, col) writes S[row][col] and S[row+4][col], then reads
# S[col][row] and S[col][row+4].
# With STRIDE = 8 words per shared row, the read S[col][row] puts all 8
# lanes of a warp on the same bank: 7 extra cycles per lds.
# transpose_pad.s is the same kernel with STRIDE = 9 (one pad word per row):
# then the 8 lanes use 8 different banks, and there are no conflicts.
.blocks 2
.threads 32
.equ STRIDE 8
.equ IN 0x1000
.equ OUT 0x1400
.param 0 IN
.param 1 OUT
.random IN 128
        s2r  r1, tid
        s2r  r2, ctaid
        shri r3, r1, 3           # row 0..3
        andi r4, r1, 7           # col
        shli r5, r2, 8           # tile offset: ctaid * 256 bytes
        shli r6, r1, 2
        add  r5, r5, r6          # + (row * 8 + col) * 4
        s2r  r6, param0
        add  r6, r6, r5
        ld   r7, 0(r6)           # in[row][col]
        ld   r8, 128(r6)         # in[row+4][col]
        muli r9, r3, STRIDE*4
        shli r10, r4, 2
        add  r9, r9, r10         # &S[row][col]
        sts  r7, 0(r9)
        sts  r8, STRIDE*16(r9)   # &S[row+4][col]
        bar
        muli r9, r4, STRIDE*4
        shli r10, r3, 2
        add  r9, r9, r10         # &S[col][row]
        lds  r7, 0(r9)
        lds  r8, 16(r9)          # S[col][row+4]
        s2r  r6, param1
        add  r6, r6, r5
        st   r7, 0(r6)           # out[row][col]
        st   r8, 128(r6)         # out[row+4][col]
        exit

# Three lines in the same L1 set (1 KB apart: set = address bits [9:5]).
# The set has 2 ways. One warp, so the access order is fixed.
#   1. A B C A B C ...   each access misses (LRU evicts the next line needed)
#   2. A B A B ...       2 misses, then hits
#   3. A C A C ...       A hits, so B is now the LRU line; C replaces B and
#                        then A and C hit. If a hit did not update LRU, C
#                        would replace A, and A would miss again.
# The lines hold different data, so a wrong tag check or a fill into the
# wrong way gives a wrong sum. Expected: 13 hits, 15 misses. The testbench
# checks these counts, so a replacement bug that only costs time also fails.
.expect_l1 13 15
.blocks 1
.threads 8
.equ A 0x1000
.equ B 0x1400
.equ C 0x1800
.equ OUT 0x2000
.random A 8
.random B 8
.random C 8
        s2r  r1, laneid
        shli r1, r1, 2
        li   r2, A
        add  r2, r2, r1
        li   r5, 0
        li   r6, 4
abc:    ld   r7, 0(r2)
        ld   r8, 1024(r2)
        ld   r9, 2048(r2)
        add  r5, r5, r7
        xor  r5, r5, r8
        sub  r5, r5, r9
        addi r6, r6, -1
        brnz r6, abc
        li   r6, 4
ab:     ld   r7, 0(r2)
        ld   r8, 1024(r2)
        add  r5, r5, r7
        xor  r5, r5, r8
        addi r6, r6, -1
        brnz r6, ab
        li   r6, 4
ac:     ld   r7, 0(r2)
        ld   r9, 2048(r2)
        add  r5, r5, r7
        sub  r5, r5, r9
        addi r6, r6, -1
        brnz r6, ac
        li   r3, OUT
        add  r3, r3, r1
        st   r5, 0(r3)
        exit

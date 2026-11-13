# C = A * B for 8x8 integer matrices, with shared memory.
# The same result as matmul.s. Each block computes 4 rows of C. First the
# block copies its 4 rows of A and all of B into shared memory (coalesced,
# 3 loads per thread), then the inner loop reads only shared memory:
#   As[row][k]: the same word for all lanes of a warp (broadcast)
#   Bs[k][col]: 8 consecutive words, 8 different banks
# So the inner loop has no bank conflicts and no global loads.
.blocks 2
.threads 32
.equ A 0x1000
.equ B 0x1100
.equ C 0x1200
.param 0 A
.param 1 B
.param 2 C
.random A 64
.random B 64
        s2r  r1, tid
        s2r  r2, ctaid
        shli r3, r2, 5
        add  r3, r3, r1          # gid = row * 8 + col
        shli r4, r3, 2           # gid * 4
        shli r5, r1, 2           # tid * 4
        s2r  r6, param0
        add  r6, r6, r4
        ld   r7, 0(r6)
        sts  r7, 0(r5)           # As[tid] = A[gid]
        s2r  r6, param1
        add  r6, r6, r5
        ld   r7, 0(r6)
        sts  r7, 128(r5)         # Bs[tid] = B[tid]
        ld   r7, 128(r6)
        sts  r7, 256(r5)         # Bs[tid + 32] = B[tid + 32]
        bar
        shri r8, r1, 3
        shli r8, r8, 5           # &As[local row][0]
        andi r9, r1, 7
        shli r9, r9, 2
        addi r9, r9, 128         # &Bs[0][col]
        li   r10, 0              # acc
        li   r11, 8              # k counter
kloop:  lds  r12, 0(r8)
        lds  r13, 0(r9)
        mul  r12, r12, r13
        add  r10, r10, r12
        addi r8, r8, 4
        addi r9, r9, 32
        addi r11, r11, -1
        brnz r11, kloop
        s2r  r6, param2
        add  r6, r6, r4
        st   r10, 0(r6)
        exit

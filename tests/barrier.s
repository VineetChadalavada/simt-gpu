# Warps talk through memory across a barrier. Each thread writes one word,
# waits at bar, then reads a word that a different warp wrote.
# A delay loop makes warp 0 the slowest writer, and warp 3 reads warp 0's
# words. Without the barrier, warp 3 reads them before warp 0 writes them.
.blocks 2
.threads 32
.param 0 0x1000
.param 1 0x2000
        s2r  r12, warpid
        li   r13, 3
        sub  r13, r13, r12
        muli r13, r13, 12        # (3 - warpid) * 12 iterations
        addi r13, r13, 1
delay:  addi r13, r13, -1
        brnz r13, delay          # uniform inside a warp: no divergence
        s2r  r1, tid
        s2r  r2, ctaid
        shli r3, r2, 5           # ctaid * 32
        s2r  r4, param0
        shli r5, r3, 2
        add  r4, r4, r5          # &buf[ctaid * 32]
        muli r6, r1, 3
        add  r6, r6, r2
        shli r7, r1, 2
        add  r7, r7, r4
        st   r6, 0(r7)           # buf[tid] = tid * 3 + ctaid
        bar
        addi r8, r1, 8
        andi r8, r8, 31          # (tid + 8) % 32: a thread in the next warp
        shli r8, r8, 2
        add  r8, r8, r4
        ld   r9, 0(r8)
        add  r10, r3, r1         # gid
        shli r10, r10, 2
        s2r  r11, param1
        add  r11, r11, r10
        st   r9, 0(r11)
        exit

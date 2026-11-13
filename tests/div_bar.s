# Divergent code before a barrier. A divergent delay loop (longest in warp 0)
# and an if/else both reconverge before bar. After bar, each thread reads
# a word that a thread in the next warp wrote.
.blocks 2
.threads 32
.param 0 0x1000
.param 1 0x2000
        s2r  r1, tid
        s2r  r2, ctaid
        s2r  r12, warpid
        s2r  r13, laneid
        li   r14, 4
        sub  r14, r14, r12       # 4 - warpid
        addi r13, r13, 1
        mul  r13, r13, r14       # (lane + 1) * (4 - warpid) trips
delay:  addi r13, r13, -1
        brnz r13, delay
        muli r6, r1, 3
        andi r7, r1, 1
        brz  r7, ev, j
        addi r6, r6, 100
        jmp  j
ev:     addi r6, r6, 200
j:      add  r6, r6, r2
        shli r3, r2, 5           # ctaid * 32
        s2r  r4, param0
        shli r5, r3, 2
        add  r4, r4, r5          # &buf[ctaid * 32]
        shli r7, r1, 2
        add  r7, r7, r4
        st   r6, 0(r7)
        bar
        addi r8, r1, 8
        andi r8, r8, 31
        shli r8, r8, 2
        add  r8, r8, r4
        ld   r9, 0(r8)
        add  r10, r3, r1
        shli r10, r10, 2
        s2r  r11, param1
        add  r11, r11, r10
        st   r9, 0(r11)
        exit

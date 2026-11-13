# A divergent loop inside an if, with a divergent if inside the loop.
# Lanes 1..7 run the loop (lane = trip count); lane 0 waits in the stack.
# With the two stack rules, the stack needs 5 entries. Without them, every
# divergent loop exit adds an entry, and the stack overflows.
.blocks 2
.threads 32
.param 1 0x2000
        s2r  r1, laneid
        s2r  r2, tid
        li   r5, 0
        seqi r7, r1, 0
        brz  r7, loopy, join     # lanes 1..7 go first, lane 0 waits
        addi r5, r5, 1000        # lane 0
        jmp  join
loopy:  mov  r10, r1             # trips = lane
lp:     addi r5, r5, 3
        andi r9, r10, 1
        brz  r9, ev, lj
        addi r5, r5, 7
        jmp  lj
ev:     shli r5, r5, 1
lj:     addi r10, r10, -1
        brnz r10, lp
        jmp  join
join:   add  r5, r5, r2
        s2r  r3, ctaid
        shli r3, r3, 5
        add  r3, r3, r2
        shli r3, r3, 2
        s2r  r8, param1
        add  r8, r8, r3
        st   r5, 0(r8)
        exit

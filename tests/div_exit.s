# exit in divergent code. Some lanes exit at the top, some exit inside a
# nested if, and warp 2 exits completely. The other lanes must continue
# with the correct mask, and the exited lanes must never come back.
.blocks 2
.threads 27
.param 1 0x2000
        s2r  r1, tid
        s2r  r2, ctaid
        muli r3, r2, 27
        add  r3, r3, r1          # gid
        s2r  r9, warpid
        seqi r9, r9, 2
        brz  r9, live, live      # uniform in each warp: warp 2 falls through
        exit                     # all of warp 2
live:   muli r5, r1, 3
        andi r7, r1, 3
        brnz r7, cont, cont
        exit                     # tid % 4 == 0
cont:   andi r7, r1, 2
        brz  r7, b_else, b_join
        andi r8, r1, 4
        brz  r8, keep, keep
        exit                     # bits 2:1 = 11
keep:   addi r5, r5, 100
        jmp  b_join
b_else: addi r5, r5, 7
b_join: s2r  r8, param1
        shli r4, r3, 2
        add  r8, r8, r4
        st   r5, 0(r8)
        exit

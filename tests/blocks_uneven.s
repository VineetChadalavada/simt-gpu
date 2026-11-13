# Many blocks with uneven work: block b runs a loop of 4 + 12 * (b % 4)
# trips. The dispatcher gives the next block to the first free core, so the
# core with short blocks takes more blocks. The result must not depend on
# which core ran a block.
.blocks 24
.threads 16
.equ OUT 0x3000
.param 0 OUT
        s2r  r1, ctaid
        andi r2, r1, 3
        muli r2, r2, 12
        addi r2, r2, 4           # trips
        s2r  r3, tid
        add  r4, r3, r1          # acc = tid + ctaid
loop:   muli r4, r4, 3
        xori r4, r4, 0x55
        addi r2, r2, -1
        brnz r2, loop
        s2r  r5, ntid
        mul  r5, r5, r1
        add  r5, r5, r3          # gid
        shli r5, r5, 2
        s2r  r6, param0
        add  r6, r6, r5
        st   r4, 0(r6)
        exit

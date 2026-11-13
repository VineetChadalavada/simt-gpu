# if/else on the low bit of tid. The odd path loads into r5; the even path
# computes r5 from its old value. If the LSU wrote load data into inactive
# lanes too, the even lanes would see the wrong r5.
.blocks 2
.threads 32
.param 0 0x1000
.param 1 0x2000
.random 0x1000 64
        s2r  r1, tid
        s2r  r2, ctaid
        shli r3, r2, 5
        add  r3, r3, r1          # gid
        shli r4, r3, 2
        s2r  r6, param0
        add  r6, r6, r4          # &in[gid]
        muli r5, r1, 7           # all lanes
        andi r7, r1, 1
        brz  r7, even, join      # even lanes jump
        ld   r5, 0(r6)           # odd lanes
        addi r5, r5, 1
        jmp  join
even:   muli r5, r5, 3
        addi r5, r5, -2
join:   s2r  r8, param1
        add  r8, r8, r4
        st   r5, 0(r8)
        exit

# if without else: the branch target is the rpc. The core must not push an
# entry for the taken path, because that path starts at the rpc.
.blocks 1
.threads 32
.param 1 0x2000
        s2r  r1, tid
        muli r5, r1, 5
        andi r7, r1, 3
        brnz r7, skip, skip      # tid % 4 != 0 skips the add
        addi r5, r5, 1000
skip:   s2r  r8, param1
        shli r4, r1, 2
        add  r8, r8, r4
        st   r5, 0(r8)
        exit

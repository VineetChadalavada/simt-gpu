# Three levels of nested if/else on the tid bits. 27 threads: the last warp
# is partial, so lanes are inactive from the start and after divergence.
.blocks 2
.threads 27
.param 1 0x2000
        s2r  r1, tid
        s2r  r2, ctaid
        muli r3, r2, 27
        add  r3, r3, r1          # gid
        li   r5, 0
        andi r7, r1, 1
        brz  r7, a_else, a_join
        addi r5, r5, 1           # bit 0 = 1
        andi r7, r1, 2
        brz  r7, b_else, b_join
        addi r5, r5, 10          # bits 1:0 = 11
        andi r7, r1, 4
        brnz r7, c_join, c_join
        addi r5, r5, 100         # bits 2:0 = 011
c_join: jmp  b_join
b_else: addi r5, r5, 20          # bits 1:0 = 01
b_join: addi r5, r5, 1000
        jmp  a_join
a_else: andi r7, r1, 4           # bit 0 = 0
        brz  r7, d_else, d_join
        addi r5, r5, 300
        jmp  d_join
d_else: addi r5, r5, 400
d_join: mul  r5, r5, r1
a_join: s2r  r8, param1
        shli r4, r3, 2
        add  r8, r8, r4
        st   r5, 0(r8)
        exit

# A switch statement: a chain of 7 branches that all reconverge at J.
# Each branch replaces the top stack entry, because the top entry already
# ends at J. The stack peaks at 8 entries (the limit). Without the replace
# rule, it would need 14 and the core would stop with a stack overflow.
.blocks 2
.threads 32
.param 1 0x2000
        s2r  r1, laneid
        s2r  r2, tid
        li   r5, 0
        seqi r7, r1, 0
        brz  r7, c1, J
        addi r5, r5, 10          # lane 0
        jmp  J
c1:     seqi r7, r1, 1
        brz  r7, c2, J
        addi r5, r5, 20
        jmp  J
c2:     seqi r7, r1, 2
        brz  r7, c3, J
        addi r5, r5, 30
        jmp  J
c3:     seqi r7, r1, 3
        brz  r7, c4, J
        addi r5, r5, 40
        jmp  J
c4:     seqi r7, r1, 4
        brz  r7, c5, J
        addi r5, r5, 50
        jmp  J
c5:     seqi r7, r1, 5
        brz  r7, c6, J
        addi r5, r5, 60
        jmp  J
c6:     seqi r7, r1, 6
        brz  r7, c7, J
        addi r5, r5, 70
        jmp  J
c7:     addi r5, r5, 80          # lane 7
J:      add  r5, r5, r2
        s2r  r3, ctaid
        shli r3, r3, 5
        add  r3, r3, r2
        shli r3, r3, 2
        s2r  r8, param1
        add  r8, r8, r3
        st   r5, 0(r8)
        exit

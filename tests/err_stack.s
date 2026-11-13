# Negative test: 5 levels of nested divergence need 10 stack entries, and
# the stack has 8. The core must stop with error code 2.
# At each level, one lane takes the short path and the others go deeper.
.blocks 1
.threads 8
.expect_err 2
        s2r  r1, laneid
        seqi r7, r1, 0
        brz  r7, t1, j1
        jmp  j1
t1:     seqi r7, r1, 1
        brz  r7, t2, j2
        jmp  j2
t2:     seqi r7, r1, 2
        brz  r7, t3, j3
        jmp  j3
t3:     seqi r7, r1, 3
        brz  r7, t4, j4
        jmp  j4
t4:     seqi r7, r1, 4
        brz  r7, t5, j5          # overflow here
        jmp  j5
t5:     nop
j5:     nop
j4:     nop
j3:     nop
j2:     nop
j1:     exit

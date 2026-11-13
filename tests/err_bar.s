# Negative test: bar inside divergent code. The core must stop with error
# code 4, not wait forever for lanes that can never arrive.
.blocks 1
.threads 8
.expect_err 4
        s2r  r1, laneid
        andi r7, r1, 1
        brz  r7, e, j
        bar                      # odd lanes only
        jmp  j
e:      nop
j:      exit

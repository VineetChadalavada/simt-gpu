# Collatz steps for n = gid + 1: a while loop with a divergent exit and a
# divergent if/else inside. Lanes leave the loop at very different times
# (n = 27 needs 111 steps), so SIMD efficiency is low: a classic GPU case.
.blocks 2
.threads 32
.param 1 0x2000
        s2r  r1, tid
        s2r  r2, ctaid
        shli r3, r2, 5
        add  r3, r3, r1          # gid
        addi r4, r3, 1           # n
        li   r5, 0               # steps
top:    seqi r7, r4, 1
        brnz r7, done, done      # lanes with n == 1 leave the loop
        andi r8, r4, 1
        brz  r8, even, step
        muli r4, r4, 3           # odd: n = 3n + 1
        addi r4, r4, 1
        jmp  step
even:   shri r4, r4, 1           # even: n = n / 2
step:   addi r5, r5, 1
        jmp  top
done:   s2r  r8, param1
        shli r3, r3, 2
        add  r8, r8, r3
        st   r5, 0(r8)
        exit

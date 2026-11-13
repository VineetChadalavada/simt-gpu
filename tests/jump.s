# jmp forward and back, nop, and branches that all lanes agree on.
.blocks 1
.threads 16
.param 0 0x1000
        s2r  r1, tid
        shli r1, r1, 2
        s2r  r2, param0
        add  r2, r2, r1
        li   r3, 1
        jmp  fwd
        li   r3, 99              # skipped
back:   addi r3, r3, 100
        jmp  done
fwd:    nop
        addi r3, r3, 10
        brz  r0, back, done      # r0 is 0 in all lanes: always taken
        li   r3, 99              # skipped
done:   brnz r0, back, out       # never taken
out:    st   r3, 0(r2)           # 111
        exit

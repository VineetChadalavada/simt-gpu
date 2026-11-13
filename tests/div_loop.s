# A divergent loop: each lane runs (lane + ctaid + 1) iterations.
# out[gid] = sum over k < trips of in[k] * k
.blocks 3
.threads 32
.param 0 0x1000
.param 1 0x2000
.random 0x1000 16
        s2r  r1, tid
        s2r  r2, ctaid
        shli r3, r2, 5
        add  r3, r3, r1          # gid
        andi r10, r1, 7
        add  r10, r10, r2
        addi r10, r10, 1         # trips
        li   r4, 0               # sum
        li   r11, 0              # k
        s2r  r6, param0
loop:   ld   r8, 0(r6)
        mul  r8, r8, r11
        add  r4, r4, r8
        addi r6, r6, 4
        addi r11, r11, 1
        addi r10, r10, -1
        brnz r10, loop           # rpc = the next instruction
        s2r  r8, param1
        shli r3, r3, 2
        add  r8, r8, r3
        st   r4, 0(r8)
        exit

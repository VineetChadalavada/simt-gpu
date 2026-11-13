# Write-port reservation. An FP result writes port 0 three cycles after
# its EX cycle; an ALU result writes in its EX cycle. 4 warps run a loop of
# ffma/fadd mixed with independent ALU instructions, so an ALU instruction
# of one warp often wants port 0 in the cycle that an FP result of another
# warp writes it. The issue stage must hold the ALU instruction for one
# cycle (stall_wb > 0); if it does not, one of the two writes is lost.
# (One warp alone issues at most every 2 cycles and does not hit the case.)
.blocks 1
.threads 32
.equ OUT 0x2000
.param 0 OUT
        s2r  r1, tid
        shli r2, r1, 2
        s2r  r3, param0
        add  r3, r3, r2          # &out[tid]
        li   r4, f(1.5)
        li   r5, f(-0.75)
        li   r6, f(3.0)
        li   r10, 0
        li   r11, 0
        li   r12, 0
        li   r13, 6
loop:   ffma r6, r4, r5, r6      # r6 = 1.5 * -0.75 + r6
        addi r10, r10, 1
        addi r11, r11, 3
        add  r12, r12, r1
        fadd r4, r4, r6
        xori r10, r10, 5
        add  r11, r11, r10
        addi r13, r13, -1
        brnz r13, loop
        add  r7, r10, r11
        add  r7, r7, r12
        st   r6, 0(r3)
        st   r4, 128(r3)
        st   r7, 256(r3)
        exit

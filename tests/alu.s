# All 15 register-register ALU operations, and the immediate forms, on
# random inputs. Each thread writes 28 result words.
.blocks 2
.threads 32
.equ A   0x1000
.equ B   0x1200
.equ OUT 0x2000
.param 0 A
.param 1 B
.param 2 OUT
.random A 64
.random B 64
        s2r  r1, tid
        s2r  r2, ctaid
        shli r2, r2, 5
        add  r1, r1, r2          # gid
        shli r2, r1, 2
        s2r  r3, param0
        add  r3, r3, r2
        ld   r4, 0(r3)           # a
        s2r  r3, param1
        add  r3, r3, r2
        ld   r5, 0(r3)           # b
        s2r  r3, param2
        shli r2, r1, 7           # 32 words per thread
        add  r3, r3, r2
        add  r6, r4, r5
        st   r6, 0(r3)
        sub  r6, r4, r5
        st   r6, 4(r3)
        mul  r6, r4, r5
        st   r6, 8(r3)
        and  r6, r4, r5
        st   r6, 12(r3)
        or   r6, r4, r5
        st   r6, 16(r3)
        xor  r6, r4, r5
        st   r6, 20(r3)
        shl  r6, r4, r5
        st   r6, 24(r3)
        shr  r6, r4, r5
        st   r6, 28(r3)
        sra  r6, r4, r5
        st   r6, 32(r3)
        slt  r6, r4, r5
        st   r6, 36(r3)
        sltu r6, r4, r5
        st   r6, 40(r3)
        min  r6, r4, r5
        st   r6, 44(r3)
        max  r6, r4, r5
        st   r6, 48(r3)
        seq  r6, r4, r5
        st   r6, 52(r3)
        sne  r6, r4, r5
        st   r6, 56(r3)
        seq  r6, r4, r4
        st   r6, 60(r3)
        addi r6, r4, -12345
        st   r6, 64(r3)
        muli r6, r4, 77
        st   r6, 68(r3)
        andi r6, r4, 0xFFF
        st   r6, 72(r3)
        xori r6, r4, -1
        st   r6, 76(r3)
        srai r6, r4, 31
        st   r6, 80(r3)
        shri r6, r4, 31
        st   r6, 84(r3)
        slti r6, r4, -5
        st   r6, 88(r3)
        sltui r6, r4, 100
        st   r6, 92(r3)
        lui  r6, 0x2ABCD
        st   r6, 96(r3)
        li   r6, 0xDEADBEEF
        st   r6, 100(r3)
        mov  r7, r6
        st   r7, 104(r3)
        add  r0, r4, r5          # writes to r0 are dropped
        st   r0, 108(r3)
        exit

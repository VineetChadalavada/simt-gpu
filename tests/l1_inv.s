# The L1 rule for 2 cores: write-through, and invalidate at kernel start.
# Three launches of two kernels (two entry PCs in one program):
#   1. sum   2 blocks. Each block reads all of X (8 lines), so both cores
#            have all of X in their L1.
#   2. inc   2 blocks. Block b adds 1 to its half of X. The two blocks run
#            on different cores, so each core updates only its own half;
#            its L1 still holds the old copy of the other half.
#   3. sum   again. Without the invalidate at kernel start, each core reads
#            old data for one half of X from its L1, and the sums are wrong.
.equ X 0x1000
.equ OUT1 0x2000
.equ OUT3 0x2100
.random X 64
.launch sum 2 32 X OUT1
.launch inc 2 32 X
.launch sum 2 32 X OUT3

sum:    s2r  r1, tid
        shli r1, r1, 2
        s2r  r2, param0
        add  r2, r2, r1          # &X[tid]
        ld   r3, 0(r2)
        ld   r4, 128(r2)         # X[tid + 32]
        add  r3, r3, r4
        s2r  r5, ctaid
        shli r5, r5, 7
        add  r5, r5, r1
        s2r  r6, param1
        add  r6, r6, r5
        st   r3, 0(r6)           # out[ctaid * 32 + tid]
        exit

inc:    s2r  r1, tid
        s2r  r2, ctaid
        shli r2, r2, 5
        add  r1, r1, r2
        shli r1, r1, 2
        s2r  r2, param0
        add  r2, r2, r1          # &X[ctaid * 32 + tid]
        ld   r3, 0(r2)
        addi r3, r3, 1
        st   r3, 0(r2)
        exit

# y[i] = a * x[i] + y[i] in FP32, with one ffma per element.
# 4 blocks x 32 threads.
.blocks 4
.threads 32
.equ X 0x1000
.equ Y 0x1400
.param 0 X
.param 1 Y
.param 2 f(-1.75)
.randf X 128 -100.0 100.0
.randf Y 128 -100.0 100.0
        s2r  r1, tid
        s2r  r2, ctaid
        shli r2, r2, 5
        add  r1, r1, r2
        shli r1, r1, 2           # i * 4
        s2r  r2, param0
        add  r2, r2, r1
        ld   r3, 0(r2)           # x[i]
        s2r  r4, param1
        add  r4, r4, r1
        ld   r5, 0(r4)           # y[i]
        s2r  r6, param2          # a
        ffma r5, r6, r3, r5
        st   r5, 0(r4)
        exit

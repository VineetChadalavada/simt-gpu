# Negative test: a shared-memory address past 1 KB. Lanes 0..5 use words
# 250..255 (valid), lanes 6 and 7 use 1024 and 1028. The core must stop
# with error code 5 and must not wrap the address.
.expect_err 5
.threads 8
        s2r  r1, tid
        shli r1, r1, 2
        addi r1, r1, 1000
        lds  r2, 0(r1)
        exit

// Opcodes and special-register numbers. Python copy: tools/isa.py.
`ifndef ISA_DEFS_VH
`define ISA_DEFS_VH

`define OP_NOP   6'h00
`define OP_LUI   6'h10
`define OP_LD    6'h20
`define OP_ST    6'h21
`define OP_LDS   6'h22   // shared memory
`define OP_STS   6'h23
`define OP_S2R   6'h24
`define OP_FADD  6'h28   // FP32: op[5:2] = 4'b1010, op[1:0] = fadd/fsub/fmul/ffma
`define OP_FSUB  6'h29
`define OP_FMUL  6'h2A
`define OP_FFMA  6'h2B   // rd = rs1 * rs2 + rs3, rs3 in [13:10]
`define OP_JMP   6'h30
`define OP_BRZ   6'h31
`define OP_BRNZ  6'h32
`define OP_BAR   6'h33
`define OP_EXIT  6'h3F

`define SR_TID     4'd0
`define SR_CTAID   4'd1
`define SR_NTID    4'd2
`define SR_NCTAID  4'd3
`define SR_LANEID  4'd4
`define SR_WARPID  4'd5
`define SR_COREID  4'd6
// 8..11 = param0..param3

// Error codes (sm_core err_code)
`define ERR_ILLEGAL    4'd1
`define ERR_STACK      4'd2   // reconvergence stack overflow
`define ERR_MISALIGNED 4'd3
`define ERR_BAR_DIV    4'd4   // bar inside divergent code
`define ERR_SMEM_RANGE 4'd5   // shared-memory address out of range

`endif

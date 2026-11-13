`timescale 1ns/1ps
`include "isa_defs.vh"

// Instruction decoder. Pure combinational logic.
// ra and rb are the two source registers that the issue stage reads, after
// the format mux: a branch tests rd-field [25:22], a store sends rd-field data.
module decode (
    input  wire [31:0] instr,
    output wire        is_alu,     // ALU ops 0x01..0x1F, includes LUI
    output wire [3:0]  alu_op,
    output wire        alu_imm,    // operand b is the immediate
    output wire        is_ld,
    output wire        is_st,
    output wire        is_s2r,
    output wire        is_jmp,
    output wire        is_br,      // brz or brnz
    output wire        br_nz,      // 1 = brnz
    output wire        is_bar,
    output wire        is_exit,
    output wire        is_ctrl,    // changes the warp's control flow
    output wire        is_mem,
    output wire        is_shared,  // lds or sts
    output wire        is_fp,      // fadd, fsub, fmul, ffma
    output wire [1:0]  fp_op,      // 0 fadd, 1 fsub, 2 fmul, 3 ffma
    output wire        illegal,
    output wire [3:0]  rd,
    output wire [3:0]  ra,
    output wire [3:0]  rb,
    output wire [3:0]  rc,         // third source (ffma)
    output wire        use_ra,
    output wire        use_rb,
    output wire        use_rc,
    output wire        wr_rd,      // writes a register other than r0
    output wire [31:0] imm,
    output wire [10:0] target,
    output wire [10:0] rpc,
    output wire [3:0]  sreg
);
    wire [5:0] op = instr[31:26];
    wire is_nop = (op == `OP_NOP);
    wire is_lui = (op == `OP_LUI);

    assign is_alu  = (op[5] == 1'b0) && !is_nop;
    assign alu_op  = op[3:0];
    assign alu_imm = op[4];
    assign is_ld   = (op == `OP_LD) || (op == `OP_LDS);
    assign is_st   = (op == `OP_ST) || (op == `OP_STS);
    assign is_s2r  = (op == `OP_S2R);
    assign is_jmp  = (op == `OP_JMP);
    assign is_br   = (op == `OP_BRZ) || (op == `OP_BRNZ);
    assign br_nz   = (op == `OP_BRNZ);
    assign is_bar  = (op == `OP_BAR);
    assign is_exit = (op == `OP_EXIT);
    assign is_ctrl = is_jmp | is_br | is_bar | is_exit;
    assign is_mem  = is_ld | is_st;
    assign is_shared = is_mem && op[1];
    assign is_fp   = (op[5:2] == 4'b1010);
    assign fp_op   = op[1:0];
    assign illegal = !(is_nop | is_alu | is_mem | is_s2r | is_ctrl | is_fp);

    assign rd     = instr[25:22];
    assign ra     = is_br ? instr[25:22] : instr[21:18];
    assign rb     = is_st ? instr[25:22] : instr[17:14];
    assign rc     = instr[13:10];
    assign use_ra = (is_alu && !is_lui) | is_mem | is_br | is_fp;
    assign use_rb = (is_alu && !alu_imm) | is_st | is_fp;
    assign use_rc = is_fp && (fp_op == 2'd3);
    assign wr_rd  = (is_alu | is_ld | is_s2r | is_fp) && (rd != 4'd0);

    assign imm    = is_lui ? {instr[17:0], 14'b0} : {{14{instr[17]}}, instr[17:0]};
    assign target = instr[21:11];
    assign rpc    = instr[10:0];
    assign sreg   = instr[3:0];
endmodule

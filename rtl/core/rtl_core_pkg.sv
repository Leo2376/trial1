package rtl_core_pkg;

  localparam int XLEN = 64;

  typedef logic [6:0]  opcode_t;
  typedef logic [4:0]  regaddr_t;
  typedef logic [2:0]  funct3_t;
  typedef logic [6:0]  funct7_t;

  localparam opcode_t OP_LUI    = 7'b0110111;
  localparam opcode_t OP_AUIPC  = 7'b0010111;
  localparam opcode_t OP_JAL    = 7'b1101111;
  localparam opcode_t OP_JALR   = 7'b1100111;
  localparam opcode_t OP_BRANCH = 7'b1100011;
  localparam opcode_t OP_LOAD   = 7'b0000011;
  localparam opcode_t OP_STORE  = 7'b0100011;
  localparam opcode_t OP_OPIMM  = 7'b0010011;
  localparam opcode_t OP_OP     = 7'b0110011;
  localparam opcode_t OP_OPIMM32 = 7'b0011011;
  localparam opcode_t OP_OP32    = 7'b0111011;
  localparam opcode_t OP_SYSTEM  = 7'b1110011;
  localparam opcode_t OP_FENCE   = 7'b0001111;
  localparam opcode_t OP_AMO      = 7'b0101111;
  localparam opcode_t OP_FPLOAD  = 7'b0000111;
  localparam opcode_t OP_FPSTORE = 7'b0100111;
  localparam opcode_t OP_FPOP     = 7'b1010011;
  localparam opcode_t OP_FMADD    = 7'b1000011;

  typedef enum logic [4:0] {
    ALU_NONE = 0,
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
    ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR, ALU_AND,
    ALU_ADDW, ALU_SUBW, ALU_SLLW, ALU_SRLW, ALU_SRAW,
    ALU_LUI, ALU_COPYB, ALU_MUL, ALU_MULH, ALU_MULHSU, ALU_MULHU,
    ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU,
    ALU_DIVW, ALU_DIVUW, ALU_REMW, ALU_REMUW
  } alu_op_e;

  typedef enum logic [4:0] {
    FPU_NONE = 5'd0,
    FPU_FADD, FPU_FSUB, FPU_FMUL, FPU_FDIV, FPU_FSQRT,
    FPU_FMIN, FPU_FMAX, FPU_FSGNJ, FPU_FSGNJN, FPU_FSGNJX,
    FPU_FLE, FPU_FLT, FPU_FEQ,
    FPU_F2I, FPU_I2F, FPU_F2D, FPU_D2F, FPU_MV_X2F, FPU_MV_F2X, FPU_CLASS
  } fpu_op_e;

  typedef enum logic [3:0] {
    MUL_NONE=0, MUL_MUL, MUL_MULH, MUL_MULHSU, MUL_MULHU,
    MUL_DIV, MUL_DIVU, MUL_REM, MUL_REMU,
    MUL_DIVW, MUL_DIVUW, MUL_REMW, MUL_REMUW
  } mul_op_e;

  typedef enum logic [3:0] {
    LSU_NONE=0, LSU_LB, LSU_LH, LSU_LW, LSU_LD, LSU_LBU, LSU_LHU, LSU_LWU,
    LSU_SB, LSU_SH, LSU_SW, LSU_SD,
    LSU_LR, LSU_SC, LSU_AMO
  } lsu_op_e;

  typedef enum logic [2:0] { AMO_ADD=0, AMO_SWAP, AMO_XOR, AMO_AND, AMO_OR, AMO_MIN, AMO_MAX, AMO_MINU } amo_op_e;

  typedef enum logic [3:0] {
    SRC_NONE=0, SRC_REG, SRC_IMM_I, SRC_IMM_S, SRC_IMM_B, SRC_IMM_U, SRC_IMM_J, SRC_PC
  } asrc_e;

  typedef enum logic [1:0] { WB_NONE=0, WB_INT, WB_FP, WB_MEM } wb_sel_e;

  typedef enum logic [1:0] { PRIV_U=0, PRIV_S=1, PRIV_M=3 } priv_e;

  typedef enum logic [4:0] {
    CAUSE_MISALIGNED_FETCH=5'd0, CAUSE_FETCH_ACCESS=5'd1, CAUSE_ILLEGAL_INSN=5'd2,
    CAUSE_BREAKPOINT=5'd3, CAUSE_MISALIGNED_LOAD=5'd4, CAUSE_LOAD_ACCESS=5'd5,
    CAUSE_MISALIGNED_STORE=5'd6, CAUSE_STORE_ACCESS=5'd7, CAUSE_USER_ECALL=5'd8,
    CAUSE_SUP_ECALL=5'd9, CAUSE_M_ECALL=5'd11, CAUSE_FETCH_PAGE_FAULT=5'd12,
    CAUSE_LOAD_PAGE_FAULT=5'd13, CAUSE_STORE_PAGE_FAULT=5'd15
  } cause_e;

  localparam logic [4:0] CAUSE_MTIMER    = 5'd7;
  localparam logic [4:0] CAUSE_MSOFTWARE = 5'd3;

  typedef struct packed {
    logic        valid;
    opcode_t     opcode;
    funct3_t     funct3;
    funct7_t     funct7;
    regaddr_t    rs1;
    regaddr_t    rs2;
    regaddr_t    rd;
    logic [63:0] imm;
    alu_op_e     alu_op;
    fpu_op_e     fpu_op;
    mul_op_e     mul_op;
    lsu_op_e     lsu_op;
    amo_op_e     amo_op;
    asrc_e       a_src;
    logic        use_imm_b;
    wb_sel_e     wb_sel;
    logic        is_branch;
    logic        is_jal;
    logic        is_jalr;
    logic        is_fp;
    logic        reads_csr;
    logic        writes_csr;
    logic [11:0] csr_addr;
    logic [1:0]  csr_op;
    logic        fence_i;
    logic        is_ebreak;
    logic        is_ecall;
    logic        is_mret;
    logic        is_sret;
    logic        is_wfi;
    logic        illegal;
    logic [2:0]  fp_fmt;
    logic [2:0]  fp_rm;
  } ctrl_t;

  localparam logic [11:0] CSR_MSTATUS=12'h300, CSR_MISA=12'h301, CSR_MIE=12'h304,
    CSR_MTVEC=12'h305, CSR_MSCRATCH=12'h340, CSR_MEPC=12'h341, CSR_MCAUSE=12'h342,
    CSR_MTVAL=12'h343, CSR_MIP=12'h344, CSR_MCYCLE=12'hB00, CSR_CYCLE=12'hC00,
    CSR_MINSTRET=12'hB02, CSR_INSTRET=12'hC02, CSR_MTIME=12'hC01, CSR_MVENDORID=12'hF11,
    CSR_MARCHID=12'hF12, CSR_MIMPID=12'hF13, CSR_MHARTID=12'hF14,
    CSR_FCSR=12'h003, CSR_FFLAGS=12'h001, CSR_FRM=12'h002,
    CSR_SSTATUS=12'h100, CSR_SIE=12'h104, CSR_STVEC=12'h105, CSR_SSCRATCH=12'h140,
    CSR_SEPC=12'h141, CSR_SCAUSE=12'h142, CSR_STVAL=12'h143, CSR_SIP=12'h144,
    CSR_UTVEC=12'h005, CSR_USCRATCH=12'h040, CSR_UEPC=12'h041, CSR_UCAUSE=12'h042,
    CSR_UTVAL=12'h043;

endpackage

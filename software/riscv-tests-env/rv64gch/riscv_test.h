#ifndef _ENV_RV64GCH_H
#define _ENV_RV64GCH_H

#include "../encoding.h"

#define TOHOST_ADDR  0x100000000


#define RVTEST_RV64U          .macro init; .endm
#define RVTEST_RV64UF         .macro init; RVTEST_FP_ENABLE; .endm
#define RVTEST_RV32U          .macro init; .endm
#define RVTEST_RV32UF         .macro init; RVTEST_FP_ENABLE; .endm

#define RVTEST_FP_ENABLE      li t0, (1 << 13); csrs mstatus, t0
#define RVTEST_VECTOR_ENABLE
#define RVTEST_ENABLE_MACHINE
#define RVTEST_ENABLE_SUPERVISOR
#define RVTEST_ZVE32X_ENABLE

#define INIT_XREG             li x1, 0; li x2, 0; li x3, 0; li x4, 0; \
                              li x5, 0; li x6, 0; li x7, 0; li x8, 0; \
                              li x9, 0; li x10, 0; li x11, 0; li x12, 0; \
                              li x13, 0; li x14, 0; li x15, 0; li x16, 0; \
                              li x17, 0; li x18, 0; li x19, 0; li x20, 0; \
                              li x21, 0; li x22, 0; li x23, 0; li x24, 0; \
                              li x25, 0; li x26, 0; li x27, 0; li x28, 0; \
                              li x29, 0; li x30, 0; li x31, 0

#define RISCV_MULTICORE_DISABLE
#define INIT_RNMI
#define INIT_SATP
#define INIT_PMP
#define DELEGATE_NO_TRAPS
#define EXTRA_INIT
#define EXTRA_INIT_TIMER
#define INTERRUPT_HANDLER    j fail
#define CHECK_XLEN

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .globl _start;                                                  \
_start:                                                                 \
        j reset_vector;                                                 \
reset_vector:                                                           \
        INIT_XREG;                                                      \
        li TESTNUM, 0;                                                  \
        init;                                                           \
        j 1f;                                                           \
        .align 2;                                                       \
write_tohost:                                                           \
        li t5, TOHOST_ADDR;                                             \
        sw TESTNUM, 0(t5);                                              \
        sw zero, 4(t5);                                                \
        j write_tohost;                                                 \
        .align 2;                                                       \
1:

#define RVTEST_CODE_END    unimp

#define RVTEST_PASS                                                     \
        fence;                                                          \
        li TESTNUM, 1;                                                  \
        j write_tohost

#define TESTNUM gp

#define RVTEST_FAIL                                                     \
        fence;                                                          \
1:      beqz TESTNUM, 1b;                                               \
        sll TESTNUM, TESTNUM, 1;                                        \
        or  TESTNUM, TESTNUM, 1;                                        \
        j write_tohost

#define RVTEST_DATA_BEGIN                                               \
        .pushsection .tohost,"aw",@progbits;                           \
        .align 6; .global tohost; tohost: .dword 0; .size tohost, 8;    \
        .align 6; .global fromhost; fromhost: .dword 0; .size fromhost, 8;\
        .popsection;                                                    \
        .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif

#define TOHOST_ADDR    0x100000000
#define FROMHOST_ADDR  0x100000008
#define CHAROUT_ADDR   0x100000010

.section .text.init, "ax"
.global _start
_start:
    li   sp, 0x8000fffff8
    call main
    j    .

main:
    la   a0, msg
    call puts
    li   a0, 1
    call putchar
    li   a0, 10
    call putchar
    li   t0, 0
    li   t1, 0
    li   t2, 5
sum_loop:
    add  t0, t0, t2
    addi t2, t2, -1
    bnez t2, sum_loop
    li   a0, 1
    sd   a0, TOHOST_ADDR(t0)
    j    .

putchar:
    li   t0, CHAROUT_ADDR
    sd   a0, 0(t0)
    ret

puts:
    mv   t2, a0
puts_loop:
    lbu  a0, 0(t2)
    beqz a0, puts_done
    li   t0, CHAROUT_ADDR
    sd   a0, 0(t0)
    addi t2, t2, 1
    j    puts_loop
puts_done:
    ret

.section .data
msg:
    .asciz "RV64GCH hello from testbench"

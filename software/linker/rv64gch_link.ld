OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  DRAM (rwxa) : ORIGIN = 0x000080000000, LENGTH = 64K
}

SECTIONS
{
  .text 0x000080000000 : {
    KEEP(*(.text.init))
    *(.text .text.*)
  } > DRAM

  .data : {
    *(.data .data.*)
    . = ALIGN(8);
    *(.sdata .sdata.*)
  } > DRAM

  .rodata : {
    *(.rodata .rodata.*)
  } > DRAM

  .bss : {
    . = ALIGN(8);
    *(.sbss .sbss.*)
    *(.bss .bss.*)
  } > DRAM

  . = ALIGN(64);
  .tohost : {
    . = ALIGN(64);
    *(.tohost)
  } > DRAM

  _end = .;
}

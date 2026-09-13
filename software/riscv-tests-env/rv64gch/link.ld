OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  DRAM (rwxa) : ORIGIN = 0x80000000, LENGTH = 256M
}

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }

  . = ALIGN(0x1000);
  .tohost : {
    *(.tohost)
  } > DRAM

  . = ALIGN(0x1000);
  .text : { *(.text) }

  . = ALIGN(0x1000);
  .data : { *(.data) }
  .bss : { *(.bss) }
  _end = .;
}

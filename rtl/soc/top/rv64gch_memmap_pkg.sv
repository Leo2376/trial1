package rv64gch_memmap_pkg;

  localparam logic [47:0] DRAM_BASE   = 48'h0000_8000_0000;
  localparam logic [47:0] DRAM_TOP    = 48'h0001_0000_0000;
  localparam logic [47:0] MMIO_BASE   = 48'h0001_0000_0000;
  localparam logic [47:0] HOSTIF_BASE = 48'h0001_0000_0000;
  localparam logic [47:0] HOSTIF_TOP  = 48'h0001_0001_0000;
  // TB-only IRQ stimulus (verification aid, not part of the SoC).
  localparam logic [47:0] STIM_BASE   = 48'h0001_0008_0000;
  localparam logic [47:0] STIM_TOP    = 48'h0001_0009_0000;
  localparam logic [47:0] CLINT_BASE  = 48'h0001_0010_0000;
  localparam logic [47:0] CLINT_TOP   = 48'h0001_0011_0000;
  localparam logic [47:0] PLIC_BASE   = 48'h0001_0020_0000;
  localparam logic [47:0] PLIC_TOP    = 48'h0001_0060_0000;

  localparam logic [47:0] RESET_PC    = DRAM_BASE;

  localparam logic [63:0] TOHOST_OFF   = 64'h0000_0000_0000_0000;
  localparam logic [63:0] FROMHOST_OFF = 64'h0000_0000_0000_0008;
  localparam logic [63:0] CHAROUT_OFF  = 64'h0000_0000_0000_0010;

  localparam logic [63:0] TOHOST_PASS = 64'h0000_0000_0000_0001;

endpackage

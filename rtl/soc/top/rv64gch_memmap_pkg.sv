package rv64gch_memmap_pkg;

  localparam logic [47:0] DRAM_BASE   = 48'h0000_8000_0000;
  localparam logic [47:0] DRAM_TOP    = 48'h0001_0000_0000;
  localparam logic [47:0] MMIO_BASE   = 48'h0001_0000_0000;
  localparam logic [47:0] HOSTIF_BASE = 48'h0001_0000_0000;
  localparam logic [47:0] HOSTIF_TOP  = 48'h0001_0001_0000;

  localparam logic [47:0] RESET_PC    = DRAM_BASE;

  localparam logic [63:0] TOHOST_OFF   = 64'h0000_0000_0000_0000;
  localparam logic [63:0] FROMHOST_OFF = 64'h0000_0000_0000_0008;
  localparam logic [63:0] CHAROUT_OFF  = 64'h0000_0000_0000_0010;

  localparam logic [63:0] TOHOST_PASS = 64'h0000_0000_0000_0001;

endpackage

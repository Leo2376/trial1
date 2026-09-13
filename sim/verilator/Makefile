RTL_PKG    := ../../rtl/soc/top/rv64gch_memmap_pkg.sv
IF         := ../../rtl/soc/fabric/axi4_if.sv
DEC        := ../../rtl/soc/fabric/axi4_decoder.sv
TB         := ../../verification/tb_core/tb_rv64gch_core.sv
STUB       := ../../verification/tb_core/axi4_master_stub.sv
DRAM       := ../../verification/tb_core/axi4_dram_model.sv
HOSTIF     := ../../verification/tb_core/axi4_hostif_model.sv

SRCS := $(RTL_PKG) $(IF) $(DEC) $(STUB) $(DRAM) $(HOSTIF) $(TB)

VFLAGS := --binary --timing -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE
VFLAGS += -top-module tb_rv64gch_core

all: run

obj_dir/Vtb_rv64gch_core: $(SRCS)
	verilator $(VFLAGS) $(SRCS)

run: obj_dir/Vtb_rv64gch_core
	./obj_dir/Vtb_rv64gch_core

clean:
	rm -rf obj_dir

.PHONY: all run clean

RTL_PKG    := ../../rtl/soc/top/rv64gch_memmap_pkg.sv
IF         := ../../rtl/soc/fabric/axi4_if.sv
DEC        := ../../rtl/soc/fabric/axi4_decoder.sv
TB         := ../../verification/tb_core/tb_rv64gch_core.sv
STUB       := ../../verification/tb_core/axi4_master_stub.sv
DRAM       := ../../verification/tb_core/axi4_dram_model.sv
HOSTIF     := ../../verification/tb_core/axi4_hostif_model.sv

SRCS := $(RTL_PKG) $(IF) $(DEC) $(STUB) $(DRAM) $(HOSTIF) $(TB)

SIM  := iverilog -g2012 -Wall -o sim.vvp $(SRCS)
RUN  := vvp sim.vvp

all: run

sim.vvp: $(SRCS)
	$(SIM)

run: sim.vvp
	$(RUN)

clean:
	rm -f sim.vvp

.PHONY: all run clean

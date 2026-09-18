TOP      := tb_rv64gch_core
FILELIST := ../filelist.f
EXE      := obj_dir/V$(TOP)
HEX_FILE := prog.vh
GEN_HEX  := ../../tools/scripts/gen_smoke_hex.py
ELF_TO_HEX := ../../tools/scripts/elf_to_hex.py

# Default test: smoke test
TEST     ?= smoke
RISCV_TESTS_DIR := ../../riscv-tests/isa

VFLAGS := --binary --timing -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE
VFLAGS += -Wno-INITIALDLY -top-module $(TOP)

all: run

# Generate hex from smoke test (default)
prog_smoke.vh: $(GEN_HEX)
	python3 $(GEN_HEX) prog_smoke.vh

# Generate hex from riscv-test ELF
prog_%.vh: $(RISCV_TESTS_DIR)/rv64uf-p-%
	python3 $(ELF_TO_HEX) $< $@

$(HEX_FILE): prog_$(TEST).vh
	cp prog_$(TEST).vh $(HEX_FILE)

$(EXE): $(FILELIST) $(shell cat $(FILELIST))
	verilator $(VFLAGS) -f $(FILELIST)

run: $(HEX_FILE) $(EXE)
	./$(EXE)

# Run a specific FPU test: make TEST=fadd
# Run smoke test: make TEST=smoke

clean:
	rm -rf obj_dir prog.vh prog_*.vh

.PHONY: all run clean
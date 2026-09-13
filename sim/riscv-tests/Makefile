# rv64ui ISA regression against riscv-tests under the Verilator testbench.
#
# Requires: riscv64-unknown-elf-gcc, python3, and the prebuilt Vtb_rv64gch_core
# simulator (run `make -C ../verilator` first, or `make sim` here).
#
# Override the riscv-tests source tree / test list with:
#   make RISCV_SRC=/path/to/riscv-tests/isa TESTS="add sub lb"
#
ROOT     := $(CURDIR)/../..
SIM      := $(ROOT)/sim/verilator/obj_dir/Vtb_rv64gch_core
ENVDIR   := $(ROOT)/software/riscv-tests-env/rv64gch
ELF2HEX  := $(ROOT)/tools/scripts/elf2hex.py
RISCV_SRC?= /opt/riscv-tests/isa
MARCH    := rv64imafd_zicsr_zifencei
MABI     := lp64d
WORK     := $(CURDIR)/build

# Base integer ISA (rv64ui) subset exercised by this regression.
TESTS ?= \
  add addi addw addiw and andi auipc beq bge bgeu blt bltu bne \
  jal jalr lui or ori simple slli slliw sll sllw slt slti sltiu sltu \
  srai sraiw sra sraw srli srliw srl srlw sub subw xor xori \
  lb lbu lh lhu lw lwu ld sb sh sw sd

CC := riscv64-unknown-elf-gcc
CFLAGS := -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles -static \
          -T $(ENVDIR)/link.ld -I $(ENVDIR) -I $(ROOT)/software/riscv-tests-env \
          -I $(RISCV_SRC) -I $(RISCV_SRC)/macros/scalar

.PHONY: all sim isa clean

all: sim isa

sim:
	$(MAKE) -C $(ROOT)/sim/verilator

isa: $(SIM)
	@mkdir -p $(WORK)
	@fail=0; for t in $(TESTS); do \
	  src=$(RISCV_SRC)/rv64ui/$$t.S; \
	  [ -f "$$src" ] || { echo "SKIP $$t (no source)"; continue; }; \
	  elf=$(WORK)/$$t.elf; hex=$(WORK)/$$t.hex; \
	  $(CC) $(CFLAGS) $$src -o $$elf 2>/dev/null || { echo "COMPILE_FAIL $$t"; fail=1; continue; }; \
	  python3 $(ELF2HEX) $$elf $$hex >/dev/null 2>&1 || true; \
	  out=`$(SIM) +hex=$$hex 2>/dev/null | grep -E '\[tb\] TEST (PASSED|FAILED)'`; \
	  echo "$$out" | grep -q PASSED && echo "PASS $$t" || { echo "FAIL $$t"; fail=1; }; \
	done; \
	echo "============================="; \
	[ "$$fail" -eq 0 ] && echo "ALL ISA TESTS PASSED" || { echo "ISA TESTS FAILED"; exit 1; }

clean:
	rm -rf $(WORK)

$(SIM):
	$(MAKE) -C $(ROOT)/sim/verilator

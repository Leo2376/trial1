TOP      := tb_rv64gch_core
FILELIST := ../filelist.f
EXE      := obj_dir/V$(TOP)
HEX_FILE := prog.vh
GEN_HEX  := ../../tools/scripts/gen_smoke_hex.py

VFLAGS := --binary --timing -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE
VFLAGS += -Wno-INITIALDLY -top-module $(TOP)

all: run

$(HEX_FILE): $(GEN_HEX)
	python3 $(GEN_HEX) $(HEX_FILE)

$(EXE): $(FILELIST) $(shell cat $(FILELIST))
	verilator $(VFLAGS) -f $(FILELIST)

run: $(HEX_FILE) $(EXE)
	./$(EXE)

clean:
	rm -rf obj_dir $(HEX_FILE)

.PHONY: all run clean

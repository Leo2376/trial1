TOP      := tb_rv64gch_core
FILELIST := ../filelist.f
EXE      := obj_dir/V$(TOP)

VFLAGS := --binary --timing -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE
VFLAGS += -Wno-INITIALDLY -top-module $(TOP)

all: run

$(EXE): $(FILELIST) $(shell cat $(FILELIST))
	verilator $(VFLAGS) -f $(FILELIST)

run: $(EXE)
	./$(EXE)

clean:
	rm -rf obj_dir

.PHONY: all run clean

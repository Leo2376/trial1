TOP      := tb_rv64gch_core
FILELIST := ../filelist.f
SIM      := iverilog -g2012 -Wall -o sim.vvp
RUN      := vvp sim.vvp

all: run

sim.vvp: $(FILELIST) $(shell cat $(FILELIST))
	$(SIM) -c $(FILELIST)

run: sim.vvp
	$(RUN)

clean:
	rm -f sim.vvp

.PHONY: all run clean

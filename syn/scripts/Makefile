# ----------------------------------------------------------------------------
# ASAP7 + Yosys synthesis driver for the rv64gch_core.
#
# Targets:
#   libs      - fetch + decompress + merge ASAP7 RVT_TT NLDM liberty
#   synth     - run Yosys synthesis (depends on libs)
#   clean     - remove generated outputs
#   distclean - also remove fetched ASAP7 clone
#
# Override defaults on the command line, e.g.:
#   make synth TOP=rv64gch_core YOSYS=yosys
# ----------------------------------------------------------------------------

# --- Tool paths --------------------------------------------------------------
YOSYS    ?= yosys
P7ZIP    ?= 7z
GIT      ?= git
PYTHON3  ?= python3

# --- Top + paths -------------------------------------------------------------
TOP      ?= rv64gch_core
OUTDIR   ?= ../output
LIBDIR   ?= ../lib
FILELIST ?= ../filelist.f
TCL      ?= synth_yosys.tcl

ASAP7_URL    ?= https://github.com/The-OpenROAD-Project/asap7
ASAP7_DIR    ?= ../third_party/asap7
ASAP7_LIBDIR ?= $(ASAP7_DIR)/asap7sc7p5t_28/LIB/NLDM

# Merged liberty consumed by Yosys (abc / dfflibmap).
MERGED_LIB   ?= $(LIBDIR)/asap7_RVT_TT.lib

# RVT, typical-typical corner, 7.5-track. 5 cell categories must be merged.
RVT_TT_SRC := \
	asap7sc7p5t_AO_RVT_TT_nldm_211120 \
	asap7sc7p5t_INVBUF_RVT_TT_nldm_220122 \
	asap7sc7p5t_OA_RVT_TT_nldm_211120 \
	asap7sc7p5t_SEQ_RVT_TT_nldm_220123 \
	asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120

# Compressed sources in the ASAP7 clone.
RVT_TT_7Z   := $(addsuffix .lib.7z,$(addprefix $(ASAP7_LIBDIR)/,$(RVT_TT_SRC)))
RVT_TT_LIB  := $(addsuffix .lib,$(addprefix $(LIBDIR)/,$(RVT_TT_SRC)))

.PHONY: libs synth clean distclean all
all: synth

# --- Fetch ASAP7 -------------------------------------------------------------
$(ASAP7_DIR)/.git:
	@mkdir -p $(dir $(ASAP7_DIR))
	$(GIT) clone --depth 1 $(ASAP7_URL) $(ASAP7_DIR)
	cd $(ASAP7_DIR) && $(GIT) submodule update --init --recursive asap7sc7p5t_28

# The .7z archives are produced by the ASAP7 clone+submodule above, so they
# have no recipe of their own - declare them satisfied once the clone exists.
$(RVT_TT_7Z): $(ASAP7_DIR)/.git
	@:

# --- Decompress a single .lib.7z into $(LIBDIR) -----------------------------
# Pattern rule keyed on the staged basename in $(LIBDIR).
$(LIBDIR)/%.lib: $(ASAP7_LIBDIR)/%.lib.7z | $(ASAP7_DIR)/.git
	@mkdir -p $(LIBDIR)
	$(P7ZIP) x -o$(LIBDIR) -y $<

# --- Merge the 5 RVT_TT liberty files into one -------------------------------
# Liberty concatenation is valid: each .lib declares a `library (...)` block;
# most Yosys flows accept a single concatenated file. We strip any duplicate
# `default_*` header lines from the second+ files to avoid parser warnings.
$(MERGED_LIB): $(RVT_TT_LIB)
	@mkdir -p $(LIBDIR)
	$(PYTHON3) merge_libs.py $(LIBDIR) $@ $(RVT_TT_LIB)

.PHONY: libs
libs: $(ASAP7_DIR)/.git $(MERGED_LIB)

# --- Synthesis ---------------------------------------------------------------
# Run Yosys from syn/ (the parent of scripts/) so the relative paths in
# filelist.f (../rtl/...) and the TCL default paths resolve correctly.
synth: libs
	@mkdir -p $(OUTDIR)
	cd .. && YOSYS=$(YOSYS) LIBFILE=lib/asap7_RVT_TT.lib FILELIST=filelist.f \
		TOP=$(TOP) OUTDIR=output $(YOSYS) -c scripts/$(TCL)

# --- Cleanup -----------------------------------------------------------------
clean:
	rm -rf $(OUTDIR) $(LIBDIR)

distclean: clean
	rm -rf $(ASAP7_DIR)

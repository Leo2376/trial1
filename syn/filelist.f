# Synthesis filelist - RTL sources for Yosys (open-source frontend) flow.
# Only modules with plain logic ports are included here. The SoC fabric
# (axi4_master / axi4_decoder / rv64gch_top) use the SystemVerilog `axi4_if`
# interface, which the open-source Yosys Verilog frontend does not support.
# Those are synthesized with a commercial frontend (Verific/Synopsys) flow.
#
# Order matters: packages and sub-modules must precede their users.
../rtl/core/rtl_core_pkg.sv
../rtl/soc/top/rv64gch_memmap_pkg.sv
../rtl/core/frontend/decompressor.sv
../rtl/core/regfile/regfile_int.sv
../rtl/core/regfile/regfile_fp.sv
../rtl/core/int_alu/alu.sv
../rtl/core/mul_div/mdu.sv
../rtl/core/fpu/fpu.sv
../rtl/core/csr/csr_unit.sv
../rtl/core/ctrl/forwarding_unit.sv
../rtl/core/ctrl/hazard_unit.sv
../rtl/core/rv64gch_core.sv

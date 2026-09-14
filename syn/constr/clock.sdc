# SDC constraints for ASAP7 synthesis of the rv64gch_core.
# All timings referenced to the 1 GHz virtual clock; ASAP7 nominal Vdd=0.7V.
# These are synthesis-place estimates, not sign-off timing.

# --- Virtual clock ------------------------------------------------------------
# ASAP7 7nm nominal corner. 1 GHz = 1.0 ns period; conservative for RTL synth.
create_clock -name clk -period 1000 [get_ports clk]

# Asynchronous active-low reset - not constrained for recovery/removal here
# (added by the commercial backend timing flow).
set_input_delay  200 -clock clk [all_inputs]
set_output_delay 200 -clock clk [all_outputs]

# Unconstrained paths - reset deassertion is handled by reset synchronizers
# inside the core; treat rst_n as a false path to avoid over-constraining.
set_false_path -from [get_ports rst_n]

# Don't touch clock - synthesis should not buffer the input clock port.
set_don't_touch [get_ports clk]

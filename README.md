# MyLittleEDA.tcl
**A Lightweight EDA Tool for ASIC Design and Prototyping**

## Overview
**MyLittleEDA.tcl** is a Tcl-based Electronic Design Automation (EDA) tool designed for ASIC design, prototyping, and analysis. It supports:
- Netlist parsing (Verilog)
- Basic placement and routing
- Timing analysis
- DFT (Design-for-Test) insertion
- Voltage drop and safety analysis via USF files

## Features
- **Netlist Parsing**: Reads and analyzes Verilog netlists.
- **Physical Prototyping**: Generates LEF and LIB views for standard cells.
- **Timing Analysis**: Estimates critical paths and timing constraints.
- **DFT Support**: Inserts scan chains and test structures.
- **User-Friendly Interface**: Simple Tcl commands for automation.

## Usage
1. Load the tool in your Tcl environment:
   ```tcl
   source mylittleda.tcl
   ```
2. Parse a Verilog netlist:
   ```tcl
   read_verilog design.v
   ```
3. Generate LEF/LIB files:
   ```tcl
   write_lef design.lef
   write_lib design.lib
   ```

## Future Enhancements
- Advanced timing analysis
- Power analysis
- GUI integration
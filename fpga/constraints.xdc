# ==============================================================================
# Timing Constraints for cJTAG Bridge - XCKU5P
# ==============================================================================

set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 51.0 [current_design]

# ==============================================================================
# Clock Pin Assignments
# ==============================================================================
# 100 MHz Differential System Clock on pins T25 (P) / U25 (N)
set_property PACKAGE_PIN T25 [get_ports clk_i_p]
set_property PACKAGE_PIN U25 [get_ports clk_i_n]
set_property IOSTANDARD LVDS [get_ports clk_i_p]
set_property IOSTANDARD LVDS [get_ports clk_i_n]

# ==============================================================================
# Clock Timing Constraints
# ==============================================================================
# Primary Clock - 100 MHz differential system clock
create_clock -period 10.000 -name clk_sys -waveform {0.000 5.000} [get_ports clk_i_p]

# TCKC Input Clock (variable frequency, conservatively constrain to 50 MHz max)
create_clock -period 20.000 -name tckc -waveform {0.000 10.000} [get_ports tckc_i]

# Generated TCK clock (internal JTAG clock from cJTAG bridge)
# TCK is generated from system clock logic - treat as asynchronous to both clk_sys and tckc
# Use wildcard to match synthesized register name (tck_int_reg or similar)
create_generated_clock -name tck_generated -source [get_ports clk_i_p] -divide_by 1 [get_pins -hierarchical -filter {NAME =~ */tck_int_reg/Q}]

# Asynchronous clock groups (TCKC, TCK, and system clock are independent)
set_clock_groups -asynchronous -group [get_clocks clk_sys] -group [get_clocks tckc] -group [get_clocks -filter {NAME =~ *tck_generated*}]

# ==============================================================================
# I/O Timing Constraints
# ==============================================================================
# Input delays (relative to TCKC)
set_input_delay -clock tckc -min 2.000 [get_ports tmsc]
set_input_delay -clock tckc -max 8.000 [get_ports tmsc]

# Output delays (relative to TCKC)
set_output_delay -clock tckc -min 0.000 [get_ports tmsc]
set_output_delay -clock tckc -max 5.000 [get_ports tmsc]

# Reset input delays (relative to system clock)
set_input_delay -clock clk_sys -min 2.000 [get_ports ntrst_i]
set_input_delay -clock clk_sys -max 8.000 [get_ports ntrst_i]

# Reset is asynchronous
set_false_path -from [get_ports ntrst_i]

# ==============================================================================
# I/O Standards (Default for non-clock signals)
# ==============================================================================
set_property IOSTANDARD LVCMOS18 [get_ports ntrst_i]
set_property IOSTANDARD LVCMOS18 [get_ports tckc_i]
set_property IOSTANDARD LVCMOS18 [get_ports tmsc]

# ==============================================================================
# Pin Assignments for Other Signals
# ==============================================================================
# TODO: Add PACKAGE_PIN constraints based on your board layout
set_property PACKAGE_PIN J9 [get_ports ntrst_i]
set_property PACKAGE_PIN H9 [get_ports tckc_i]
set_property PACKAGE_PIN G9 [get_ports tmsc]


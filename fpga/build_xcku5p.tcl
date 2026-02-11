# ==============================================================================
# Vivado TCL Build Script for cJTAG Bridge
# Target: Xilinx XCKU5P (Kintex UltraScale+)
# ==============================================================================
# Usage:
#   vivado -mode batch -source build_xcku5p.tcl
#   vivado -mode gui -source build_xcku5p.tcl
# ==============================================================================

set project_name "cjtag_xcku5p"
set project_dir  "./project"
set build_dir    "./build"

# Device Configuration
set device_part "xcku5p-ffvb676-1-e"

puts "================================================================================"
puts "cJTAG Bridge - Vivado Project Setup for XCKU5P"
puts "================================================================================"

# ==============================================================================
# Create Project
# ==============================================================================
if {[file exists $project_dir]} {
    puts "Cleaning existing project directory..."
    file delete -force $project_dir
}

create_project $project_name $project_dir -part $device_part -force
set_property target_language Verilog [current_project]

puts "Project created: $project_name"
puts "Target device: $device_part"

# ==============================================================================
# Add Source Files
# ==============================================================================
puts "\nAdding source files..."

# Add RTL sources
set src_files [list \
    "../src/cjtag/cjtag_bridge.sv" \
    "../src/jtag/jtag_tap.sv" \
    "../src/riscv/riscv_dtm.sv" \
]

foreach src $src_files {
    if {[file exists $src]} {
        add_files -norecurse $src
        puts "  Added: $src"
    } else {
        puts "  WARNING: File not found: $src"
    }
}

# Add top-level FPGA module (with differential clock support)
if {[file exists "../src/top_fpga.sv"]} {
    add_files -norecurse ../src/top_fpga.sv
    puts "  Added: ../src/top_fpga.sv (FPGA top with differential clock)"
} else {
    error "FPGA top module not found: ../src/top_fpga.sv"
}

# Switch to manual compile order mode (required to set top module)
set_property source_mgmt_mode None [current_project]

# Set top module
set_property top top [current_fileset]

# Update compile order
update_compile_order -fileset sources_1

# ==============================================================================
# Synthesis Settings
# ==============================================================================
puts "\nConfiguring synthesis settings..."

set_property strategy "Vivado Synthesis Defaults" [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE Default [get_runs synth_1]

set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FSM_EXTRACTION auto [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS true [get_runs synth_1]

# ==============================================================================
# Implementation Settings
# ==============================================================================
puts "Configuring implementation settings..."

set_property strategy "Vivado Implementation Defaults" [get_runs impl_1]
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Default [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE Default [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Default [get_runs impl_1]

# ==============================================================================
# Suppress Benign Warnings
# ==============================================================================
puts "Configuring message suppression..."

# Suppress Device 21-9073: RSS factor Speedmodel warnings
# These are benign Vivado tool warnings about missing speed models for global routing
set_msg_config -id {Device 21-9073} -suppress

# Suppress Device 21-9320 and 21-2174: Oracle tile group warnings
# These are benign device-specific warnings
set_msg_config -id {Device 21-9320} -suppress
set_msg_config -id {Device 21-2174} -suppress

# Suppress Vivado 12-7122: Auto Incremental Compile warning
# This is expected on first run
set_msg_config -id {Vivado 12-7122} -suppress

# Suppress Synth 8-7080: Parallel synthesis criteria
# This is informational for small designs
set_msg_config -id {Synth 8-7080} -suppress

# ==============================================================================
# Add Timing Constraints
# ==============================================================================
puts "Adding timing constraints..."

set xdc_file "../fpga/constraints.xdc"

if {[file exists $xdc_file]} {
    add_files -fileset constrs_1 -norecurse $xdc_file
    puts "  Added: $xdc_file"
} else {
    error "Constraints file not found: $xdc_file"
}

# ==============================================================================
# Build Functions
# ==============================================================================

proc run_synthesis {} {
    puts "\n================================================================================"
    puts "Running Synthesis..."
    puts "================================================================================"

    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1

    if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
        error "Synthesis failed!"
    }

    open_run synth_1

    puts "\n--- Synthesis Report ---"
    report_timing_summary -file ./build/synth_timing.rpt
    report_utilization -file ./build/synth_utilization.rpt
    report_utilization -hierarchical -file ./build/synth_utilization_hier.rpt

    puts "Synthesis completed successfully!"
}

proc run_implementation {} {
    puts "\n================================================================================"
    puts "Running Implementation..."
    puts "================================================================================"

    launch_runs impl_1 -jobs 4
    wait_on_run impl_1

    if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
        error "Implementation failed!"
    }

    open_run impl_1

    puts "\n--- Implementation Report ---"
    report_timing_summary -file ./build/impl_timing.rpt
    report_utilization -file ./build/impl_utilization.rpt
    report_utilization -hierarchical -file ./build/impl_utilization_hier.rpt
    report_power -file ./build/impl_power.rpt
    report_drc -file ./build/impl_drc.rpt

    # Check timing
    set slack [get_property SLACK [get_timing_paths]]
    if {$slack < 0} {
        puts "WARNING: Timing not met! Slack = $slack"
    } else {
        puts "Timing met. Slack = $slack"
    }

    puts "Implementation completed successfully!"
}

proc generate_bitstream {} {
    puts "\n================================================================================"
    puts "Generating Bitstream..."
    puts "================================================================================"

    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1

    # Copy bitstream to build directory
    file mkdir $::build_dir
    set bit_file "$::project_dir/$::project_name.runs/impl_1/top.bit"
    if {[file exists $bit_file]} {
        file copy -force $bit_file "$::build_dir/cjtag_xcku5p.bit"
        puts "Bitstream generated: $::build_dir/cjtag_xcku5p.bit"
    } else {
        error "Bitstream file not found!"
    }
}

proc build_all {} {
    file mkdir $::build_dir
    run_synthesis
    run_implementation
    generate_bitstream
    puts "\n================================================================================"
    puts "Build completed successfully!"
    puts "Bitstream: $::build_dir/cjtag_xcku5p.bit"
    puts "================================================================================"
}

# ==============================================================================
# Auto-build if in batch mode
# ==============================================================================
if {[info exists ::env(BUILD_AUTO)] && $::env(BUILD_AUTO) == "1"} {
    build_all
    exit
}

puts "\n================================================================================"
puts "Project setup completed!"
puts "================================================================================"
puts "\nAvailable commands:"
puts "  run_synthesis        - Run synthesis only"
puts "  run_implementation   - Run implementation"
puts "  generate_bitstream   - Generate bitstream"
puts "  build_all            - Complete build flow"
puts "\nTo build automatically, run:"
puts "  BUILD_AUTO=1 vivado -mode batch -source build_xcku5p.tcl"
puts "================================================================================"

# cJTAG Bridge - FPGA Build

This directory contains scripts for building the cJTAG bridge design for FPGA targets.

## Target Device

- **XCKU5P-FFVB676-1-E** (Xilinx Kintex UltraScale+)

## Prerequisites

- Xilinx Vivado 2020.2 or later
- Valid Vivado license for the target device

## Quick Start

### Using Vivado GUI

```bash
vivado -mode gui -source build_xcku5p.tcl
```

Then in the Tcl console:
```tcl
build_all
```

### Batch Mode (Automated Build)

```bash
BUILD_AUTO=1 vivado -mode batch -source build_xcku5p.tcl
```

Or use the Makefile:
```bash
make         # Build everything
make synth   # Synthesis only
make impl    # Implementation only
make bit     # Generate bitstream
make clean   # Clean project
```

## Build Flow

The TCL script provides these commands:

| Command | Description |
|---------|-------------|
| `run_synthesis` | Run synthesis only |
| `run_implementation` | Run place & route |
| `generate_bitstream` | Generate bitstream file |
| `build_all` | Complete build flow |

## Project Structure

```
fpga/
├── build_xcku5p.tcl          # Main build script
├── constraints.xdc           # Timing and pin constraints
├── Makefile                   # Convenience wrapper
├── project/                   # Generated Vivado project (gitignored)
└── build/                     # Build outputs (gitignored)
    ├── cjtag_xcku5p.bit      # Final bitstream
    ├── synth_timing.rpt      # Synthesis timing report
    ├── impl_timing.rpt       # Implementation timing report
    └── *.rpt                 # Various reports
```

## Timing Constraints

Timing and pin constraints are defined in [constraints.xdc](constraints.xdc):

- **System Clock (clk_i_p/clk_i_n)**: 100 MHz differential on pins T25/U25
- **TCKC Clock**: Up to 50 MHz (conservative constraint)
- **Clock Domains**: Marked as asynchronous

To customize constraints, edit [constraints.xdc](constraints.xdc) directly.

## I/O Pin Mapping

Pin constraints are defined in [constraints.xdc](constraints.xdc). The 100 MHz differential clock is assigned to pins T25/U25.

**Port Interface (3 signals):**
- `clk_i_p/clk_i_n` - 100 MHz differential system clock (pins T25/U25)
- `ntrst_i` - JTAG reset, active low
- `tckc_i` - cJTAG clock input
- `tmsc` - cJTAG bidirectional data (inout)

Other signal pins need to be assigned based on your board layout. Edit [constraints.xdc](constraints.xdc) and uncomment/modify the TODO section:

```tcl
# Example pin assignments (edit based on your board)
set_property PACKAGE_PIN AA12 [get_ports ntrst_i]
set_property PACKAGE_PIN AB12 [get_ports tckc_i]
set_property PACKAGE_PIN AC12 [get_ports tmsc]
```

## Build Reports

After building, check these reports in the `build/` directory:

- **Timing Reports**: Verify all timing requirements are met
- **Utilization Reports**: Check resource usage
- **Power Reports**: Estimate power consumption
- **DRC Reports**: Design rule check results

### Latest Build Results (XCKU5P-FFVB676-1-E)

**Resource Utilization (Post-Implementation):**
- **LUTs**: 155 / 216,960 (0.07%)
- **Flip-Flops**: 201 / 433,920 (0.05%)
- **CLBs**: 28 / 27,120 (0.10%)
- **IOBs**: 5 / 280 (1.79%)
- **BRAM**: 0 / 480 (0.00%)
- **DSP**: 0 / 1,824 (0.00%)

**Timing Summary (Post-Route):**
- **WNS (Worst Negative Slack)**: +8.185 ns ✅ TIMING MET
- **TNS (Total Negative Slack)**: 0.000 ns
- **WHS (Worst Hold Slack)**: +0.043 ns ✅ HOLD MET
- **WPWS (Worst Pulse Width Slack)**: +4.725 ns ✅ PULSE WIDTH MET
- **Failing Endpoints**: 0

**Power Consumption (Estimated):**
- **Total On-Chip Power**: 0.455 W
  - Dynamic Power: 0.005 W
  - Static Power: 0.450 W
- **Junction Temperature**: 25.8°C
- **Max Ambient**: 99.2°C

**Design Characteristics:**
- 379 total timing endpoints
- 14 unique control sets
- All clocks properly constrained
- No timing violations
- Extended temperature grade supported (-40°C to +100°C)

## Synthesis Notes

The FPGA build uses `top_fpga.sv` which includes an IBUFDS buffer for differential clock input. The simulation testbench uses `top.sv` with single-ended clock.

Key differences:
- **FPGA (top_fpga.sv)**: Differential clock inputs (clk_i_p/clk_i_n) with IBUFDS
- **Simulation (top.sv)**: Single-ended clock (clk_i)

The `initial` blocks and `$dumpfile` statements in testbench modules are automatically ignored by Vivado during synthesis.

## Troubleshooting

### Timing Not Met

1. Check `build/impl_timing.rpt` for critical paths
2. Adjust clock constraints if needed
3. Try different synthesis/implementation strategies
4. Enable physical optimization

### Resource Utilization Issues

The cJTAG bridge is very lightweight and fits easily on even small FPGAs:
- **LUTs**: ~155 (0.07% of XCKU5P)
- **Flip-Flops**: ~201 (0.05% of XCKU5P)
- **No BRAMs or DSPs required**

If you see significantly higher utilization, check for unexpected logic duplication or instantiation issues.

### Synthesis Warnings

All code should synthesize without warnings. If you see warnings:
- Check the design follows synthesizable coding practices
- Review clock domain crossings
- Ensure all case statements have defaults

## Advanced Options

### Custom Build Strategy

Edit the TCL script to change synthesis/implementation strategies:

```tcl
set_property strategy "Flow_PerfOptimized_high" [get_runs synth_1]
set_property strategy "Performance_ExplorePostRoutePhysOpt" [get_runs impl_1]
```

### Multi-Threading

Adjust the `-jobs` parameter:

```tcl
launch_runs synth_1 -jobs 8  # Use 8 threads
```

## License

Same as the main cJTAG project.

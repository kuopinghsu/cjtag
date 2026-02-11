# Makefile for cJTAG FPGA Build
# Target: Xilinx XCKU5P (Kintex UltraScale+)

PROJECT = cjtag_xcku5p
TCL_SCRIPT = build_xcku5p.tcl

.PHONY: all synth impl bit clean gui help

# Default target - build everything
all: bit

# Open project in GUI
gui:
	@echo "Opening Vivado GUI..."
	vivado -mode gui -source $(TCL_SCRIPT)

# Run synthesis only
synth:
	@echo "Running synthesis..."
	@echo 'run_synthesis; exit' | vivado -mode batch -source $(TCL_SCRIPT)

# Run implementation only (requires synthesis)
impl:
	@echo "Running implementation..."
	@echo 'run_synthesis; run_implementation; exit' | vivado -mode batch -source $(TCL_SCRIPT)

# Generate bitstream (full flow)
bit:
	@echo "Running full build flow..."
	BUILD_AUTO=1 vivado -mode batch -source $(TCL_SCRIPT)
	@echo ""
	@echo "=========================================="
	@if [ -f build/$(PROJECT).bit ]; then \
		echo "Build successful!"; \
		echo "Bitstream: build/$(PROJECT).bit"; \
		echo "Size: $$(ls -lh build/$(PROJECT).bit | awk '{print $$5}')"; \
	else \
		echo "Build failed - bitstream not found"; \
		exit 1; \
	fi
	@echo "=========================================="

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf project build .Xil *.log vivado*.jou

# Help target
help:
	@echo "cJTAG FPGA Build System"
	@echo ""
	@echo "Targets:"
	@echo "  make        - Build complete design (synthesis + implementation + bitstream)"
	@echo "  make synth  - Run synthesis only"
	@echo "  make impl   - Run synthesis + implementation"
	@echo "  make bit    - Generate bitstream (same as 'make' or 'make all')"
	@echo "  make gui    - Open Vivado GUI with project"
	@echo "  make clean  - Remove all generated files"
	@echo "  make help   - Show this help message"
	@echo ""
	@echo "Build artifacts:"
	@echo "  build/$(PROJECT).bit  - Final bitstream"
	@echo "  build/*.rpt           - Build reports"
	@echo "  project/              - Vivado project directory"

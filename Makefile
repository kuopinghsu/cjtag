#!/usr/bin/make -f
# =============================================================================
# Makefile for cJTAG Bridge Verilator Simulation
# =============================================================================

# Project directories
SRC_DIR     := src
TB_DIR      := tb
BUILD_DIR   := build

# Source files
RTL_SOURCES := $(SRC_DIR)/cjtag_bridge.sv \
               $(SRC_DIR)/jtag_tap.sv \
               $(SRC_DIR)/top.sv

CPP_SOURCES := $(TB_DIR)/tb_cjtag.cpp \
               $(SRC_DIR)/jtag_vpi.cpp

# Verilator configuration
VERILATOR   := verilator
TOP_MODULE  := top
VFLAGS      := --cc \
               --exe \
               --build \
               --trace-fst \
               --trace-structs \
               --trace-depth 5 \
               -Wall \
               -Wno-fatal \
               --top-module $(TOP_MODULE) \
               -CFLAGS "-I$(SRC_DIR) -std=c++14" \
               -LDFLAGS "-lpthread"

# Output binary
VERILATOR_EXE := $(BUILD_DIR)/V$(TOP_MODULE)
VERILATOR_TEST := $(BUILD_DIR)/Vtest_$(TOP_MODULE)

# Test source
TEST_SOURCE := $(TB_DIR)/test_cjtag.cpp

# VPI Port
VPI_PORT := 3333

# Waveform control
WAVE ?= 0

# Verbose debug output
VERBOSE ?= 0

ifeq ($(VERBOSE),1)
VFLAGS += -DVERBOSE
endif

# =============================================================================
# Targets
# =============================================================================

.PHONY: all clean build run sim vpi test help

# Default target
all: build

# Help message
help:
	@echo "=========================================="
	@echo "cJTAG Bridge Makefile"
	@echo "=========================================="
	@echo "Targets:"
	@echo "  make build     - Build Verilator simulation"
	@echo "  make test      - Run automated test suite"
	@echo "  make run       - Run simulation (no waveform)"
	@echo "  make sim       - Run simulation with waveform"
	@echo "  make WAVE=1    - Run simulation with FST waveform dump"
	@echo "  make vpi       - Run simulation and wait for OpenOCD"
	@echo "  make clean     - Clean build artifacts"
	@echo "  make help      - Show this help message"
	@echo ""
	@echo "Environment Variables:"
	@echo "  WAVE=1         - Enable FST waveform dump"
	@echo "  VPI_PORT=3333  - VPI server port (default: 3333)"
	@echo ""
	@echo "Usage Examples:"
	@echo "  make test                    # Run automated tests"
	@echo "  make WAVE=1                  # Build and run with waveforms"
	@echo "  VPI_PORT=5555 make vpi       # Run VPI on custom port"
	@echo "=========================================="

# Build the simulation
build: $(VERILATOR_EXE)

$(VERILATOR_EXE): $(RTL_SOURCES) $(CPP_SOURCES)
	@mkdir -p $(BUILD_DIR)
	@echo "=========================================="
	@echo "Building Verilator simulation..."
	@echo "=========================================="
	@echo "RTL Sources: $(RTL_SOURCES)"
	@echo "C++ Sources: $(CPP_SOURCES)"
	@echo ""
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR) \
		$(RTL_SOURCES) \
		$(CPP_SOURCES)
	@echo ""
	@echo "Build complete: $(VERILATOR_EXE)"
	@echo "=========================================="

$(VERILATOR_TEST): $(RTL_SOURCES) $(TEST_SOURCE)
	@mkdir -p $(BUILD_DIR)
	@echo "=========================================="
	@echo "Building test suite..."
	@echo "=========================================="
	@echo "RTL Sources: $(RTL_SOURCES)"
	@echo "Test Source: $(TEST_SOURCE)"
	@echo ""
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/test_obj \
		-o ../Vtest_$(TOP_MODULE) \
		$(RTL_SOURCES) \
		$(TEST_SOURCE)
	@echo ""
	@echo "Test build complete: $(VERILATOR_TEST)"
	@echo "=========================================="

# Run automated test suite
test: $(VERILATOR_TEST)
	@echo "=========================================="
	@echo "Running automated test suite..."
	@echo "=========================================="
ifeq ($(WAVE),1)
	@echo "Waveform: Enabled (test_trace.fst)"
	@$(VERILATOR_TEST) --trace
else
	@$(VERILATOR_TEST)
endif
	@echo ""

# Run tests with waveform trace
test-trace: $(VERILATOR_TEST)
	@echo "=========================================="
	@echo "Running tests with waveform trace..."
	@echo "=========================================="
	@$(VERILATOR_TEST) --trace
	@echo ""
	@echo "Trace saved to: test_trace.fst"

# 
# Run simulation without waveform
run: build
	@echo "Running simulation (no waveform)..."
	@cd $(BUILD_DIR) && ./V$(TOP_MODULE)

# Run simulation with waveform
sim: WAVE=1
sim: build
	@echo "Running simulation with FST waveform..."
	@WAVE=1 VPI_PORT=$(VPI_PORT) $(VERILATOR_EXE) +trace

# Run and wait for VPI connection
vpi: build
	@echo "=========================================="
	@echo "Starting VPI simulation server..."
	@echo "=========================================="
ifeq ($(WAVE),1)
	@echo "Waveform: Enabled (cjtag.fst)"
	@WAVE=1 VPI_PORT=$(VPI_PORT) $(VERILATOR_EXE) +trace
else
	@echo "Waveform: Disabled"
	@echo "To enable: make WAVE=1 vpi"
	@VPI_PORT=$(VPI_PORT) $(VERILATOR_EXE)
endif

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf $(BUILD_DIR)
	rm -f *.fst *.vcd
	@echo "Clean complete."

# Lint RTL (optional)
lint:
	@echo "Running Vetest test-trace rilator lint..."
	$(VERILATOR) --lint-only $(RTL_SOURCES)

# View waveform with GTKWave
wave: cjtag.fst
	@if command -v gtkwave > /dev/null; then \
		echo "Opening waveform in GTKWave..."; \
		gtkwave cjtag.fst &; \
	else \
		echo "GTKWave not found. Install with: sudo apt-get install gtkwave"; \
		echo "Waveform file: cjtag.fst"; \
	fi

# Display status
status:
	@echo "=========================================="
	@echo "Project Status"
	@echo "=========================================="
	@echo "Build directory: $(BUILD_DIR)"
	@echo "Executable:      $(VERILATOR_EXE)"
	@echo "VPI Port:        $(VPI_PORT)"
	@echo ""
	@if [ -f "$(VERILATOR_EXE)" ]; then \
		echo "Status: Built ✓"; \
	else \
		echo "Status: Not built"; \
		echo "Run 'make build' to build"; \
	fi
	@echo "=========================================="

# =============================================================================
# Phony targets (non-file targets)
# =============================================================================
.PHONY: all build run sim vpi clean help lint wave status

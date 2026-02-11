#!/usr/bin/make -f
# =============================================================================
# Makefile for cJTAG Bridge Verilator Simulation
# =============================================================================

# Project directories
SRC_DIR     := src
TB_DIR      := tb
VPI_DIR     := vpi
BUILD_DIR   := build

# Source files
RTL_SOURCES := $(SRC_DIR)/cjtag/cjtag_bridge.sv \
               $(SRC_DIR)/jtag/jtag_tap.sv \
               $(SRC_DIR)/riscv/riscv_dtm.sv \
               $(SRC_DIR)/top.sv

CPP_SOURCES := $(TB_DIR)/tb_cjtag.cpp \
               $(VPI_DIR)/jtag_vpi.cpp

# Verilator configuration
VERILATOR   := verilator
TOP_MODULE  := top

# Performance optimization settings
# Note: VPI tests require single-threaded mode for stability
VERILATOR_THREADS ?= 2
OPT_LEVEL ?= 2

VFLAGS      := --cc \
               --exe \
               --build \
               --trace-fst \
               --trace-structs \
               --trace-depth 5 \
               -Wall \
               -Wno-fatal \
               --top-module $(TOP_MODULE) \
               --threads $(VERILATOR_THREADS) \
               -O$(OPT_LEVEL) \
               --x-assign fast \
               --x-initial fast \
               -LDFLAGS "-lpthread"

# Base CFLAGS (will be extended by VERBOSE flag)
CFLAGS_BASE := -I$(SRC_DIR) -I$(VPI_DIR) -std=c++14

# Output binary
VERILATOR_EXE := $(BUILD_DIR)/V$(TOP_MODULE)
VERILATOR_TEST := $(BUILD_DIR)/Vtest_$(TOP_MODULE)
IDCODE_TEST := $(BUILD_DIR)/test_idcode

# Test source
TEST_SOURCE := $(TB_DIR)/test_cjtag.cpp
IDCODE_TEST_SOURCE := $(TB_DIR)/test_idcode.cpp

# VPI Port
VPI_PORT := 3333

# Waveform control
WAVE ?= 0

# Verbose debug output
VERBOSE ?= 0

ifeq ($(VERBOSE),1)
CFLAGS_BASE += -DVERBOSE
VFLAGS += +define+VERBOSE
endif

# Add CFLAGS to VFLAGS
VFLAGS += -CFLAGS "$(CFLAGS_BASE)"

# =============================================================================
# Targets
# =============================================================================

.PHONY: all clean build run sim vpi test test-openocd test-idcode fpga help

# Default target

# Help message
help:
	@echo "=========================================="
	@echo "cJTAG Bridge Makefile"
	@echo "=========================================="
	@echo "Targets:"
	@echo "  make all          - Test all avaliable tests"
	@echo "  make build        - Build Verilator simulation"
	@echo "  make test         - Run automated test suite"
	@echo "  make test-openocd - Test OpenOCD connection to VPI"
	@echo "  make test-idcode  - Test VPI IDCODE read"
	@echo "  make run          - Run simulation (no waveform)"
	@echo "  make sim          - Run simulation with waveform"
	@echo "  make WAVE=1       - Run simulation with FST waveform dump"
	@echo "  make vpi          - Run simulation and wait for OpenOCD"
	@echo "  make fpga         - Build FPGA bitstream (Xilinx XCKU5P)"
	@echo "  make clean        - Clean build artifacts"
	@echo "  make help         - Show this help message"
	@echo ""
	@echo "Environment Variables:"
	@echo "  WAVE=1         - Enable FST waveform dump"
	@echo "  VERBOSE=1      - Show detailed build output and warnings"
	@echo "  VPI_PORT=3333  - VPI server port (default: 3333)"
	@echo "  VERILATOR_THREADS=2  - Parallel threads for simulation (default: 2)"
	@echo "  OPT_LEVEL=3    - Optimization level 0-3 (default: 3)"
	@echo ""
	@echo "Usage Examples:"
	@echo "  make test                    # Run automated tests"
	@echo "  make VERBOSE=1 test          # Run tests with verbose output"
	@echo "  make test-openocd            # Test OpenOCD VPI connection"
	@echo "  make test-idcode             # Test VPI IDCODE read"
	@echo "  make WAVE=1                  # Build and run with waveforms"
	@echo "  VPI_PORT=5555 make vpi       # Run VPI on custom port"
	@echo "  VERILATOR_THREADS=4 make test  # Use 4 threads for faster simulation"
	@echo "  OPT_LEVEL=3 make build       # Maximum optimization (default)"
	@echo "=========================================="

# Test all
all: test test-idcode test-openocd

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

$(IDCODE_TEST): $(RTL_SOURCES) $(IDCODE_TEST_SOURCE)
	@mkdir -p $(BUILD_DIR)
	@echo "=========================================="
	@echo "Building IDCODE test..."
	@echo "=========================================="
	@echo "RTL Sources: $(RTL_SOURCES)"
	@echo "Test Source: $(IDCODE_TEST_SOURCE)"
	@echo ""
	$(VERILATOR) --cc --exe --build --trace-fst -Wall -Wno-fatal \
		--top-module $(TOP_MODULE) \
		-CFLAGS "-I$(SRC_DIR) -std=c++14" \
		-LDFLAGS "-lpthread" \
		--Mdir $(BUILD_DIR)/idcode_test \
		-o ../test_idcode \
		$(RTL_SOURCES) \
		$(IDCODE_TEST_SOURCE)
	@echo ""
	@echo "IDCODE test build complete: $(IDCODE_TEST)"
	@echo "=========================================="

# Run automated test suite
test: $(VERILATOR_TEST)
	@echo "=========================================="
	@echo "Running automated test suite..."
	@echo "=========================================="
ifeq ($(WAVE),1)
	@echo "Waveform: Enabled (cjtag.fst)"
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
	@echo "Trace saved to: cjtag.fst"

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
	rm -f *.fst *.fst.hier *.vcd *.log
	@$(MAKE) -C fpga clean
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

# Test OpenOCD VPI connection (with verbose output)
test-openocd-verbose:
	@$(MAKE) VERBOSE=1 test-openocd

# Test OpenOCD VPI connection
test-openocd:
	@echo "=========================================="
	@echo "Testing OpenOCD VPI Connection"
	@echo "=========================================="
	@echo "Note: Building with single thread for VPI stability..."
	@$(MAKE) clean > /dev/null 2>&1
	@VERILATOR_THREADS=1 $(MAKE) build > /dev/null 2>&1
	@echo "Cleaning up any existing VPI servers..."
	@pkill -9 Vtop 2>/dev/null || true
	@pkill -9 openocd 2>/dev/null || true
	@sleep 1
	@echo "Starting VPI server in background..."
	@if [ "$(WAVE)" = "1" ]; then \
		echo "Waveform: Enabled (cjtag.fst)"; \
		WAVE=1 $(VERILATOR_EXE) > openocd_test.log 2>&1 & \
		VPI_PID=$$!; \
	else \
		echo "Waveform: Disabled (use WAVE=1 to enable)"; \
		$(VERILATOR_EXE) > openocd_test.log 2>&1 & \
		VPI_PID=$$!; \
	fi; \
	echo "VPI server PID: $$VPI_PID"; \
	echo "Waiting for VPI server to start listening on port $(VPI_PORT)..."; \
	for i in 1 2 3 4 5; do \
		sleep 1; \
		if lsof -i :$(VPI_PORT) > /dev/null 2>&1; then \
			echo "✓ VPI server is listening on port $(VPI_PORT)"; \
			break; \
		fi; \
		if [ $$i -eq 5 ]; then \
			echo "✗ VPI server failed to start"; \
			kill -TERM $$VPI_PID 2>/dev/null || true; \
			sleep 0.5; \
			kill -9 $$VPI_PID 2>/dev/null || true; \
			exit 1; \
		fi; \
	done; \
	echo "Checking if VPI server is running..."; \
	if ps -p $$VPI_PID > /dev/null 2>&1; then \
		echo "✓ VPI server started successfully"; \
		echo "Connecting OpenOCD and running test suite (30 second timeout)..."; \
		if [ "$(VERBOSE)" = "1" ]; then \
			(timeout -s KILL 30 openocd -d3 -f openocd/cjtag.cfg > openocd_output.log 2>&1) & \
		else \
			(timeout -s KILL 30 openocd -f openocd/cjtag.cfg > openocd_output.log 2>&1) & \
		fi; \
		OPENOCD_PID=$$!; \
		echo "OpenOCD PID: $$OPENOCD_PID"; \
		wait $$OPENOCD_PID; \
		EXIT_CODE=$$?; \
		echo "OpenOCD exited with code $$EXIT_CODE"; \
		if [ $$EXIT_CODE -eq 137 ] || [ $$EXIT_CODE -eq 124 ]; then \
			echo "⚠ OpenOCD timed out after 30 seconds"; \
		fi; \
		if grep -q "Can.t connect" openocd_output.log || \
		   grep -q "Connection refused" openocd_output.log; then \
			echo "✗ VPI connection failed"; \
			tail -30 openocd_output.log; \
			RESULT=1; \
		elif grep -q "Connection to.*successful" openocd_output.log && \
		     grep -q "OScan1 protocol initialized" openocd_output.log; then \
			echo "✓ OpenOCD connected and OScan1 initialized"; \
			if grep -q "Test Complete\|Test Suite Summary" openocd_output.log; then \
				echo "✓ OpenOCD test suite completed"; \
				if [ $$EXIT_CODE -eq 0 ]; then \
					if grep -q "IDCODE matches expected value" openocd_output.log; then \
						echo "✅ IDCODE verified (test suite passed): 0x1DEAD3FF"; \
						RESULT=0; \
					else \
						echo "❌ IDCODE verification failed"; \
						tail -20 openocd_output.log | grep -A 5 "IDCODE"; \
						RESULT=1; \
					fi; \
				else \
					echo "❌ OpenOCD returned error code $$EXIT_CODE"; \
					RESULT=1; \
				fi; \
			else \
				echo "⚠ Test did not complete fully"; \
				if [ $$EXIT_CODE -eq 137 ] || [ $$EXIT_CODE -eq 124 ]; then \
					echo "⚠ OpenOCD timed out (expected - known cJTAG bridge limitation)"; \
					echo "  The bridge successfully enters OSCAN1 but may not maintain state"; \
					echo "  during complex JTAG operations (target examination)."; \
				fi; \
				RESULT=1; \
			fi; \
		else \
			echo "✗ Test failed"; \
			tail -30 openocd_output.log; \
			RESULT=1; \
		fi; \
		echo "Stopping VPI server (PID: $$VPI_PID)..."; \
		kill -TERM $$VPI_PID 2>/dev/null && echo "  SIGTERM sent" || echo "  SIGTERM failed"; \
		sleep 1.5; \
		if ps -p $$VPI_PID > /dev/null 2>&1; then \
			echo "Process still running after SIGTERM, sending SIGKILL..."; \
			kill -9 $$VPI_PID 2>/dev/null || true; \
			pkill -9 -f Vtop 2>/dev/null || true; \
			pkill -9 -f verilator 2>/dev/null || true; \
			sleep 0.5; \
		else \
			echo "  Process exited cleanly after SIGTERM"; \
		fi; \
		wait $$VPI_PID 2>/dev/null || true; \
		echo "✓ Waiting for FST file to be written..."; \
		sleep 1; \
		echo "✓ VPI server stopped"; \
		echo ""; \
		echo "========================================"; \
		if [ $$RESULT -eq 0 ]; then \
			echo "✅ OpenOCD Test PASSED"; \
			echo "========================================"; \
			echo "Logs: openocd_test.log, openocd_output.log"; \
			echo ""; \
			sed -n '/##TEST_STATS_BEGIN##/,/##TEST_STATS_END##/p' openocd_output.log | \
				grep -v "##TEST_STATS" || true; \
		else \
			echo "❌ OpenOCD Test FAILED"; \
			echo "========================================"; \
			echo "Check logs: openocd_test.log, openocd_output.log"; \
		fi; \
		exit $$RESULT; \
	else \
		echo "✗ VPI server failed to start"; \
		exit 1; \
	fi

# Test VPI with IDCODE read
test-idcode: $(IDCODE_TEST)
	@echo "=========================================="
	@echo "Testing VPI IDCODE Read"
	@echo "=========================================="
	@echo "Running standalone IDCODE test..."
	@if $(IDCODE_TEST); then \
		echo ""; \
		echo "========================================"; \
		echo "✅ VPI IDCODE Test PASSED"; \
		echo "========================================"; \
		echo "IDCODE: 0x1DEAD3FF verified successfully"; \
		if [ "$(WAVE)" = "1" ]; then \
			echo "Waveform saved to: cjtag.fst"; \
			echo "View with: gtkwave cjtag.fst"; \
		fi; \
	else \
		echo ""; \
		echo "========================================"; \
		echo "❌ VPI IDCODE Test FAILED"; \
		echo "========================================"; \
		if [ "$(WAVE)" = "1" ]; then \
			echo "Check cjtag.fst waveform for details"; \
		fi; \
		exit 1; \
	fi

# FPGA synthesis target
fpga:
	@echo "=========================================="
	@echo "Building FPGA Bitstream for Xilinx XCKU5P"
	@echo "=========================================="
	@$(MAKE) -C fpga all

# =============================================================================
# Phony targets (non-file targets)
# =============================================================================
.PHONY: all build run sim vpi clean help lint wave status test-openocd test-idcode fpga

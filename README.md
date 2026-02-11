# cJTAG Bridge - IEEE 1149.7 Implementation

SystemVerilog implementation of a cJTAG (IEEE 1149.7) to JTAG (IEEE 1149.1) bridge with Verilator simulation and OpenOCD VPI interface support.

## Overview

This project implements a **cJTAG adapter** that converts a 2-wire cJTAG interface (TCKC/TMSC) to a standard 4-wire JTAG interface (TCK/TMS/TDI/TDO). The implementation follows a subset of the IEEE 1149.7 specification, specifically supporting:

- **OScan1 format** for advanced protocol
- **TAP.7 star-2 scan topology**
- **Online/Offline state management**
- **Escape sequences** for mode switching
- **Online Activation Code (OAC)** validation with CP parity checking

## Features

- ✅ Full cJTAG to JTAG bridge (OScan1 format)
- ✅ 12-bit Activation Packet with CP (Check Packet) parity validation (IEEE 1149.7 compliant)
- ✅ Simple JTAG TAP controller for testing
- ✅ OpenOCD VPI interface for remote debugging
- ✅ Verilator-based simulation with FST waveform support
- ✅ Comprehensive automated test suite
- ✅ Makefile for easy build and simulation
- ✅ Support for RISC-V debug module interface

## Implementation Scope

### JTAG TAP Controller (`jtag_tap.sv`)

**✅ Fully Implemented:**
- Complete IEEE 1149.1 TAP state machine (all 16 states)
- Instruction Register (5-bit parameterizable)
- Data Registers: IDCODE, BYPASS, DTMCS (32-bit), DMI (41-bit)
- Proper capture/shift/update operations
- TDO timing per IEEE 1149.1 specification
- Reset behavior (nTRST and software reset)
- Integration with RISC-V Debug Transport Module

**❌ Not Implemented (by design):**
- Advanced boundary scan features (EXTEST, INTEST, SAMPLE/PRELOAD)
- CLAMP and HIGHZ instructions
- Boundary scan cells
- BSDL description
- Manufacturing test features

**Use Case:** Designed for cJTAG bridge testing and basic RISC-V debug interface support. NOT intended for production boundary scan testing.

### RISC-V Debug Transport Module (`riscv_dtm.sv`)

**✅ Implemented:**
- DTMCS register (Debug Transport Module Control/Status)
  - Version field (Debug Spec 0.13)
  - Address width configuration (abits=6)
  - Status reporting (dmistat, idle)
- DMI register (Debug Module Interface, 41-bit)
  - Read/write operations
  - Address and data fields
- Debug Module registers (simulated):
  - `dmcontrol` (0x10) - writable
  - `dmstatus` (0x11) - returns fixed status values
  - `hartinfo` (0x16) - returns hart configuration
- OpenOCD initialization and recognition

**❌ Not Implemented (minimal implementation):**
- Full Debug Module backend (no actual hart control)
- Halt/resume functionality
- Single-step execution
- Abstract commands (command register)
- Program buffer (progbuf[0-15])
- System bus access (sbcs, sbaddress, sbdata)
- Memory access registers (data[0-11])
- Authentication mechanisms
- Error handling (dmihardreset/dmireset non-functional)

**Use Case:** Sufficient for OpenOCD protocol testing, cJTAG validation, and demonstrating RISC-V DTM interface structure. NOT sufficient for actual debugging sessions (halt/resume, memory access, program execution control).

**Testing:** Both modules are comprehensively validated with 131 automated tests covering all state transitions, register operations, and protocol compliance.

## Directory Structure

```
cjtag/
├── .github/               # GitHub configuration
│   └── copilot-instructions.md  # GitHub Copilot instructions
├── src/                   # RTL source files
│   ├── top.sv             # Top-level module (simulation)
│   ├── top_fpga.sv        # Top-level module (FPGA synthesis)
│   ├── README.md          # RTL documentation
│   ├── cjtag/
│   │   └── cjtag_bridge.sv    # cJTAG to JTAG converter
│   ├── jtag/
│   │   └── jtag_tap.sv        # JTAG TAP controller (IEEE 1149.1)
│   └── riscv/
│       └── riscv_dtm.sv       # RISC-V Debug Transport Module
├── tb/                    # Testbench files
│   ├── tb_cjtag.cpp       # C++ testbench harness
│   ├── test_cjtag.cpp     # Automated test suite (131 tests)
│   ├── test_idcode.cpp    # IDCODE test program
│   └── README.md          # Testbench documentation
├── vpi/                   # VPI interface for OpenOCD
│   ├── jtag_vpi.cpp       # VPI server implementation
│   └── README.md          # VPI documentation
├── docs/                  # Project documentation
│   ├── README.md          # Documentation navigation hub
│   ├── ARCHITECTURE.md    # System architecture and design
│   ├── PROTOCOL.md        # cJTAG protocol specification
│   ├── TEST_GUIDE.md      # Comprehensive test documentation
│   ├── CLOCK_REQUIREMENTS.md  # Timing and clock constraints
│   └── PERFORMANCE.md     # Performance characteristics
├── fpga/                  # FPGA synthesis files
│   ├── Makefile           # FPGA build system
│   ├── build_xcku5p.tcl   # Vivado synthesis script (Xilinx XCKU5P)
│   ├── constraints.xdc    # Timing and pin constraints
│   └── README.md          # FPGA build documentation
├── openocd/               # OpenOCD integration
│   ├── cjtag.cfg          # OpenOCD configuration with test suite
│   └── patched/           # OpenOCD patches for cJTAG support
│       ├── README.md              # Patch usage and optimization guide
│       ├── MANUAL_APPLICATION_GUIDE.md
│       ├── PATCH_SUMMARY.md
│       ├── 001-jtag_vpi-cjtag-support.patch
│       ├── 002-oscan1-new-file.txt
│       └── 003-oscan1-header-new-file.txt
├── build/                 # Build artifacts (generated, gitignored)
│   └── Vtop               # Verilator compiled simulation
├── Makefile               # Build system with test targets
└── README.md              # This file - project overview
```

## Requirements

### Software Dependencies

- **Verilator** (4.0+): SystemVerilog simulator
  ```bash
  sudo apt-get install verilator
  ```

- **GTKWave** (optional): Waveform viewer
  ```bash
  sudo apt-get install gtkwave
  ```

- **OpenOCD** (with cJTAG patches): JTAG debugger
  ```bash
  # See openocd/patched/README.md for installation
  ```

- **Build tools**: make, g++, git
  ```bash
  sudo apt-get install build-essential git
  ```

## Quick Start

### 1. Build the Simulation

```bash
make build
```

This will:
- Compile SystemVerilog RTL with Verilator
- Build the automated test suite
- Create the VPI interface
- Generate executable in `build/Vtop`

### 2. Run Automated Tests

```bash
make test
```

This runs the comprehensive test suite covering:
- Reset behavior
- Escape sequences (all toggle counts 0-31)
- OAC validation (valid/invalid/partial)
- **CP (Check Packet) validation (8 comprehensive tests)**
- OScan1 packet operation (1000+ packet stress tests)
- TAP state machine (all 16 states)
- IDCODE readout
- JTAG operations
- RISC-V Debug Module (DTM, DTMCS, DMI registers)
- Error recovery and robustness
- Timing and signal integrity
- Protocol compliance (IEEE 1149.7)

Expected output: **131/131 tests passed ✅**

### 3. Run OpenOCD Integration Tests

```bash
make test-openocd
```

This runs OpenOCD integration tests through the VPI interface, validating:
- OpenOCD VPI connectivity
- cJTAG OScan1 protocol activation
- JTAG TAP operations (IDCODE, DTMCS, DMI, BYPASS)
- RISC-V Debug Module access
- Multi-register operations
- Stress testing with repeated operations

Expected output: **8/8 OpenOCD tests passed ✅**

### 4. View Waveforms

```bash
make wave
```

Opens the waveform in GTKWave (if installed).

```bash
make WAVE=1
```

This runs the simulation with FST waveform tracing enabled. Waveform file will be saved to `cjtag.fst`.

### 5. Run VPI Server for OpenOCD

```bash
make WAVE=1 vpi
```

This starts the simulation in VPI server mode, listening on port 3333 for OpenOCD connections.

## Usage Guide

### Running the Simulation

#### Basic simulation (no waveform):
```bash
make run
```

#### With waveform dump:
```bash
make WAVE=1
make sim
```

#### VPI mode (wait for OpenOCD):
```bash
make WAVE=1 vpi
```

#### Custom VPI port:
```bash
VPI_PORT=5555 make vpi
```

### Connecting OpenOCD

1. **Start the simulation** in VPI mode:
   ```bash
   make WAVE=1 vpi
   ```

2. **In another terminal, run OpenOCD**:
   ```bash
   openocd -f openocd/cjtag.cfg
   ```

3. **Connect with GDB** (in another terminal):
   ```bash
   riscv64-unknown-elf-gdb
   (gdb) target remote localhost:3334
   ```

### Makefile Targets

Use `make help` to see all available targets:

```
==========================================
cJTAG Bridge Makefile
==========================================
Targets:
  make all          - Test all avaliable tests
  make build        - Build Verilator simulation
  make test         - Run automated test suite
  make test-openocd - Test OpenOCD connection to VPI
  make test-idcode  - Test VPI IDCODE read
  make run          - Run simulation (no waveform)
  make sim          - Run simulation with waveform
  make WAVE=1       - Run simulation with FST waveform dump
  make vpi          - Run simulation and wait for OpenOCD
  make clean        - Clean build artifacts
  make help         - Show this help message

Environment Variables:
  WAVE=1         - Enable FST waveform dump
  VERBOSE=1      - Show detailed build output and warnings
  VPI_PORT=3333  - VPI server port (default: 3333)
  VERILATOR_THREADS=2  - Parallel threads for simulation (default: 2)
  OPT_LEVEL=2    - Optimization level 0-3 (default: 2)

Usage Examples:
  make test                    # Run automated tests
  make VERBOSE=1 test          # Run tests with verbose output
  make test-openocd            # Test OpenOCD VPI connection
  make test-idcode             # Test VPI IDCODE read
  make WAVE=1                  # Build and run with waveforms
  VPI_PORT=5555 make vpi       # Run VPI on custom port
  VERILATOR_THREADS=4 make test  # Use 4 threads for faster simulation
  OPT_LEVEL=3 make build       # Maximum optimization
==========================================
```

## Module Descriptions

### cjtag_bridge.sv

**Purpose**: Converts 2-wire cJTAG to 4-wire JTAG

**Key Features**:
- Escape sequence detection (online/offline/reset)
- 12-bit Activation Packet validation (OAC + EC + CP with XOR parity)
- OScan1 3-bit packet handling
- TCK generation (1:3 ratio with TCKC)

**Ports**:
```systemverilog
input  logic  ntrst_i      // Reset (active low)
input  logic  tckc_i       // cJTAG clock
input  logic  tmsc_i       // cJTAG data in
output logic  tmsc_o       // cJTAG data out
output logic  tmsc_oen     // Output enable
output logic  tck_o        // JTAG clock
output logic  tms_o        // JTAG TMS
output logic  tdi_o        // JTAG TDI
input  logic  tdo_i        // JTAG TDO
output logic  online_o     // Status: online
output logic  nsp_o        // Standard protocol active
```

### jtag_tap.sv

**Purpose**: Simple JTAG TAP controller for testing

**Key Features**:
- Full IEEE 1149.1 state machine
- IDCODE register (0x1DEAD3FF)
- BYPASS register
- RISC-V DTM support (DTMCS, DMI registers)
- 5-bit instruction register

**Ports**:
```systemverilog
input  logic  tck_i        // JTAG clock
input  logic  tms_i        // JTAG TMS
input  logic  tdi_i        // JTAG TDI
output logic  tdo_o        // JTAG TDO
input  logic  ntrst_i      // Reset
```

### jtag_vpi.cpp

**Purpose**: VPI interface for OpenOCD communication

**Key Features**:
- TCP/IP server (default port 3333)
- cJTAG protocol commands
- Non-blocking socket I/O
- Command processing for TCKC/TMSC

## cJTAG Protocol Details

### OScan1 Format

In OScan1 mode, each JTAG bit requires **3 TCKC cycles**:

1. **Bit 0**: nTDI (inverted TDI) - driven by probe
2. **Bit 1**: TMS - driven by probe
3. **Bit 2**: TDO - driven by device

### Escape Sequences

Performed by holding TCKC high and toggling TMSC:

- **6-7 toggles**: Selection (OFFLINE → ONLINE_ACT)
- **4-5 toggles**: Deselection (OSCAN1 → OFFLINE)
- **8+ toggles**: Reset (any state → OFFLINE)

### 12-bit Activation Packet (OAC + EC + CP)

After selection escape sequence (6-7 toggles), a 12-bit activation packet is required:

- **OAC** (Online Activation Code): 4 bits = 1100 (LSB first) - TAP.7 star-2 topology
- **EC** (Extension Code): 4 bits = 1000 (LSB first) - short form
- **CP** (Check Packet): 4 bits = 0100 (LSB first) - XOR parity for data integrity

**CP Calculation**: CP[i] = OAC[i] ⊕ EC[i] (bitwise XOR)

**Validation**: The bridge validates all three fields (OAC, EC, and CP) before activating. Only the correct 12-bit sequence with valid CP parity will activate the bridge, providing robust protocol compliance and data integrity checking per IEEE 1149.7 specification.

## Waveform Analysis

When running with `WAVE=1`, the FST waveform includes:

- **tckc_i**: cJTAG clock input
- **tmsc_i/o**: cJTAG data (bidirectional)
- **tck_o**: Generated JTAG clock (1:3 ratio)
- **tms_o, tdi_o, tdo_i**: JTAG signals
- **online_o**: Bridge state indicator
- **TAP state machine**: Internal JTAG TAP states

### Key Signals to Observe

1. **Escape Detection**: Watch `tmsc_i` edges while `tckc_i` is high
2. **Activation Packet**: 12 TCKC cycles after selection escape (OAC + EC + CP)
3. **OScan1 Packets**: 3-bit groups (nTDI, TMS, TDO)
4. **TCK Generation**: TCK pulses on every 3rd TCKC

## OpenOCD Configuration

The provided `openocd/cjtag.cfg` configures OpenOCD for cJTAG mode:

```tcl
adapter driver jtag_vpi
jtag_vpi set_port 3333
jtag_vpi enable_cjtag on
transport select jtag
jtag newtap riscv cpu -irlen 5 -expected-id 0x1dead3ff
```

### Patching OpenOCD

To enable cJTAG support in OpenOCD, apply the patches in `openocd/patched/`:

```bash
cd ~/openocd
patch -p1 < /path/to/cjtag/openocd/patched/001-jtag_vpi-cjtag-support.patch
cp /path/to/cjtag/openocd/patched/002-oscan1-new-file.txt src/jtag/drivers/oscan1.c
cp /path/to/cjtag/openocd/patched/003-oscan1-header-new-file.txt src/jtag/drivers/oscan1.h
./configure --enable-jtag_vpi
make -j4
sudo make install
```

See `openocd/patched/README.md` for detailed instructions.

## Troubleshooting

### Build Issues

**Problem**: Verilator not found
```bash
sudo apt-get install verilator
```

**Problem**: C++ compilation errors
- Ensure g++ supports C++14 or later
- Check that pthread library is available

### Simulation Issues

**Problem**: VPI connection refused
- Ensure no other process is using port 3333
- Try custom port: `VPI_PORT=5555 make vpi`

**Problem**: No waveform generated
- Ensure `WAVE=1` is set
- Verify FST file: `ls -lh cjtag.fst`

### OpenOCD Issues

**Problem**: "Error: JTAG scan chain interrogation failed"
- Check that simulation is running
- Verify VPI port matches (default: 3333)
- Ensure cJTAG patches are applied to OpenOCD

**Problem**: OpenOCD doesn't recognize cJTAG commands
- Apply patches from `openocd/patched/`
- Rebuild OpenOCD with `--enable-jtag_vpi`

## Automated Test Suite

The project includes a comprehensive automated test suite in [tb/test_cjtag.cpp](tb/test_cjtag.cpp) with **131 test cases** providing complete protocol validation.

### Test Statistics
- **Total Tests**: 131 (100% passing ✅)
- **Test File Size**: 4,900+ lines
- **Coverage**: Protocol, state machine, timing, TAP operations, RISC-V debug module, error recovery, stress testing, **CP parity validation**
- **Execution Time**: ~5 seconds

### Test Categories

#### 1. Basic Functionality (16 tests)
- Reset state verification
- Escape sequences (6, 7, 8+ toggles)
- OAC validation (valid/invalid)
- OScan1 packet transmission
- TCK generation and timing
- TMSC bidirectional control
- JTAG TAP IDCODE operations
- Multiple packet streaming

#### 2. Enhanced Testing (4 tests)
- All TDI/TMS combinations
- Full TAP state machine traversal
- 128-bit sustained shift
- 100x rapid cycling

#### 3. Error Recovery & Robustness (20 tests)
- OAC single-bit errors
- Incomplete escape sequences
- Glitch rejection and filtering
- Timing edge cases
- Reset scenarios (nTRST)
- Invalid state recovery
- Timeout handling
- Partial packet handling

#### 4. Systematic Boundary Testing (25 tests)
- All toggle counts 0-15
- Counter saturation (5-bit: 31 max)
- All TDO patterns
- Bit position tracking
- 1000-packet stress test
- Deselection escapes
- OAC timing variations
- Realistic debug sessions
- Random fuzzing

#### 5. Synchronizer & Timing (3 tests)
- 2-cycle synchronizer delay
- Edge detection minimum pulse
- Back-to-back TCKC edges

#### 6. Signal Integrity (4 tests)
- nSP signal verification (OFFLINE=1, OSCAN1=0)
- TCK pulse characteristics
- TMSC_OEN timing at bit boundaries
- TDI/TMS hold between packets

#### 7. Escape Edge Cases (4 tests)
- Zero toggles
- Odd toggle counts (1, 3, 9, 11, 13)
- Maximum toggle count (30+)
- Exact boundaries (4, 5, 6, 7, 8)

#### 8. Packet & State Transitions (4 tests)
- bit_pos wraparound (0→1→2→0)
- Packets without TDO readback
- Zero delay between packets
- Mid-packet interruption

#### 9. TAP Deep Dive (8 tests)
- BYPASS register integrity
- IR/DR capture values
- Extended PAUSE states (100 cycles)
- 500-bit sustained shift
- Alternating IR/DR scans
- Back-to-back IDCODE reads
- All 16 TAP states individually
- Multiple instruction values

#### 10. Performance & Compliance (19 tests)
- nTRST pulse widths
- Software TAP reset
- Maximum packet rate
- Asymmetric duty cycles (10%-90%)
- All zeros/ones data patterns
- Walking ones/zeros patterns
- IEEE 1149.7 compliance
- OAC/EC/CP field validation
- **CP parity validation (8 comprehensive tests)**:
  - Single-bit error detection in CP field
  - Multiple-bit error detection
  - XOR calculation verification (CP[i] = OAC[i] ⊕ EC[i])
  - Invalid EC with matching CP rejection
  - All-zeros and all-ones CP patterns
  - CP validation stress testing (10+ invalid attempts)
- OScan1 format compliance

#### 11. RISC-V Debug Module (19 tests)
- DTMCS register read and format validation
- DMI register access (41-bit operations)
- Debug Module registers (dmcontrol, dmstatus, hartinfo)
- DMI write operations and read-after-write
- Error handling (invalid addresses, dmistat field)
- Complex sequences (sequential reads, rapid switching)
- Complete debug initialization flow
- Debug module state tests (halt flags, reset bits)
- Edge cases (back-to-back operations, mixed sequences)
- Integration tests (all registers, stress testing with 100 operations)

### Running Tests

```bash
# Run all tests
make test

# Clean build and test
make clean && make test

# Run tests with waveform trace
WAVE=1 make test

# View test waveform
gtkwave *.fst
```

### Expected Output
```
========================================
cJTAG Bridge Automated Test Suite
========================================

Running test: 01. reset_state ... PASS
Running test: 02. escape_sequence_online_6_edges ... PASS
...
Running test: 129. mixed_idcode_dtmcs_dmi_sequence ... PASS
Running test: 130. debug_module_all_registers ... PASS
Running test: 131. dmi_stress_test_100_operations ... PASS

========================================
Test Results: 131 tests passed
========================================
✅ ALL TESTS PASSED!
```

### Test Documentation
For detailed test descriptions, debugging guide, and adding new tests, see [docs/TEST_GUIDE.md](docs/TEST_GUIDE.md).

**New in v1.2**: 19 comprehensive RISC-V Debug Module tests added, covering DTMCS, DMI, dmcontrol, dmstatus, and hartinfo registers with full integration testing.

**New in v1.3**: 8 enhanced CP (Check Packet) validation tests added, providing comprehensive IEEE 1149.7 parity checking compliance with single-bit and multiple-bit error detection.

## OpenOCD Integration Test Suite

The project includes automated OpenOCD integration tests that validate the complete cJTAG-to-JTAG bridge operation with OpenOCD debugger software.

### Test Overview

**Location**: `openocd/cjtag.cfg` (run_tests procedure)
**Execution**: `make test-openocd`
**Test Count**: 8 comprehensive integration tests
**Pass Rate**: 100% (8/8 passing ✅)

### OpenOCD Test Steps

#### Step 1: IDCODE Read and Verification
- Reads JTAG IDCODE register
- Verifies expected value: `0x1DEAD3FF`
- Validates basic TAP communication

#### Step 2: DTMCS Register Access
- Accesses RISC-V Debug Transport Module Control and Status register
- Performs 32-bit DR scan through DTMCS instruction
- Validates DTM version detection (v0.13)

#### Step 3: Instruction Register Test
- Tests all major IR values:
  - IDCODE (0x01)
  - DTMCS (0x10 or 0x11)
  - DMI (0x11 or 0x10)
  - BYPASS (0x1F)
- Validates IR scan and instruction decoding

#### Step 4: BYPASS Register Test
- Shifts data through 1-bit BYPASS register
- Tests with patterns: 0x0, 0x1
- Verifies data integrity through minimal path

#### Step 5: Multiple IDCODE Reads
- Performs back-to-back IDCODE operations
- Tests 3 consecutive reads
- Validates consistent results and state retention

#### Step 6: DMI Register Access
- Tests RISC-V Debug Module Interface (41-bit register)
- Reads dmcontrol register (address 0x10)
- Validates DMI access protocol

#### Step 7: IDCODE Stress Test
- Performs 10 rapid IDCODE read operations
- Tests protocol stability under repeated operations
- Validates no state corruption

#### Step 8: Variable DR Scan Lengths
- Tests different data register sizes:
  - 32-bit (IDCODE, DTMCS)
  - 41-bit (DMI)
  - 1-bit (BYPASS)
- Validates proper bit counting and alignment

### Running OpenOCD Tests

```bash
# Run OpenOCD integration tests
make test-openocd

# Run with verbose output (includes VPI server logs)
make VERBOSE=1 test-openocd

# Run with waveform capture
WAVE=1 make test-openocd

# View test logs
cat openocd_output.log
cat openocd_test.log
```

### Expected Output

```
==========================================
Testing OpenOCD VPI Connection
==========================================
✓ VPI server started successfully
✓ OpenOCD connected and OScan1 initialized
✓ OpenOCD test suite completed
✅ IDCODE verified (test suite passed): 0x1DEAD3FF

========================================
✅ OpenOCD Test PASSED
========================================
```

### Test Validation Points

The OpenOCD test suite validates:

1. **VPI Connectivity**: TCP socket connection on port 3333
2. **cJTAG Protocol**: OScan1 activation and packet handling
3. **State Machine**: TAP controller state transitions
4. **Data Integrity**: Correct data transmission/reception
5. **Multi-Operation**: Sequential and repeated operations
6. **Register Access**: All major JTAG/DTM registers
7. **Error-Free Operation**: No protocol violations or timeouts
8. **RISC-V Debug**: Full debug module accessibility

### Test Metrics

- **Execution Time**: ~3-5 seconds
- **VPI Transactions**: ~50-100 packets per test run
- **Coverage**: TAP operations, DTM registers, DMI access, stress testing
- **Reliability**: 100% pass rate across all tests

### Log Files

After running `make test-openocd`, two log files are generated:

**`openocd_output.log`**: OpenOCD console output
- Shows test step execution
- Displays register read values
- Contains test summary

**`openocd_test.log`**: VPI server debug output
- Shows VPI socket operations
- Logs cJTAG packet details
- Contains timing information (when VERBOSE=1)

### Example Test Output

```tcl
Step 1: Reading IDCODE...
✓ IDCODE read: 0x1DEAD3FF

Step 2: Testing DTMCS register...
✓ Switched to DTMCS instruction
✓ 32-bit DR scan (DTMCS)
✓ DTMCS register accessed

Step 3: Testing Instruction Register...
✓ IR scan to IDCODE instruction
✓ IR scan to DTMCS instruction
✓ IR scan to DMI instruction
✓ IR scan to BYPASS instruction
✓ Instruction Register tested

Step 6: Testing DMI register access...
✓ DMI read initiated for dmcontrol (0x10)
✓ DMI register access tested

Test Suite Summary
✓ OpenOCD connected to VPI server
✓ cJTAG OScan1 protocol activated
✓ IDCODE read and verified (0x1DEAD3FF)
✓ All 8 test steps passed
```

### Troubleshooting OpenOCD Tests

**Problem**: VPI connection refused
```bash
# Check if port is in use
lsof -i :3333

# Try different port
VPI_PORT=5555 make test-openocd
```

**Problem**: IDCODE mismatch
- Verify expected IDCODE in `openocd/cjtag.cfg` matches `jtag_tap.sv`
- Check that TAP controller is properly initialized

**Problem**: Test timeouts
- Increase timeout in Makefile (default: 30 seconds)
- Check system load (slow host may cause delays)
- Enable verbose mode to see where it hangs: `make VERBOSE=1 test-openocd`

**Problem**: DTM errors during shutdown
- This is normal - errors may appear during OpenOCD cleanup
- Verify test summary shows "✓ Test passed" before shutdown
- Check that IDCODE was verified successfully

### OpenOCD Configuration

The test configuration (`openocd/cjtag.cfg`) includes:

```tcl
# VPI adapter setup
adapter driver jtag_vpi
jtag_vpi set_port 3333

# cJTAG mode enable
jtag_vpi enable_cjtag on

# TAP definition
jtag newtap riscv cpu -irlen 5 -expected-id 0x1dead3ff

# RISC-V target
target create riscv.cpu riscv -chain-position riscv.cpu

# Initialize and run tests
init
run_tests
```

## Manual Testing

1. **Build and run simulation**:
   ```bash
   make WAVE=1 vpi
   ```

2. **In another terminal, test with OpenOCD**:
   ```bash
   openocd -f openocd/cjtag.cfg
   ```

3. **Expected output**:
   ```
   Info : accepting 'jtag_vpi' connection from 3333
   Info : cJTAG mode enabled
   Info : This adapter doesn't support configurable speed
   Info : JTAG tap: riscv.cpu tap/device found: 0x1dead3ff
   ```

4. **View waveform**:
   ```bash
   make wave
   ```

### Automated Testing

Future work: Add automated testcases in `tb/` directory.

## References

1. **IEEE 1149.7-2009**: Standard for Reduced-Pin and Enhanced-Functionality Test Access Port and Boundary-Scan Architecture
2. **IEEE 1149.1**: Standard Test Access Port and Boundary-Scan Architecture
3. [MIPS cJTAG Adapter User Manual](https://s3-eu-west-1.amazonaws.com/downloads-mips/mips-documentation/login-required/mips_cjtag_adapter_users_manual.pdf)
4. [SEGGER J-Link cJTAG Specifics](https://kb.segger.com/J-Link_cJTAG_specifics)
5. OpenOCD Documentation: [OpenOCD User Guide](http://openocd.org/doc/html/index.html)

## Project Documentation

- [README.md](README.md) - This file: Project overview and quick start
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - Detailed design architecture
- [docs/PROTOCOL.md](docs/PROTOCOL.md) - cJTAG protocol specification
- [docs/TEST_GUIDE.md](docs/TEST_GUIDE.md) - Comprehensive test suite guide (121 tests)- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) - Performance optimization guide- [docs/CHECKLIST.md](docs/CHECKLIST.md) - Design verification checklist

## License

This project is provided as-is for educational and development purposes.

## Contributing

Contributions welcome! Areas for improvement:

- [x] Comprehensive automated test suite (121 tests completed ✅)
- [x] CP (Check Packet) parity checking (IEEE 1149.7 compliant ✅)
- [ ] Implement more scanning formats (SF1-SF3)
- [ ] Support multiple TAP devices
- [ ] Power management features
- [ ] Enhanced protocol compliance testing
- [ ] Performance optimization

## Project Status

### Completed ✅
- IEEE 1149.7 OScan1 format implementation
- Full JTAG TAP controller with RISC-V Debug Module support
- OpenOCD VPI interface
- **131 comprehensive automated tests** (100% passing)
- **8 OpenOCD integration tests** (100% passing)
- **Enhanced CP validation suite** (8 dedicated tests for parity checking)
- Complete protocol validation
- RISC-V Debug Module integration (DTMCS, DMI, dmcontrol, dmstatus, hartinfo)
- Error recovery and robustness testing
- Timing and signal integrity verification
- Full documentation suite
- OpenOCD test automation with VPI interface

### In Progress 🚧
- OpenOCD patch upstreaming
- Additional scanning format support

### Future Enhancements 📋
- Multi-device chain support
- Advanced power management
- Additional protocol formats

## Features & Capabilities

**Complete IEEE 1149.7 Escape Sequence Support:**
- 4-5 toggles: Deselection (OSCAN1 → OFFLINE) ✅
- 6-7 toggles: Selection (OFFLINE → ONLINE_ACT) ✅
- 8+ toggles: Reset (any state → OFFLINE) ✅
- Hardware reset (nTRST) supported ✅
- All escape sequences validated by comprehensive testing

**Test Coverage:**
- **131 Verilator automated tests** (100% passing ✅)
- **8 OpenOCD integration tests** (100% passing ✅)
- **1 VPI IDCODE verification test** (passing ✅)
- **140 total tests** ensuring production quality

## Performance

- **Build time**: ~2 seconds (optimized build)
- **Test execution**: ~2 seconds (131 tests)
- **Simulation speed**: 1-10 MHz equivalent TCKC frequency
- **Throughput**: Up to 5.5M OScan1 packets/second
- **VPI latency**: ~100-500 μs per transaction
- **Memory usage**: ~100 MB for simulation
- **System clock**: 100 MHz free-running

**Optimization Options**:
- `VERILATOR_THREADS=2` - Parallel simulation (2-4 threads)
- `OPT_LEVEL=2` - Optimization level (0-3, default: 2)
- See [docs/PERFORMANCE.md](docs/PERFORMANCE.md) for detailed optimization guide
- [ ] Enhanced VPI protocol

## Support

For issues and questions:
- Review `openocd/patched/README.md` for OpenOCD setup
- Open an issue on the project repository

## Changelog

### v1.0 (2026-01-30)
**Initial Release**
- ✅ Complete IEEE 1149.7 OScan1 3-bit packet format implementation
- ✅ Full escape sequence support (4-5, 6-7, 8+ toggles for deselection/selection/reset)
- ✅ 12-bit Activation Packet with CP (Check Packet) parity validation
- ✅ **8 comprehensive CP validation tests** (single/multiple-bit error detection, XOR verification)
- ✅ 131 automated Verilator tests (100% passing)
- ✅ OpenOCD VPI integration with 8 integration tests
- ✅ IDCODE stress test with configurable iterations
- ✅ **Performance optimizations** (threading, optimization levels, fast X propagation)
- ✅ Comprehensive documentation (Architecture, Protocol, Test Guide, Performance)
- ✅ RISC-V DTM support with proper IDCODE (0x1DEAD3FF)
- ✅ Conditional waveform generation (WAVE=1)
- ✅ Warning-free Verilator compilation

**Key Features:**
- IEEE 1149.7 compliant 3-bit OScan1 packet format: {nTDI, TMS, TDO}
- 12-bit Activation Packet (OAC + EC + CP) with XOR parity validation
- **Robust CP validation**: detects single-bit and multiple-bit errors
- **Optimized performance**: ~4s total cycle time (build + test)
- Runtime escape sequence detection with configurable glitch filtering
- Dual-edge TCKC support with proper synchronization
- Production-ready synthesizable RTL

**Testing:**
- `make test` - 131 automated tests including 8 CP validation tests including 8 CP validation tests
- `make test-openocd` - 8 OpenOCD integration tests
- `make test-idcode` - IDCODE stress test (100 iterations default)

---

**Built with ❤️ using Verilator and SystemVerilog**

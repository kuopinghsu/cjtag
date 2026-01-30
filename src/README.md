# RTL Source Directory

This directory contains the synthesizable RTL (Register Transfer Level) source code for the cJTAG Bridge implementation.

## Directory Structure

```
src/
├── README.md           # This file
├── top.sv             # Top-level module wrapper
├── cjtag/
│   └── cjtag_bridge.sv # cJTAG to JTAG bridge (IEEE 1149.7)
└── jtag/
    └── jtag_tap.sv    # JTAG TAP controller (IEEE 1149.1)
```

## Module Hierarchy

```
top
├── cjtag_bridge (cJTAG to JTAG conversion)
└── jtag_tap (JTAG TAP controller with RISC-V debug support)
```

## Module Descriptions

### top.sv
Top-level wrapper that instantiates and connects the cJTAG bridge and JTAG TAP controller.

**Interfaces:**
- cJTAG interface (TCKC, TMSC bidirectional, nTRST)
- JTAG interface (TCK, TMS, TDI, TDO, nTRST)
- Status signals (online_o, nsp_o)

### cjtag/cjtag_bridge.sv
IEEE 1149.7 cJTAG bridge implementing OScan1 format conversion to standard JTAG.

**Key Features:**
- 4-state FSM: OFFLINE, ESCAPE, ONLINE_ACT, OSCAN1
- Escape sequence detection (6-7 toggles = selection, 8+ = reset)
- Online Activation Code (OAC) validation
- 3-bit OScan1 packet format: nTDI, TMS, TDO
- TCK generation (3 cJTAG clock cycles per JTAG clock)
- Bidirectional TMSC control
- 2-stage synchronizers for metastability protection

**Specifications:**
- MIN_ESC_CYCLES: 20 (minimum TCKC high cycles for escape detection)
- Counter widths: 5-bit (saturate at 31)
- Supported modes: OScan1 (Scan Format 1)

### jtag/jtag_tap.sv
Standard IEEE 1149.1 JTAG TAP controller with RISC-V debug module support.

**Key Features:**
- Complete 16-state TAP state machine
- 5-bit instruction register
- 32-bit data registers (IDCODE, DTMCS, BYPASS)
- 41-bit DMI register (RISC-V Debug Module Interface)
- TDO output with proper timing (valid in SHIFT and EXIT1 states)

**Supported Instructions:**
- IDCODE (0x01): Read device identification
- BYPASS (0x1F): Single-bit bypass
- DTMCS (0x10): RISC-V Debug Transport Module Control/Status
- DMI (0x11): RISC-V Debug Module Interface

**Parameters:**
- IDCODE: 0x1DEAD3FF (default device ID)
- IR_LEN: 5 bits

## Design Constraints

### Synthesizability Requirements
All RTL code must be fully synthesizable:
- ❌ No delays (`#` statements)
- ❌ No `initial` blocks in synthesizable modules
- ❌ No simulation-only constructs
- ✅ Use `always_ff` for sequential logic
- ✅ Use `always_comb` for combinational logic
- ✅ Proper reset handling (async reset, sync release)

### Coding Standards
- **Warning-Free**: Must compile without Verilator warnings
- **Single Clock Domain**: Signals driven from one clock edge only
- **Complete Case Statements**: All case statements must have default
- **Reset All Registers**: All flip-flops must have proper reset
- **Meaningful Names**: Use descriptive signal and variable names
- **Comments**: Document complex state machines and algorithms

## Clock Domains

### System Clock (clk_i)
- **Frequency**: 100 MHz (typical)
- **Usage**: All internal logic, synchronizers, edge detection
- **Free-Running**: Must run continuously for proper operation

### JTAG Clock (tck_o)
- **Generation**: Derived from cJTAG clock (TCKC)
- **Ratio**: 3:1 (3 cJTAG clock cycles per JTAG clock)
- **Edges**: Posedge during OScan1 bit position 2

## Signal Conventions

### Naming
- `_i` suffix: Input signals
- `_o` suffix: Output signals
- `_int` suffix: Internal signals
- `_n` prefix or `_n` suffix: Active-low signals

### Active Levels
- `ntrst_i`: Active-low reset
- `nsp_o`: Active-low standard protocol indicator
- Most other signals: Active-high

## Building and Testing

### Build RTL
```bash
make build
```

### Run Tests
```bash
make test              # 121 Verilator unit/integration tests
make test-idcode       # VPI IDCODE verification test
make test-openocd      # 8 OpenOCD integration tests
```

### Verify Synthesizability
```bash
make clean && make VERBOSE=1
# Should produce zero warnings
```

## Verification

All RTL modules are verified by comprehensive test suites:
- **121 Verilator automated tests** in [tb/test_cjtag.cpp](../tb/test_cjtag.cpp)
- **8 OpenOCD integration tests** via VPI interface
- **1 VPI IDCODE verification test** in [tb/test_idcode.cpp](../tb/test_idcode.cpp)
- **100% pass rate** across all test suites
- **All state transitions** validated
- **Timing characteristics** verified
- **Protocol compliance** confirmed (IEEE 1149.7 & 1149.1)
- **RISC-V Debug Module** integration tested (DTM, DMI, DTMCS)

See [TEST_GUIDE.md](../docs/TEST_GUIDE.md) for complete test documentation.

## Documentation

- [ARCHITECTURE.md](../docs/ARCHITECTURE.md) - Detailed design documentation
- [PROTOCOL.md](../docs/PROTOCOL.md) - cJTAG protocol specification
- [TEST_GUIDE.md](../docs/TEST_GUIDE.md) - Test suite documentation
- [README.md](../README.md) - Project overview

## Features

**Complete IEEE 1149.7 Escape Sequence Support:**
- 4-5 toggles: Deselection (OSCAN1 → OFFLINE) ✅
- 6-7 toggles: Selection (OFFLINE → ONLINE_ACT) ✅
- 8+ toggles: Reset (any state → OFFLINE) ✅
- Hardware reset (nTRST) supported ✅

All escape sequences are fully implemented and validated by 123 comprehensive tests.

2. **OScan1 Only**: Only Scan Format 1 (OScan1) is implemented. OScan2-7 not supported.

3. **No Advanced JTAG**: Basic TAP operations supported. Advanced features (EXTEST, INTEST, etc.) not implemented.

## Contributing

When modifying RTL:
1. Ensure all changes are synthesizable
2. Maintain zero-warning compilation
3. Add/update tests for new features
4. Run full test suite: `make clean && make test`
5. Update documentation as needed

## License

See project root [LICENSE](../LICENSE) file.

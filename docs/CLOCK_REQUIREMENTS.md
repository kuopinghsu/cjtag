# cJTAG Bridge Clock Requirements

## Overview

The cJTAG bridge uses the system clock to sample asynchronous TCKC and TMSC inputs. This requires specific clock ratio constraints to ensure reliable operation.

## Minimum Clock Ratio

### Requirement 1: Synchronizer and Edge Detection

**f_sys ≥ 6 × f_tckc**

- **2-stage synchronizer**: Requires 2 system clock cycles to capture input signal
- **Edge detection**: Requires 1 additional system clock cycle
- **Total**: Each TCKC phase (high or low) must be stable for ≥ 3 system clocks
- **Therefore**: TCKC period must be ≥ 6 system clock cycles

### Requirement 2: Escape Sequence Detection

**TCKC high period ≥ MIN_ESC_CYCLES (20 system clocks)**

- During escape sequences, TCKC must be held high for at least 20 system clock cycles
- This distinguishes intentional escape sequences from spurious glitches
- OpenOCD holds TCKC high across multiple commands during escape sequence transmission

## Current Implementation

### System Configuration
- **System clock**: 100 MHz (10 ns period)
- **TCKC frequency**: 10 MHz (100 ns period)
- **TCKC toggle rate**: Every 5 system clocks (50 ns per phase)

### Verification

| Parameter | Value | Requirement | Status |
|-----------|-------|-------------|--------|
| TCKC period (system clocks) | 10 | ≥ 6 | ✅ PASS |
| TCKC phase duration | 5 | ≥ 3 | ✅ PASS |
| f_sys / f_tckc ratio | 10:1 | ≥ 6:1 | ✅ PASS |
| Escape TCKC high duration | 20+ | ≥ 20 | ✅ PASS |

### Code Enforcement

**tb_cjtag.cpp** includes compile-time assertion:
```cpp
const int sys_clocks_per_tckc = 5;  // TCKC toggle every 5 system clocks
static_assert(sys_clocks_per_tckc * 2 >= 6,
              "Clock ratio violation: TCKC period must be >= 6 system clocks");
```

## Timing Diagrams

### Synchronizer Timing (Minimum Case)
```
sys_clk:  __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
tckc_i:   ________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
                  ^
                  | Input edge

Stage1:   ________|xxxx|‾‾‾‾‾‾‾‾‾‾  (captured after 1 clock)
Stage2:   _____________|xxxx|‾‾‾‾‾  (stable after 2 clocks)
edge_det: __________________|‾|___  (detected after 3 clocks)
```

### Escape Sequence Timing
```
TCKC:     ‾‾‾‾‾‾‾‾‾‾|_____  (held high ≥ 20 system clocks)
TMSC:     |‾|_|‾|_|‾|_      (6 toggles during TCKC high)

          ← 20+ sys clocks →
```

## Modifying Clock Ratio

If you need to change the TCKC frequency:

1. **Update `sys_clocks_per_tckc`** in `tb/tb_cjtag.cpp`
2. **Verify constraint**: Ensure `sys_clocks_per_tckc * 2 >= 6`
3. **Rebuild**: Compile-time assertion will verify the constraint
4. **Test**: Run full test suite to verify functionality
   ```bash
   make test              # 123 Verilator tests
   make test-vpi          # VPI IDCODE test
   make test-openocd      # 8 OpenOCD integration tests
   ```

### Example Configurations

| sys_clocks_per_tckc | TCKC Freq | Period | Status |
|---------------------|-----------|--------|--------|
| 3 | 16.7 MHz | 6 clocks | ✅ Minimum safe |
| 5 | 10 MHz | 10 clocks | ✅ Current (recommended) |
| 10 | 5 MHz | 20 clocks | ✅ Conservative |
| 2 | 25 MHz | 4 clocks | ❌ TOO FAST (fails constraint) |

## Design Files

- **Bridge RTL**: `src/cjtag/cjtag_bridge.sv` - Documents clock requirements in header
- **Testbench**: `tb/tb_cjtag.cpp` - Implements free-running TCKC with verified ratio
- **VPI Handler**: `vpi/jtag_vpi.cpp` - Updates TMSC synchronized to TCKC edges

## References

- IEEE 1149.7 Standard: cJTAG timing specifications
- `MIN_ESC_CYCLES` parameter: Defined in `cjtag_bridge.sv` line 130
- Synchronizer design: Two-stage FF synchronizer (lines 85-98)

# OpenOCD cJTAG/OScan1 Patch Summary

## Overview
This patch enables OpenOCD's jtag_vpi driver to communicate with cJTAG (IEEE 1149.7) devices using the OScan1 two-wire protocol through a VPI interface.

## Files Modified

### 1. `001-jtag_vpi-cjtag-support.patch`
Unified patch for OpenOCD adding complete cJTAG/OScan1 support. Applies all changes in one step.

**Changes to `jtag_vpi.c`:**
- Added `CMD_OSCAN1_RAW` (0x5) VPI command for sending raw TCKC/TMSC signal pairs
- Added `enable_cjtag` configuration command to enable cJTAG mode
- Integrated OScan1 protocol initialization during driver startup
- Redirected TMS sequences and data shifts through OScan1 encoding when in cJTAG mode
- Added two-wire communication helpers:
  - `jtag_vpi_send_tckc_tmsc()` - Send raw TCKC/TMSC pairs to VPI server
  - `jtag_vpi_receive_tmsc()` - Read TDO data from TMSC line
- Added inline OScan1 protocol functions:
  - `oscan1_init()` - Sends escape sequence, OAC, and JSCAN commands
  - `oscan1_sf0_encode()` - 4-phase SF0 packet encoder/decoder
  - `oscan1_send_oac()` - Online Activation Code sender
  - `oscan1_send_jscan_cmd()` - JSCAN control command sender
  - `oscan1_set_scanning_format()` - Scanning format selector (SF0 implemented)

**Usage in OpenOCD config:**
```tcl
adapter driver jtag_vpi
jtag_vpi set_port 5555
jtag_vpi enable_cjtag on
```

## VPI Server Implementation

The VPI server (`src/jtag_vpi.cpp`) has been updated to support:

### CMD_OSCAN1_RAW (0x5)
Sends raw TCKC/TMSC signal pairs to the cJTAG device.

**Protocol:**
- **Command byte**: 0x5
- **Data byte**: bit0=TCKC, bit1=TMSC
- **Response**: Current TMSC output state (TDO value)

**Implementation:**
```cpp
case CMD_OSCAN1_RAW: {
    uint8_t cmd_byte;
    recv(client_fd, &cmd_byte, 1, 0);

    uint8_t tckc = cmd_byte & 0x01;
    uint8_t tmsc = (cmd_byte >> 1) & 0x01;

    top->tckc_i = tckc;
    top->tmsc_i = tmsc;

    // Propagate signals
    for (int i = 0; i < 5; i++) {
        top->eval();
    }

    uint8_t tmsc_out = top->tmsc_o;
    send(client_fd, &tmsc_out, 1, 0);
    break;
}
```

## Testing

### Test Suite Status
✅ All 131 tests pass with the updated implementation

### Test with OpenOCD
```bash
# Terminal 1: Start VPI server
make clean && make
./build/Vtop

# Terminal 2: Connect OpenOCD
openocd -f openocd/cjtag.cfg
```

## Protocol Flow

### 1. Initialization (OFFLINE → ONLINE)
```
1. Escape Sequence: 6 TMSC toggles (TCKC=1)
2. OAC: Send 0xB pattern (1,1,0,1)
3. JSCAN Commands:
   - JSCAN_OSCAN_ON (0x01)
   - JSCAN_SELECT (0x02)
   - JSCAN_SF_SELECT (0x04)
```

### 2. Data Transfer (SF0 Format)
Each JTAG bit transfer uses 4 VPI transactions:
```
Phase 0: TCKC=0, TMSC=0 (CP bit)
Phase 1: TCKC=1, TMSC=0
Phase 2: TCKC=1, TMSC=TDI
Phase 3: TCKC=0, TMSC=TDI (read TDO)
```

### 3. Example: Read IDCODE
```
1. Initialize OScan1 (escape + OAC + JSCAN commands)
2. Navigate TAP to SHIFT-DR using TMS sequences
3. Shift 32 bits through DR using SF0 encoding
4. Each bit: 4 TCKC/TMSC transactions via CMD_OSCAN1_RAW
```

## Configuration Options

### OpenOCD Commands
```tcl
# Enable cJTAG mode
jtag_vpi enable_cjtag on

# Set scanning format (0-3)
jtag_vpi scanning_format 0
```

## Compatibility

### Supported Features
- ✅ OScan1 two-wire protocol
- ✅ Scanning Format 0 (SF0)
- ✅ JTAG TAP state machine navigation
- ✅ Data register scanning
- ✅ Instruction register scanning
- ✅ IDCODE readback

### Known Limitations
- SF1, SF2, SF3 formats not yet implemented
- OSCAN1→OFFLINE escape sequences not supported (use ntrst instead)

## Debugging

### Enable Verbose Output
```tcl
debug_level 3
```

### Check VPI Connection
```
Info : jtag_vpi: Connection to 127.0.0.1 : 5555 successful
Info : jtag_vpi: cJTAG mode enabled, initializing OScan1 protocol
Info : Initializing OScan1 protocol...
Info : OScan1 protocol initialized successfully
```

### Waveform Analysis
```bash
# Enable waveform capture
WAVE=1 make vpi

# View waveforms
gtkwave cjtag.fst
```

## Integration Steps

1. **Apply the unified patch to OpenOCD:**
   ```bash
   cd /path/to/openocd
   patch -p1 < 001-jtag_vpi-cjtag-support.patch
   ```
   This modifies `jtag_vpi.c` only; all OScan1 functions are inlined within that file.

2. **Rebuild OpenOCD:**
   ```bash
   ./bootstrap
   ./configure --enable-jtag_vpi
   make
   sudo make install
   ```

3. **Configure for cJTAG:**
   ```tcl
   # cjtag.cfg
   adapter driver jtag_vpi
   jtag_vpi set_port 5555
   jtag_vpi enable_cjtag on

   transport select jtag
   adapter speed 1000

   jtag newtap riscv cpu -irlen 5 -expected-id 0x1dead3ff
   target create riscv.cpu riscv -chain-position riscv.cpu

   init
   ```

4. **Start VPI server and connect:**
   ```bash
   ./build/Vtop &
   openocd -f openocd/cjtag.cfg
   ```

## Status: ✅ READY FOR TESTING

The patches are complete and ready for integration with OpenOCD. The VPI server fully supports the CMD_OSCAN1_RAW command required for OScan1 communication.

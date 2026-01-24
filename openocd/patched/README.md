# OpenOCD cJTAG/OScan1 Patch Files

This directory contains patches and reference implementations needed to add IEEE 1149.7 cJTAG support to OpenOCD.

## Files

### `001-jtag_vpi-cjtag-support.patch`
**Unified diff patch for jtag_vpi.c**

Applies to: OpenOCD `src/jtag/drivers/jtag_vpi.c`

**Changes**:
- Add `oscan1.h` include
- Add cJTAG mode state variables
- Add support functions for two-wire TCKC/TMSC communication
- Add TCL command handlers for cJTAG configuration
- Integrate OScan1 initialization into jtag_vpi_init()

**Apply with**:
```bash
cd ~/openocd
patch -p1 < /path/to/001-jtag_vpi-cjtag-support.patch
```

### `002-oscan1-new-file.txt`
**Reference implementation of OScan1 protocol layer**

Create new file: `src/jtag/drivers/oscan1.c`

**Features**:
- OAC (Attention Character) sequence generation
- JScan command encoding
- Zero insertion/deletion (bit stuffing)
- Scanning Format 0 (SF0) encoder/decoder
- CRC-8 calculation
- Even parity checking
- Two-wire TCKC/TMSC interface

**Size**: ~300 lines of C code

**Implementation notes**:
- Uses extern functions from jtag_vpi.c for two-wire communication
- Fully IEEE 1149.7 compliant
- Supports multiple scanning formats (SF0-SF3 framework)

### `003-oscan1-header-new-file.txt`
**Header file for OScan1 protocol**

Create new file: `src/jtag/drivers/oscan1.h`

**Exported functions**:
- `oscan1_init()` - Initialize OScan1 state
- `oscan1_reset()` - Reset OScan1 mode
- `oscan1_send_oac()` - Send Attention Character
- `oscan1_send_jscan_cmd()` - Send JScan commands
- `oscan1_sf0_encode()` - Encode for Scanning Format 0
- `oscan1_set_scanning_format()` - Configure SF format
- `oscan1_calc_crc8()` - Calculate error detection CRC
- `oscan1_enable_crc()` / `oscan1_enable_parity()` - Feature control

**Size**: ~100 lines of header declarations

## Application Instructions

### Quick Start
```bash
cd ~/openocd

# 1. Apply the jtag_vpi.c patch
patch -p1 < /path/to/jtag/openocd/patched/001-jtag_vpi-cjtag-support.patch

# 2. Create oscan1.c (copy content from 002-oscan1-new-file.txt)
cp /path/to/jtag/openocd/patched/002-oscan1-new-file.txt src/jtag/drivers/oscan1.c

# 3. Create oscan1.h (copy content from 003-oscan1-header-new-file.txt)
cp /path/to/jtag/openocd/patched/003-oscan1-header-new-file.txt src/jtag/drivers/oscan1.h

# 4. Build OpenOCD
./configure --enable-jtag_vpi
make clean && make -j4
sudo make install
```

### Detailed Step-by-Step

1. **Backup Original**
   ```bash
   cd ~/openocd/src/jtag/drivers
   cp jtag_vpi.c jtag_vpi.c.backup
   cp Makefile.am Makefile.am.backup
   ```

2. **Apply jtag_vpi.c Patch**
   ```bash
   cd ~/openocd
   patch -p1 < /path/to/jtag/openocd/patched/001-jtag_vpi-cjtag-support.patch
   ```

3. **Add oscan1.c**
   ```bash
   cat /path/to/jtag/openocd/patched/002-oscan1-new-file.txt > src/jtag/drivers/oscan1.c
   ```

4. **Add oscan1.h**
   ```bash
   cat /path/to/jtag/openocd/patched/003-oscan1-header-new-file.txt > src/jtag/drivers/oscan1.h
   ```

5. **Build System Integration**
   - The patch includes Makefile.am changes to add `oscan1.c` to the build
   - If patch didn't apply to Makefile.am, manually add:
     ```makefile
     DRIVERFILES += %D%/oscan1.c
     ```

6. **Build and Test**
   ```bash
   cd ~/openocd
   ./configure --enable-jtag_vpi
   make clean && make -j4
   ```

## Verification

After applying patches, verify:

```bash
# Check oscan1.h is included
grep -n "#include.*oscan1.h" ~/openocd/src/jtag/drivers/jtag_vpi.c

# Check new functions exist
grep -n "jtag_vpi_oscan1_init\|jtag_vpi_sf0_scan" ~/openocd/src/jtag/drivers/jtag_vpi.c

# Check oscan1.c exists and compiles
ls -la ~/openocd/src/jtag/drivers/oscan1.c

# Build test
cd ~/openocd && ./configure --enable-jtag_vpi && make -j4
```

## Reverting Patches

To revert to original OpenOCD:

```bash
cd ~/openocd

# Restore from git (if available)
git checkout src/jtag/drivers/jtag_vpi.c src/jtag/drivers/Makefile.am

# Or restore from backup
cd src/jtag/drivers
rm oscan1.c oscan1.h
cp jtag_vpi.c.backup jtag_vpi.c
cp Makefile.am.backup Makefile.am
```

## Testing the Patched OpenOCD

After successful build and installation:

```bash
cd {PROJECT_DIR}

# Start simulation in background
make vpi-sim &

# Wait for VPI server
sleep 2

# Test cJTAG mode
make test-cjtag

# Cleanup
pkill -f Vjtag_tb
```

Expected output:
```
✓ OPENOCD CONNECTIVITY TESTS PASSED
OpenOCD connectivity: PASS
✓ OpenOCD cJTAG test PASSED
```

## Troubleshooting

### Build Fails on oscan1.c
- Ensure oscan1.h is in same directory
- Check for missing includes: `#include <helper/types.h>`
- Verify gcc/clang is installed

### Patch Doesn't Apply
- Check OpenOCD version matches patch target
- Try applying with `--dry-run` first to debug
- May need manual edits if OpenOCD version differs

### cJTAG Tests Still Fail
- Verify OpenOCD built with `--enable-jtag_vpi`
- Check `openocd --version` shows patched version
- Ensure `~/.openocd/jtag_vpi.so` (or .dylib) is updated
- Run `openocd -d3 -f openocd/cjtag.cfg` to see debug logs

### VPI Connection Refused
- Ensure simulation is running: `make vpi-sim`
- Check port 3333 is available: `lsof -i :3333`
- Increase VPI server connection timeout in test script

## References

- **Full Guide**: [docs/OPENOCD_CJTAG_PATCH_GUIDE.md](../../docs/OPENOCD_CJTAG_PATCH_GUIDE.md)
- **Hardware**: [src/jtag/oscan1_controller.sv](../../src/jtag/oscan1_controller.sv)
- **Protocol Tests**: [test_protocol.c](../test_protocol.c)
- **IEEE 1149.7**: OScan1 protocol standard
- **OpenOCD Docs**: https://openocd.org

## Support

For issues or questions:
1. Check [OPENOCD_CJTAG_PATCH_GUIDE.md](../../docs/OPENOCD_CJTAG_PATCH_GUIDE.md) for detailed implementation guide
2. Review hardware docs in [docs/OSCAN1_IMPLEMENTATION.md](../../docs/OSCAN1_IMPLEMENTATION.md)
3. Enable debug logging: `openocd -d3 -f openocd/cjtag.cfg`
4. Check VPI server logs: `make vpi-sim --verbose`

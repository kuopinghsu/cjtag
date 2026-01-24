# Build and Test Checklist

Use this checklist to verify the cJTAG bridge implementation.

## ☐ Prerequisites

- [ ] Verilator installed (`verilator --version`)
- [ ] g++ installed with C++14 support (`g++ --version`)
- [ ] make installed (`make --version`)
- [ ] Optional: GTKWave for waveform viewing (`gtkwave --version`)
- [ ] Optional: OpenOCD with cJTAG patches (`openocd --version`)

**Install missing tools:**
```bash
sudo apt-get install verilator build-essential gtkwave
```

---

## ☐ File Verification

Check all required files exist:

### RTL Source Files
- [ ] `src/cjtag_bridge.sv` - cJTAG to JTAG converter
- [ ] `src/jtag_tap.sv` - JTAG TAP controller
- [ ] `src/top.sv` - Top-level module

### C++ Source Files
- [ ] `src/jtag_vpi.cpp` - VPI interface
- [ ] `tb/tb_cjtag.cpp` - Testbench
- [ ] `tb/test_cjtag.cpp` - Automated test suite

### Build System
- [ ] `Makefile` - Build automation

### Documentation
- [ ] `README.md` - Full documentation
- [ ] `IMPLEMENTATION.md` - Implementation summary
- [ ] `ARCHITECTURE.md` - System architecture

### Configuration
- [ ] `openocd/cjtag.cfg` - OpenOCD config
- [ ] `.gitignore` - Git ignore rules

**Quick check:**
```bash
ls -la src/*.sv src/*.cpp tb/*.cpp Makefile README.md
```

---

## ☐ Automated Test Suite

### Step 1: Run tests
```bash
make test
```

**Expected output:**
```
========================================
cJTAG Bridge Automated Test Suite
========================================

Running test: 01. reset_state ... PASS
Running test: 02. escape_sequence_online_8_edges ... PASS
Running test: 03. oac_validation_valid ... PASS
Running test: 04. oac_validation_invalid ... PASS
Running test: 05. oscan1_packet_transmission ... PASS
Running test: 06. tck_generation ... PASS
Running test: 07. tmsc_bidirectional ... PASS
Running test: 08. jtag_tap_idcode ... PASS
Running test: 09. multiple_oscan1_packets ... PASS
Running test: 10. edge_ambiguity_7_edges ... PASS
Running test: 11. edge_ambiguity_9_edges ... PASS
Running test: 12. ntrst_hardware_reset ... PASS

========================================
Test Results: 12/12 tests passed
========================================
✅ ALL TESTS PASSED!

**Note**: Tests 3, 13-16 are marked as TODO due to OSCAN1→OFFLINE limitation.
See README.md Known Limitations section for details.
```

**Test coverage:**
- [x] Reset behavior
- [x] Escape sequences (OFFLINE→ONLINE)
- [x] OAC validation
- [x] OScan1 packet handling
- [x] TCK generation
- [x] TMSC bidirectional control
- [x] JTAG TAP IDCODE reading
- [x] Edge ambiguity tolerance (online)
- [x] Hardware reset
- [ ] Escape sequences (OSCAN1→OFFLINE) - TODO: See limitation
- [ ] Stress testing - TODO: Requires OSCAN1→OFFLINE support

### Step 2: Run tests with trace
```bash
make test-trace
```

**Expected:** Tests pass and `test_trace.fst` created

### Step 3: View test waveform
```bash
gtkwave test_trace.fst
```

---

## ☐ Build Test

### Step 1: Clean build
```bash
make clean
```
**Expected:** Removes `build/` directories

### Step 2: Build project
```bash
make build
```
**Expected:**
- Creates `build/` directory
- Compiles RTL and C++ code
- Generates `build/Vtop` executable
- No errors

**Common issues:**
- Missing Verilator → `sudo apt install verilator`
- C++ errors → Check g++ version supports C++14
- Missing files → Verify file list above

### Step 3: Verify executable
```bash
ls -lh build/Vtop
```
**Expected:** Executable file ~1-5 MB

---

## ☐ Simulation Test

### Step 1: Run without waveform
```bash
timeout 5s make run || true
```
**Expected:**
- Prints "VPI: Server listening on port 3333"
- Prints "Waiting for OpenOCD connection..."
- Runs until timeout (Ctrl+C to stop manually)

### Step 2: Run with waveform
```bash
timeout 5s make WAVE=1 || true
```
**Expected:**
- Same as above PLUS
- Prints "FST waveform tracing enabled: cjtag.fst"
- Creates `cjtag.fst` file

### Step 3: Verify waveform file
```bash
ls -lh cjtag.fst
```
**Expected:** FST file exists (size depends on simulation time)

---

## ☐ Waveform Verification

### Step 1: View waveform (if GTKWave installed)
```bash
make wave
```
**Expected:** GTKWave opens with `cjtag.fst`

### Step 2: Check signals
In GTKWave, verify these signals exist:
- [ ] `tckc_i` - cJTAG clock
- [ ] `tmsc_i` - cJTAG data in
- [ ] `tmsc_o` - cJTAG data out
- [ ] `tmsc_oen` - Output enable
- [ ] `tck_o` - JTAG clock
- [ ] `tms_o` - JTAG TMS
- [ ] `tdi_o` - JTAG TDI
- [ ] `tdo_i` - JTAG TDO
- [ ] `online_o` - Bridge online status

### Step 3: Initial state verification
At simulation start (time = 0):
- [ ] `online_o` should be LOW (bridge offline)
- [ ] `nsp_o` should be HIGH (standard protocol)

---

## ☐ VPI Server Test

### Step 1: Start VPI server
In **Terminal 1:**
```bash
make WAVE=1 vpi
```
**Expected:**
```
VPI: Server listening on port 3333 (cJTAG mode)
Waiting for OpenOCD connection...
```

### Step 2: Test port connectivity
In **Terminal 2:**
```bash
nc -zv localhost 3333
```
**Expected:** `Connection to localhost 3333 port [tcp/*] succeeded!`

**If port test fails:**
- Check no other process uses port 3333: `lsof -i :3333`
- Try different port: `VPI_PORT=5555 make vpi`

### Step 3: Keep server running
Leave Terminal 1 running for OpenOCD test

---

## ☐ OpenOCD Integration Test

**Prerequisites:** OpenOCD with cJTAG patches installed

### Step 1: Ensure simulation is running
Verify Terminal 1 shows: "Waiting for OpenOCD connection..."

### Step 2: Connect OpenOCD
In **Terminal 2:**
```bash
openocd -f openocd/cjtag.cfg
```

**Expected output:**
```
Info : accepting 'jtag_vpi' connection from 3333
Info : cJTAG mode enabled
Info : JTAG tap: riscv.cpu tap/device found: 0x1dead3ff
```

### Step 3: Verify connection in simulation
Terminal 1 should show: "VPI: Client connected"

### Step 4: Test JTAG scan
In OpenOCD terminal, type:
```tcl
scan_chain
```
**Expected:** Shows IDCODE `0x1dead3ff`

### Step 5: Stop simulation
- Press Ctrl+C in Terminal 1 (simulation)
- Press Ctrl+C in Terminal 2 (OpenOCD)

---

## ☐ Waveform Analysis

After running with OpenOCD, analyze the waveform:

### Step 1: Open waveform
```bash
make wave
```

### Step 2: Locate key events

#### Event 1: Online Escape Sequence
- [ ] Find where `tckc_i` stays HIGH
- [ ] Count `tmsc_i` edges (should be ~8)
- [ ] `online_o` goes HIGH after escape

#### Event 2: Online Activation Code
- [ ] 12 TCKC pulses after escape
- [ ] OAC = 1100, EC = 1000, CP = 0000
- [ ] Bridge enters OSCAN1 state

#### Event 3: OScan1 Packets
- [ ] Every 3 TCKC cycles = 1 JTAG bit
- [ ] `tck_o` pulses on 3rd cycle
- [ ] `tmsc_o` driven during TDO bit

---

## ☐ Clean Test

### Step 1: Clean build
```bash
make clean
```
**Expected:** Removes `build/`

### Step 2: Verify cleanup
```bash
ls build/ 2>/dev/null || echo "Directories removed successfully"
```
**Expected:** "Directories removed successfully"

### Step 3: Rebuild from scratch
```bash
make build
```
**Expected:** Successful rebuild

---

## ☐ Automated Test

Run the automated test script:
```bash
bash tools/test_setup.sh
```
Automated test suite passes (16/16 tests)
2. Build completes without errors
3. Simulation runs and creates VPI server
4. Waveform file is generated with WAVE=1
5. OpenOCD connects and finds IDCODE 0x1dead3ff
6
Next steps:
  1. Run simulation:      make WAVE=1
  2. View waveform:       make wave
  3. Start VPI server:    make WAVE=1 vpi
  4. Connect OpenOCD:     openocd -f openocd/cjtag.cfg
```

---

## Common Issues & Solutions

### Issue: Verilator not found
**Solution:**
```bash
sudo apt-get update
sudo apt-get install verilator
```

### Issue: Build fails with C++ errors
**Solution:**
- Check g++ version: `g++ --version` (need 5.0+)
- Update build-essential: `sudo apt-get install build-essential`

### Issue: VPI port already in use
**Solution:**
```bash
# Find process using port
lsof -i :3333

# Use different port
VPI_PORT=5555 make vpi
```

### Issue: OpenOCD connection fails
**Solution:**
1. Ensure simulation is running first
2. Check OpenOCD has cJTAG patches applied
3. Verify port in openocd/cjtag.cfg matches

### Issue: No waveform generated
**Solution:**
- Make sure to use `WAVE=1`: `make WAVE=1`
- Run for longer time before stopping

### Issue: GTKWave not found
**Solution:**
```bash
sudo apt-get install gtkwave
```

---

## Success Criteria

✅ **All tests pass when:**

1. Build completes without errors
2. Simulation runs and creates VPI server
3. Waveform file is generated with WAVE=1
4. OpenOCD connects and finds IDCODE 0x1dead3ff
5. Waveform shows proper cJTAG protocol sequences

---

## Next Steps After Successful Verification

1. ✅ Read [README.md](README.md) for detailed documentation
2. ✅ Review [ARCHITECTURE.md](ARCHITECTURE.md) for system design
3. ✅ Study waveforms to understand cJTAG protocol
4. ✅ Experiment with OpenOCD commands
5. ✅ Apply OpenOCD patches (see `openocd/patched/README.md`)
6. ✅ Integrate with your target design

---

**Date tested:** _______________

**Tester:** _______________

**Result:** ☐ PASS  ☐ FAIL

**Notes:**
_________________________________________________________________

# GitHub Copilot Instructions for cJTAG Project

## Strict Rules - MUST Follow

### 1. Synthesizable RTL Only
- **ALL** RTL (SystemVerilog/Verilog) code MUST be synthesizable
- Do NOT use delays (`#` statements) in synthesizable modules
- Do NOT use `initial` blocks in synthesizable logic
- Use only synthesizable constructs (always_ff, always_comb, always_latch)
- Avoid non-synthesizable system tasks in production code (use only in testbenches or under `ifdef VERBOSE`)

### 2. Warning-Free Compilation - MANDATORY
- **EVERY** code change MUST compile without warnings
- Before completing any change, ALWAYS run: `make clean && make VERBOSE=1`
- Fix ALL Verilator warnings before submitting code:
  - `CASEINCOMPLETE` - Add default cases to all case statements
  - `MULTIDRIVEN` - Ensure signals are driven from only one clock domain
  - `UNUSEDSIGNAL` - Remove or use all declared signals
  - `UNOPTFLAT` - Fix combinational loops
  - Any other warnings must be resolved

### 3. Debugging Process
- To debug compilation issues: `make clean && make VERBOSE=1`
- To debug test failures: `make VERBOSE=1 test`
- To run specific tests: Use the test framework in `tb/test_cjtag.cpp`
- Check waveforms: Enable with `WAVE=1 make test` and examine generated FST files

## Code Standards

### SystemVerilog Best Practices
- Use `always_ff` for sequential logic (flip-flops)
- Use `always_comb` for combinational logic
- Avoid multiple drivers on any signal
- Ensure all case statements have default cases
- Reset all registers properly in async reset blocks
- Use meaningful signal names
- Add comments for complex state machines

### Clock Domain Rules
- Each signal should be driven from ONE clock domain only
- In dual-edge designs:
  - Clearly separate posedge and negedge logic
  - Do NOT write to the same signal from both edges
  - Document which signals belong to which clock domain

### Testing Requirements
- Run full test suite after changes: `make test`
- Verify with verbose output: `make VERBOSE=1 test`
- Ensure all existing tests still pass
- Add new tests for new features

## File Structure
- **src/** - Synthesizable RTL modules
- **tb/** - Testbench files (can use non-synthesizable constructs)
- **build/** - Generated files (ignored by git)
- **docs/** - Documentation

## Design Limitations

### OSCAN1 to OFFLINE Transition
- **LIMITATION**: OSCAN1→OFFLINE escape sequences are NOT supported
- **Reason**: Bidirectional TMSC conflicts during packet bit 2 (TDO readback)
- **Workaround**: Use hardware reset (`ntrst_i`) to return to OFFLINE state
- **Impact**: Tests 3, 13-16 are marked as TODO (currently disabled)
- **Expected Tests**: 12/12 passing tests (not 16/16)

## Verification Checklist
Before considering any code change complete:
- [ ] Code compiles: `make clean && make VERBOSE=1`
- [ ] Zero warnings in compilation output
- [ ] All tests pass: `make test`
- [ ] Code is synthesizable (no simulation-only constructs in RTL)
- [ ] Proper reset handling for all registers
- [ ] No combinational loops
- [ ] All case statements have default cases
- [ ] Signals driven from single clock domain only

## Common Pitfalls to Avoid
- ❌ Driving same signal from multiple clock domains
- ❌ Incomplete case statements (missing default)
- ❌ Using `initial` blocks in synthesizable modules
- ❌ Delays in RTL code
- ❌ Ignoring compiler warnings
- ❌ Not testing after changes

## Commands Reference
```bash
# Clean build
make clean

# Build with verbose output (shows all warnings)
make VERBOSE=1

# Run tests
make test

# Run tests with verbose output
make VERBOSE=1 test

# Enable waveform generation
WAVE=1 make test

# Complete verification flow
make clean && make VERBOSE=1 && make VERBOSE=1 test
```

---
**Remember: Warning-free, synthesizable code is not optional - it's mandatory for every commit.**

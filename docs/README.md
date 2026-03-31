# cJTAG Bridge Documentation

This directory contains comprehensive documentation for the cJTAG Bridge project, covering architecture, protocols, testing, and verification.

## Documentation Overview

| Document | Description | Key Topics |
|----------|-------------|------------|
| [TEST_GUIDE.md](TEST_GUIDE.md) | Complete test suite guide | 131 tests, coverage analysis, debugging |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System design and architecture | FSM, modules, interfaces, timing |
| [PROTOCOL.md](PROTOCOL.md) | cJTAG protocol specification | IEEE 1149.7, OScan1, escape sequences |

## Quick Navigation

### 🧪 Testing & Verification
**→ [TEST_GUIDE.md](TEST_GUIDE.md)**
- **131 Verilator tests** (100% passing ✅)
- **8 OpenOCD integration tests** (100% passing ✅)
- **VPI IDCODE verification test** (passing ✅)
- Complete test catalog organized in 13 categories
- Coverage analysis (protocol, timing, TAP, error recovery, RISC-V debug)
- Debugging guide and troubleshooting
- Test execution and CI/CD integration
- Performance metrics and best practices

**Test Statistics:**
- Verilator Tests: 131 (unit & integration)
- OpenOCD Tests: 8 (system integration)
- VPI Tests: 1 (IDCODE verification)
- Test File: 5,100+ lines
- Execution Time: ~15 seconds (Verilator), ~3-5 seconds (OpenOCD)
- Pass Rate: 100%

### 🏗️ Architecture & Design
**→ [ARCHITECTURE.md](ARCHITECTURE.md)**
- System architecture overview
- Module descriptions (cjtag_bridge, jtag_tap)
- State machine design (4 main states)
- Signal interfaces and timing
- Clock domain architecture (100MHz system clock)
- Implementation details and design decisions

### 📡 Protocol Specification
**→ [PROTOCOL.md](PROTOCOL.md)**
- IEEE 1149.7 cJTAG protocol
- OScan1 3-bit packet format
- Escape sequences (selection, deselection, reset)
- Online Activation Code (OAC)
- JTAG TAP controller operations
- Timing requirements and constraints

## Project Summary

### Implementation Status

**Completed Features ✅:**
- IEEE 1149.7 OScan1 format implementation
- Full 2-wire to 4-wire bridge (TCKC/TMSC → TCK/TMS/TDI/TDO)
- JTAG TAP controller (all 16 states)
- RISC-V Debug Transport Module (DTM, DMI, DTMCS)
- Escape sequence detection (all toggle counts)
- OAC validation (Online Activation Code)
- OpenOCD VPI interface integration
- **131 Verilator automated tests**
- **8 OpenOCD integration tests**
- **VPI IDCODE verification test**
- Complete protocol validation
- Error recovery and robustness testing
- Timing and signal integrity verification

**Test Coverage:**
- ✅ Protocol compliance (IEEE 1149.7)
- ✅ State machine (all 4 states + transitions)
- ✅ JTAG TAP (all 16 states)
- ✅ Timing & synchronization
- ✅ Signal integrity
- ✅ Error recovery
- ✅ Stress testing (up to 10,000 cycles)
- ✅ Boundary conditions
- ✅ Data patterns

### Key Design Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| System Clock | 100 MHz | Free-running for synchronizers |

| Counter Width | 5 bits | Saturates at 31 |
| TCKC:TCK Ratio | 3:1 | OScan1 packet timing |
| IDCODE | 0x1DEAD3FF | TAP identification |
| OAC Value | 0x0C8 | 12-bit activation code |

### Features

**Complete IEEE 1149.7 Escape Sequence Support:**
- 4-5 toggles: Deselection (OSCAN1 → OFFLINE)
- 6-7 toggles: Selection (OFFLINE → ONLINE_ACT)
- 8+ toggles: Reset (any state → OFFLINE)
- Hardware reset (nTRST) supported
- All escape sequences validated by 131 comprehensive tests

## Getting Started

### 1. Read Core Documentation
Start with the main [README.md](../README.md) for project overview and quick start.

### 2. Understand the Protocol
Review [PROTOCOL.md](PROTOCOL.md) to understand IEEE 1149.7 cJTAG:
- How escape sequences work
- OScan1 packet format (3 bits: nTDI, TMS, TDO)
- Online Activation Code (OAC)
- State transitions

### 3. Study the Architecture
Check [ARCHITECTURE.md](ARCHITECTURE.md) for system design:
- Module hierarchy and interfaces
- State machine operation
- Timing and synchronization
- Signal flow

### 4. Run the Tests
Follow [TEST_GUIDE.md](TEST_GUIDE.md) to validate:
```bash
make test              # 131 Verilator tests
make test-idcode       # VPI IDCODE test
make test-openocd      # 8 OpenOCD integration tests
```
Expected: **131/131 Verilator tests passed ✅**
Expected: **8/8 OpenOCD tests passed ✅**
Expected: **VPI IDCODE test passed ✅**

## Common Use Cases

### For Developers
1. **Adding features**: Check [ARCHITECTURE.md](ARCHITECTURE.md) for design patterns
2. **Writing tests**: See [TEST_GUIDE.md](TEST_GUIDE.md) test templates
3. **Debugging**: Use [TEST_GUIDE.md](TEST_GUIDE.md) debugging guide
4. **Understanding protocol**: Read [PROTOCOL.md](PROTOCOL.md)

### For Verification Engineers
1. **Test coverage**: Review [TEST_GUIDE.md](TEST_GUIDE.md) coverage section
2. **Running tests**: Follow [TEST_GUIDE.md](TEST_GUIDE.md) execution guide
3. **Adding tests**: Use [TEST_GUIDE.md](TEST_GUIDE.md) templates

### For Hardware Engineers
1. **Signal timing**: See [ARCHITECTURE.md](ARCHITECTURE.md) timing section
2. **Interface specs**: Review [PROTOCOL.md](PROTOCOL.md)
3. **State machines**: Check [ARCHITECTURE.md](ARCHITECTURE.md) FSM diagrams
4. **Reset behavior**: See [TEST_GUIDE.md](TEST_GUIDE.md) reset tests

### For Integration
1. **OpenOCD setup**: Main [README.md](../README.md) OpenOCD section
2. **Protocol details**: [PROTOCOL.md](PROTOCOL.md) packet format
3. **Timing requirements**: [ARCHITECTURE.md](ARCHITECTURE.md) constraints
4. **Known limitations**: [TEST_GUIDE.md](TEST_GUIDE.md)

## Documentation Standards

### File Organization
- **Markdown format** for all documentation
- **Clear headings** with hierarchical structure
- **Code examples** with syntax highlighting
- **Tables** for quick reference
- **Links** between related sections

### Content Guidelines
- **Clear and concise** explanations
- **Examples** for complex concepts
- **Diagrams** where helpful (ASCII art or external images)
- **References** to specifications and standards
- **Version information** when relevant

## References

### IEEE Standards
- **IEEE 1149.7-2009**: Reduced-Pin and Enhanced-Functionality Test Access Port
- **IEEE 1149.1-2013**: Standard Test Access Port and Boundary-Scan Architecture

### External Resources
- [Verilator Manual](https://verilator.org/guide/latest/)
- [OpenOCD User Guide](http://openocd.org/doc/html/index.html)
- [GTKWave Documentation](http://gtkwave.sourceforge.net/)

### Project Files
- [Main README](../README.md) - Project overview
- [Source Code](../src/) - SystemVerilog implementation
- [Test Suite](../tb/test_cjtag.cpp) - 131 automated tests
- [Makefile](../Makefile) - Build system

## Contributing to Documentation

### Adding New Documentation
1. Create markdown file in `docs/` directory
2. Follow existing format and style
3. Add entry to this README's table of contents
4. Link from relevant sections
5. Update main [README.md](../README.md) if needed

### Updating Existing Documentation
1. Ensure accuracy with current implementation
2. Update related documents for consistency
3. Add version/date information if significant changes
4. Verify all links still work
5. Run spell check

### Documentation Review Checklist
- [ ] Clear and accurate content
- [ ] Proper markdown formatting
- [ ] Working internal/external links
- [ ] Code examples tested
- [ ] Tables properly formatted
- [ ] Consistent terminology
- [ ] No typos or grammar errors

## Support and Questions

### For Technical Questions
- Review relevant documentation section
- Check [TEST_GUIDE.md](TEST_GUIDE.md) troubleshooting guide
- Examine test cases for examples
- Review source code comments

### For Issues or Bugs
- Run test suite: `make test`
- Enable debug: `WAVE=1 make test`
- Review waveforms: `gtkwave *.fst`

---

**Documentation Version**: 2026.01
**Last Updated**: January 28, 2026
**Project Status**: ✅ Production Ready (131 Verilator + 8 OpenOCD + 1 VPI tests passing)

For the latest information, visit the main [project README](../README.md).

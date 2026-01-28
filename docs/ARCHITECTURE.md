# cJTAG Bridge Architecture

## Overview

This document provides comprehensive technical details of the cJTAG bridge implementation, including system architecture, clock domain design, state machine behavior, protocol flows, and verification procedures.

The cJTAG bridge implements IEEE 1149.7 (Compact JTAG) Class T4, converting a 2-wire cJTAG interface to standard 4-wire JTAG using a system clock-based architecture that enables full escape sequence support.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Host Computer                               │
│                                                                     │
│  ┌──────────────┐         ┌──────────────┐        ┌──────────────┐  │
│  │              │         │              │        │              │  │
│  │     GDB      │◄───────►│   OpenOCD    │◄──────►│  Simulation  │  │
│  │              │  TCP    │              │  VPI   │  (Verilator) │  │
│  │              │ :3334   │              │ :3333  │              │  │
│  └──────────────┘         └──────────────┘        └──────┬───────┘  │
│                                                          │          │
└──────────────────────────────────────────────────────────┼──────────┘
                                                           │
            ┌─────────────────────────────────────────────────────────┐
            │         Verilator Simulation (top.sv)                   │
            │                                                         │
            │  ┌──────────────────────────────────────────────────┐   │
            │  │        cjtag_bridge.sv                           │   │
            │  │  ┌────────────────────────────────────────────┐  │   │
            │  │  │  State Machine                             │  │   │
            │  │  │  - OFFLINE                                 │  │   │
            │  │  │  - ESCAPE (online/offline/reset)           │  │   │
            │  │  │  - ONLINE_ACT (OAC validation)             │  │   │
            │  │  │  - OSCAN1 (active scanning)                │  │   │
            │  │  └────────────────────────────────────────────┘  │   │
            │  │                                                  │   │
            │  │  2-Wire cJTAG Interface                          │   │
            │  │  ┌─────┐  ┌─────┐                                │   │
            │  │  │TCKC │  │TMSC │  (bidirectional)               │   │
            │  │  └──┬──┘  └──┬──┘                                │   │
            │  │     │        │                                   │   │
            │  │  ┌──────────────────────┐                        │   │
            │  │  │  OScan1 Protocol     │                        │   │
            │  │  │  ┌────┬────┬────┐    │                        │   │
            │  │  │  │nTDI│TMS │TDO │    │  3-bit packets         │   │
            │  │  │  └────┴────┴────┘    │                        │   │
            │  │  └──────────────────────┘                        │   │
            │  │     │        │        │                          │   │
            │  │  ┌──────────────────────┐                        │   │
            │  │  │  4-Wire JTAG Output  │                        │   │
            │  │  │  TCK, TMS, TDI, TDO  │                        │   │
            │  │  └──────────┬───────────┘                        │   │
            │  └─────────────┼────────────────────────────────────┘   │
            │                │                                        │
            │  ┌──────────────────────────────────────────────────┐   │
            │  │        jtag_tap.sv (Test Target)                 │   │
            │  │  ┌────────────────────────────────────────────┐  │   │
            │  │  │  TAP Controller State Machine              │  │   │
            │  │  │  ┌──────────────┬───────────────┐          │  │   │
            │  │  │  │ IR: IDCODE   │ DR: 0x1DEAD3FF│          │  │   │
            │  │  │  │    BYPASS    │     BYPASS    │          │  │   │
            │  │  │  │    DTMCS     │     DTMCS     │          │  │   │
            │  │  │  │    DMI       │     DMI       │          │  │   │
            │  │  │  └──────────────┴───────────────┘          │  │   │
            │  │  └────────────────────────────────────────────┘  │   │
            │  └──────────────────────────────────────────────────┘   │
            └─────────────────────────────────────────────────────────┘
```

---

## Clock Architecture

### System Clock Design

The cJTAG bridge uses a **system clock-based architecture** to enable proper escape sequence detection per IEEE 1149.7.

```
┌─────────────────┐
│  System Clock   │  100 MHz (synthesizable)
│    (clk_i)      │  - Primary clock for all logic
└────────┬────────┘  - Samples async inputs
         │           - Detects edges
         ▼           - Generates outputs
┌─────────────────┐
│  Synchronizers  │  2-stage metastability protection
│    (2-FF)       │  - tckc_i → tckc_sync[1:0] → tckc_s
└────────┬────────┘  - tmsc_i → tmsc_sync[1:0] → tmsc_s
         │
┌─────────────────┐
│  Edge Detectors │  Detect transitions
│                 │  - tckc_posedge, tckc_negedge
└────────┬────────┘  - tmsc_edge
         │
┌─────────────────┐
│ Escape Detector │  Monitors TCKC high + TMSC toggles
│                 │  - Counts tmsc_toggle_count
└────────┬────────┘  - Evaluates on tckc_negedge
         │
┌─────────────────┐
│  State Machine  │  Processes protocol states
│                 │  - OFFLINE, ONLINE_ACT, OSCAN1
└────────┬────────┘  - React to escape sequences
         │
┌─────────────────┐
│ Output Logic    │  Generates JTAG signals
│                 │  - tck_o, tms_o, tdi_o
└─────────────────┘  - Controls tmsc_oen
```

### Clock Frequencies

| Clock | Frequency | Period | Purpose |
|-------|-----------|--------|---------|
| `clk_i` | 100 MHz | 10 ns | System clock (all internal logic) |
| `tckc_i` | ~10 MHz | ~100 ns | External cJTAG clock (async input) |
| `tck_o` | ~3.33 MHz | ~300 ns | Internal JTAG clock (3:1 ratio) |

### Key Features

1. **Asynchronous Input Sampling**
   - TCKC and TMSC are external async signals
   - 2-stage synchronizers eliminate metastability
   - System clock samples at 100 MHz (10× oversampling minimum)

2. **Edge Detection**
   - Detects TCKC rising/falling edges
   - Detects TMSC transitions
   - All detection happens in system clock domain

3. **Escape Sequence Detection**
   ```systemverilog
   // When TCKC goes high
   - Set tckc_is_high flag
   - Reset tmsc_toggle_count

   // While TCKC stays high (MIN_ESC_CYCLES = 20)
   - Count TMSC edges
   - Increment tckc_high_cycles

   // When TCKC goes low (if tckc_high_cycles >= MIN_ESC_CYCLES)
   - Evaluate tmsc_toggle_count:
     * 6-7:  Selection (activate → ONLINE_ACT)
     * 8+:   Reset to OFFLINE
   ```

4. **Robust Synchronization**
   - Synchronizers add 2 system clock cycles latency (~20 ns)
   - Total detection latency: ~20-30 ns (acceptable for debug)
   - No metastability issues
   - Reliable at any TCKC frequency (up to ~30 MHz)

### Design Rationale

**Why System Clock?**

Using TCKC as the clock source made escape sequence detection impossible because:
- Escape sequences require detecting "TCKC held high + TMSC toggling"
- When TCKC is the clock, no edges occur when TCKC is held static
- Cannot detect TMSC transitions without clock edges

**Solution Benefits:**
- ✅ Full IEEE 1149.7 compliance
- ✅ All escape sequences supported (selection, deselection, reset)
- ✅ OSCAN1 → OFFLINE transitions work
- ✅ Single clock domain (synthesizable)
- ✅ Better testability

---

## State Machine

### States

The cJTAG bridge operates in four primary states:

| State | Description | Entry Condition | Exit Condition |
|-------|-------------|-----------------|----------------|
| **OFFLINE** | Reset/idle state, cJTAG inactive | Power-on, nTRST, reset escape | 6-7 toggle escape |
| **ONLINE_ACT** | Receiving activation code | 6-7 toggle escape from OFFLINE | Valid OAC → OSCAN1<br>Invalid OAC → OFFLINE |
| **OSCAN1** | Active scanning mode | Valid OAC (12 bits) | 8+ toggle escape, nTRST |

### State Transition Diagram

```
                     ┌─────────────┐
                     │   OFFLINE   │◄─── Power-on / nTRST
                     └──────┬──────┘
                            │ 6-7 TMSC toggles
                            │ (TCKC high ≥ MIN_ESC_CYCLES)
                            ▼
                     ┌─────────────┐
                     │ ONLINE_ACT  │
                     └──────┬──────┘
                            │ 12 bits OAC
                            │ Valid: 0000_1000_1100
                            ▼
                     ┌─────────────┐
           ┌────────►│   OSCAN1    │
           │         └──────┬──────┘
           │                │ 8+ toggles OR nTRST
           │                ▼
           │         ┌─────────────┐
           └─────────┤   OFFLINE   │
      3-bit packets  └─────────────┘
```

### Escape Sequences

Escape sequences are detected by monitoring TCKC and TMSC:

| TMSC Toggles | TCKC State | Function | State Transition |
|--------------|------------|----------|------------------|
| 6-7 | High ≥ MIN_ESC_CYCLES | **Selection** | OFFLINE → ONLINE_ACT |
| 8+ | High ≥ MIN_ESC_CYCLES | **Reset** | Any → OFFLINE |

**MIN_ESC_CYCLES**: 20 system clock cycles minimum. This threshold prevents false escape detection during normal TCKC toggling.

---

## Protocol Flow

### 1. Escape Sequence (Selection - Go Online)

6 TMSC edges (or 7 for tolerance) while TCKC held high transitions from OFFLINE → ONLINE_ACT.

```wavedrom
{
  "signal": [
    {"name": "TCKC", "wave": "1...............0"},
    {"name": "TMSC", "wave": "010101010101....."},
    {},
    {"name": "tckc_high_cycles", "wave": "x2............3..", "data": ["≥20", "≥20"]},
    {"name": "tmsc_toggle_count", "wave": "x2.3.4.5.6.7.....", "data": ["1", "2", "3", "4", "5", "6"]},
    {},
    {"name": "State", "wave": "2...............3", "data": ["OFFLINE", "ONLINE_ACT"]}
  ],
  "config": {"hscale": 2},
  "head": {"text": "Selection Escape: 6 TMSC Toggles (TCKC high ≥ MIN_ESC_CYCLES)"}
}
```

### 2. Online Activation Code (OAC + EC + CP)

12-bit sequence: OAC (4 bits) + EC (4 bits) + CP (4 bits) transmitted LSB first, sampled on TCKC negedge.

```wavedrom
{
  "signal": [
    {"name": "TCKC", "wave": "n........................."},
    {"name": "TMSC", "wave": "x0.0.1.1.0.0.0.1.0.0.0.0.x"},
    {},
    {"name": "Field", "wave": "x2.......3.......4.......x", "data": ["OAC=1100", "EC=1000", "CP=0000"]},
    {"name": "Bit Count", "wave": "x2.3.4.5.6.7.8.9.=.=.=.=.x", "data": ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"]},
    {},
    {"name": "State", "wave": "2........................3", "data": ["ONLINE_ACT", "OSCAN1"]}
  ],
  "config": {"hscale": 2},
  "head": {"text": "Activation: OAC=1100 + EC=1000 + CP=0000 (LSB first, negedge sample)"}
}
```

- **OAC**: `1100` (LSB first) = `0011` (MSB first) = TAP.7 star-2 format
- **EC**: `1000` (LSB first) = `0001` (MSB first) = Short form, RTI state
- **CP**: `0000` = Check packet (all zeros)
- **Combined**: `0000_1000_1100` in shift register after 12 bits
- **Result**: Valid code → State transitions to OSCAN1

### 3. OScan1 3-Bit Scan Packets

Each packet contains 3 bits transmitted over 3 TCKC cycles. TCK pulses on TCKC posedge during bit 2. TMSC is sampled on negedge, outputs update on posedge.

```wavedrom
{
  "signal": [
    {"name": "TCKC", "wave": "n...n...n...n...n...n..."},
    {"name": "bit_pos", "wave": "x2...3...4...2...3...4..", "data": ["0", "1", "2", "0", "1", "2"]},
    {},
    {"name": "TMSC (in)", "wave": "x3...4...x...3...4...x..", "data": ["nTDI", "TMS", "nTDI", "TMS"]},
    {"name": "TMSC (out)", "wave": "x........z.......z......", "data": ["TDO", "TDO"]},
    {"name": "TMSC_OEN", "wave": "1........0...1...0...1.."},
    {},
    {"name": "TDI_O", "wave": "x....3...........4......", "data": ["TDI", "TDI"]},
    {"name": "TMS_O", "wave": "x........3...........4..", "data": ["TMS", "TMS"]},
    {"name": "TCK_O", "wave": "0........1.0.........1.0"},
    {"name": "TDO_I", "wave": "x........5...........6..", "data": ["TDO", "TDO"]}
  ],
  "config": {"hscale": 2},
  "head": {"text": "OScan1: negedge sample → posedge update → TCK pulse on bit 2"}
}
```

**Timing Sequence:**
- **TCKC negedge**: Sample TMSC (nTDI, TMS, or ignore for TDO), advance bit_pos
- **TCKC posedge**: Update outputs based on bit_pos:
  - Bit 0: Keep TMSC_OEN=1 (input mode)
  - Bit 1: Update TDI_O (inverted from sampled nTDI), TMSC_OEN=1
  - Bit 2: Update TMS_O, assert TCK_O=1, set TMSC_OEN=0 (output TDO)
- **TCKC negedge** (bit 2→0): Clear TCK_O=0, advance to next packet

**Key Details:**
- **nTDI**: Inverted TDI from probe (increases transition density)
- **TMS**: Test Mode Select from probe
- **TDO**: Device output driven during bit 2 (TMSC_OEN=0)
- **TCK**: Pulses high only during bit 2 (3:1 clock ratio)

## VPI Communication Protocol

```
┌──────────────┐                    ┌──────────────┐
│   OpenOCD    │                    │  Simulation  │
│  (Client)    │                    │   (Server)   │
└──────┬───────┘                    └──────┬───────┘
       │                                   │
       │  TCP Connection :3333             │
       ├──────────────────────────────────►│
       │                                   │
       │  CMD_CJTAG_TCKC (0x10) + state    │
       ├──────────────────────────────────►│
       │                                   │
       │  CMD_CJTAG_WRITE (0x11) + data    │
       ├──────────────────────────────────►│
       │                                   │
       │  CMD_CJTAG_READ (0x12)            │
       ├──────────────────────────────────►│
       │                                   │
       │  ◄─ TMSC data byte                │
       │◄──────────────────────────────────┤
       │                                   │
       │  CMD_RESET (0x00)                 │
       ├──────────────────────────────────►│
       │                                   │
       │  ◄─ Response                      │
       │◄──────────────────────────────────┤
       │                                   │
```

## Timing Relationships

### cJTAG to JTAG Clock Ratio (3:1)

TCK pulses once every 3 TCKC cycles during OScan1 operation. TCK goes high on TCKC posedge when bit_pos=2, and goes low on the following TCKC negedge.

```wavedrom
{
  "signal": [
    {"name": "TCKC", "wave": "n...n...n...n...n...n..."},
    {"name": "bit_pos", "wave": "x2...3...4...2...3...4..", "data": ["0", "1", "2", "0", "1", "2"]},
    {},
    {"name": "TCK", "wave": "0........1.0.........1.0"},
    {"name": "Packet", "wave": "x2...............3......", "data": ["Packet 0", "Packet 1"]}
  ],
  "config": {"hscale": 2},
  "head": {"text": "Clock Ratio: 3 TCKC cycles = 1 JTAG bit (TCK pulse on bit 2)"}
}
```

**Ratio**: 3 TCKC cycles = 1 JTAG bit transfer
- TCK pulses high on TCKC posedge during bit_pos=2
- TCK returns low on TCKC negedge (bit_pos transitions 2→0)
- Effective JTAG clock = TCKC frequency ÷ 3

## State Transitions

```
                     ┌─────────────┐
                     │   OFFLINE   │◄─── Power-on / nTRST
                     └──────┬──────┘
                            │ 6-7 TMSC toggles
                            │ (TCKC high ≥ MIN_ESC_CYCLES)
                            │ Detected on TCKC negedge
                            ▼
                     ┌─────────────┐
                     │ ONLINE_ACT  │
                     └──────┬──────┘
                            │ 12 bits OAC on TCKC negedge
                            │ Valid: 0000_1000_1100
                            │ Invalid → OFFLINE
                            ▼
                     ┌─────────────┐
           ┌────────►│   OSCAN1    │◄───────┐
           │         └──────┬──────┘        │
           │                │               │
           │                │ 8+ toggles    │ 3-bit
           │                │ OR nTRST      │ packets
           │                ▼               │
           │         ┌─────────────┐        │
           └─────────┤   OFFLINE   │────────┘
                     └─────────────┘

**State Details:**
- **OFFLINE**: Default state, cJTAG inactive, JTAG signals idle
- **ONLINE_ACT**: Receiving 12-bit activation code (OAC+EC+CP)
- **OSCAN1**: Active scanning, processing 3-bit packets (nTDI, TMS, TDO)

**Escape Sequences:**
- **6-7 toggles** (TCKC high ≥ MIN_ESC_CYCLES=20): Selection → ONLINE_ACT
- **8+ toggles** (TCKC high ≥ MIN_ESC_CYCLES=20): Reset → OFFLINE
- **Hardware reset** (nTRST assertion): Immediate → OFFLINE from any state
```

## Waveform Signals to Observe

When viewing FST waveforms (`cjtag.fst`):

| Signal | Description | Key Events |
|--------|-------------|------------|
| `clk_i` | System clock | 100 MHz, always running |
| `tckc_i` | cJTAG clock input | Held high during escape sequences |
| `tckc_s` | Synchronized TCKC | After 2-stage synchronizer |
| `tckc_posedge` | TCKC rising edge | Triggers output updates |
| `tckc_negedge` | TCKC falling edge | Triggers state transitions, samples TMSC |
| `tmsc_i` | cJTAG data input | Toggles during escape, carries nTDI/TMS |
| `tmsc_s` | Synchronized TMSC | After 2-stage synchronizer |
| `tmsc_edge` | TMSC transition | Increments toggle counter |
| `tmsc_toggle_count` | Toggle counter | 6-7 = selection, 8+ = reset |
| `tckc_high_cycles` | TCKC high duration | Must be ≥20 for valid escape |
| `tmsc_o` | cJTAG data output | Drives TDO during bit_pos=2 |
| `tmsc_oen` | Output enable | 0=output, 1=input |
| `state` | State machine | OFFLINE(0), ONLINE_ACT(2), OSCAN1(3) |
| `bit_pos` | Packet bit position | 0=nTDI, 1=TMS, 2=TDO |
| `online_o` | Status output | High when in OSCAN1 state |
| `tck_o` | JTAG clock output | Pulses during bit_pos=2 |
| `tms_o` | JTAG TMS output | From TMSC bit 1 (updated on posedge) |
| `tdi_o` | JTAG TDI output | Inverted from TMSC bit 0 |
| `tdo_i` | JTAG TDO input | From TAP, sent to TMSC during bit 2 |

## File Interaction Flow

```
User Command: make WAVE=1
         │
    ┌─────────┐
    │Makefile │
    └────┬────┘
         │ verilator --build
         ▼
    ┌─────────────────────┐
    │ Verilator Compiler  │
    └────┬────────────┬───┘
         │            │
    ┌────────┐   ┌────────┐
    │ RTL SV │   │C++ TB  │
    └────┬───┘   └───┬────┘
         │           │
         └─────┬─────┘
               ▼
         ┌───────────┐
         │ Vtop.exe  │
         └─────┬─────┘
               │ WAVE=1
               ▼
         ┌───────────┐
         │ VPI Port  │  :3333
         │  Server   │◄───── OpenOCD
         └─────┬─────┘
               │
         ┌───────────┐
         │ cjtag.fst │ ──► GTKWave
         └───────────┘
```

**Use this diagram to understand how all components work together!**

---

## Module Interfaces

### cjtag_bridge.sv

```systemverilog
module cjtag_bridge (
    // System Clock
    input  logic        clk_i,          // 100 MHz system clock
    input  logic        ntrst_i,        // Reset (active low)

    // cJTAG Interface (2-wire, async inputs)
    input  logic        tckc_i,         // cJTAG clock from probe
    input  logic        tmsc_i,         // cJTAG data/control in
    output logic        tmsc_o,         // cJTAG data out
    output logic        tmsc_oen,       // Output enable (0=output, 1=input)

    // JTAG Interface (4-wire, generated outputs)
    output logic        tck_o,          // JTAG clock to TAP
    output logic        tms_o,          // JTAG TMS to TAP
    output logic        tdi_o,          // JTAG TDI to TAP
    input  logic        tdo_i,          // JTAG TDO from TAP

    // Status
    output logic        online_o,       // 1=OSCAN1 active, 0=offline
    output logic        nsp_o           // Standard Protocol indicator
);
```

### Key Signals

| Signal | Direction | Domain | Description |
|--------|-----------|--------|-------------|
| `clk_i` | Input | System | 100 MHz system clock for all logic |
| `ntrst_i` | Input | Async | Active-low reset |
| `tckc_i` | Input | Async | External cJTAG clock (sampled by clk_i) |
| `tmsc_i` | Input | Async | Bidirectional cJTAG data (sampled by clk_i) |
| `tmsc_o` | Output | System | Drives TDO during bit 2 of OSCAN1 |
| `tmsc_oen` | Output | System | Controls bidirectional buffer (0=output) |
| `tck_o` | Output | System | Generated JTAG clock (pulses on TCKC posedge, bit 2) |
| `tms_o` | Output | System | JTAG TMS (from TMSC bit 1) |
| `tdi_o` | Output | System | JTAG TDI (inverted from TMSC bit 0) |
| `tdo_i` | Input | System | JTAG TDO (to TMSC bit 2) |
| `online_o` | Output | System | High when state == OSCAN1 |
| `nsp_o` | Output | System | Standard Protocol active (inverse of online_o) |

---

## Implementation Details

### Input Synchronization

```systemverilog
// 2-stage synchronizer for metastability protection
logic [1:0]  tckc_sync;
logic [1:0]  tmsc_sync;

/* verilator lint_off SYNCASYNCNET */
always_ff @(posedge clk_i or negedge ntrst_i) begin
    if (!ntrst_i) begin
        tckc_sync <= 2'b00;
        tmsc_sync <= 2'b00;
    end else begin
        tckc_sync <= {tckc_sync[0], tckc_i};
        tmsc_sync <= {tmsc_sync[0], tmsc_i};
    end
end
/* verilator lint_on SYNCASYNCNET */

assign tckc_s = tckc_sync[1];
assign tmsc_s = tmsc_sync[1];
```

### Edge Detection

```systemverilog
always_ff @(posedge clk_i or negedge ntrst_i) begin
    if (!ntrst_i) begin
        tckc_prev <= 1'b0;
        tmsc_prev <= 1'b0;
        tckc_posedge <= 1'b0;
        tckc_negedge <= 1'b0;
        tmsc_edge <= 1'b0;
    end else begin
        tckc_prev <= tckc_s;
        tmsc_prev <= tmsc_s;

        // Detect TCKC edges
        tckc_posedge <= (!tckc_prev && tckc_s);
        tckc_negedge <= (tckc_prev && !tckc_s);

        // Detect TMSC edge
        tmsc_edge <= (tmsc_prev != tmsc_s);
    end
end
```

### Escape Sequence Detection

```systemverilog
localparam MIN_ESC_CYCLES = 20;  // Minimum cycles TCKC must be high

always_ff @(posedge clk_i or negedge ntrst_i) begin
    if (!ntrst_i) begin
        tckc_is_high <= 1'b0;
        tckc_high_cycles <= 4'd0;
        tmsc_toggle_count <= 5'd0;
    end else begin
        // Track when TCKC goes high
        if (tckc_posedge) begin
            tckc_is_high <= 1'b1;
            tckc_high_cycles <= 4'd1;
            tmsc_toggle_count <= 5'd0;
        end
        // Track TCKC going low
        else if (tckc_negedge) begin
            tckc_is_high <= 1'b0;
            tckc_high_cycles <= 4'd0;
        end
        // TCKC held high - count TMSC toggles
        else if (tckc_is_high && tckc_s) begin
            if (tckc_high_cycles < 4'd15) begin
                tckc_high_cycles <= tckc_high_cycles + 4'd1;
            end

            if (tmsc_edge) begin
                tmsc_toggle_count <= tmsc_toggle_count + 5'd1;
            end
        end
    end
end
```

### State Machine Logic

State transitions occur on TCKC negedge (after sampling):

```systemverilog
always_ff @(posedge clk_i or negedge ntrst_i) begin
    case (state)
        ST_OFFLINE: begin
            // Detect selection escape (6-7 toggles, TCKC high long enough)
            if (tckc_negedge && tckc_high_cycles >= MIN_ESC_CYCLES[3:0]) begin
                if (tmsc_toggle_count >= 5'd6 && tmsc_toggle_count <= 5'd7) begin
                    state <= ST_ONLINE_ACT;
                end
            end
        end

        ST_ONLINE_ACT: begin
            // Receive 12-bit OAC on TCKC edges
            if (tckc_negedge) begin
                oac_shift <= {tmsc_s, oac_shift[10:1]};

                if (oac_count == 4'd11) begin
                    if ({tmsc_s, oac_shift[10:0]} == 12'b0000_1000_1100) begin
                        state <= ST_OSCAN1;
                    end else begin
                        state <= ST_OFFLINE;  // Invalid OAC
                    end
                end
            end
        end

        ST_OSCAN1: begin
            // Check for reset escape (8+ toggles)
            if (tckc_negedge && tckc_high_cycles >= MIN_ESC_CYCLES[3:0]) begin
                if (tmsc_toggle_count >= 5'd8) begin
                    state <= ST_OFFLINE;
                end
            end
            // Normal packet operation
            else if (tckc_negedge) begin
                tmsc_sampled <= tmsc_s;
                bit_pos <= (bit_pos == 2'd2) ? 2'd0 : bit_pos + 2'd1;
            end
        end
    endcase
end
```

### Output Generation

Outputs update on TCKC edges:

```systemverilog
always_ff @(posedge clk_i or negedge ntrst_i) begin
    case (state)
        ST_OSCAN1: begin
            if (tckc_posedge) begin
                case (bit_pos)
                    2'd1: begin
                        tdi_int <= ~tmsc_sampled;  // Inverted TDI
                        tmsc_oen_int <= 1'b1;      // Input for TMS
                    end

                    2'd2: begin
                        tms_int <= tmsc_sampled;   // TMS
                        tck_int <= 1'b1;           // TCK pulse
                        tmsc_oen_int <= 1'b0;      // Output for TDO
                    end
                endcase
            end

            if (tckc_negedge && bit_pos == 2'd2) begin
                tck_int <= 1'b0;  // End TCK pulse
            end
        end

        default: begin
            tck_int <= 1'b0;
            tms_int <= 1'b1;
            tdi_int <= 1'b0;
            tmsc_oen_int <= 1'b1;
        end
    endcase
end
```

---

## Hardware Integration

### FPGA/ASIC Instantiation

```systemverilog
// Example instantiation
cjtag_bridge u_cjtag (
    .clk_i      (sys_clk_100mhz),  // From PLL/oscillator
    .ntrst_i    (jtag_ntrst),      // From debug connector
    .tckc_i     (cjtag_tckc_pad),  // Async input from pad
    .tmsc_i     (cjtag_tmsc_in),   // Through IOBUF
    .tmsc_o     (cjtag_tmsc_out),  // To IOBUF
    .tmsc_oen   (cjtag_tmsc_oen),  // IOBUF control
    .tck_o      (jtag_tck),        // To TAP
    .tms_o      (jtag_tms),        // To TAP
    .tdi_o      (jtag_tdi),        // To TAP
    .tdo_i      (jtag_tdo),        // From TAP
    .online_o   (cjtag_online),    // Status
    .nsp_o      (cjtag_nsp)        // Status
);

// Bidirectional buffer for TMSC
IOBUF u_tmsc_iobuf (
    .I  (cjtag_tmsc_out),
    .O  (cjtag_tmsc_in),
    .T  (cjtag_tmsc_oen),  // 1=input, 0=output
    .IO (TMSC_PAD)
);
```

### Physical Layer Considerations

**PCB Design:**
- Keep TCKC and TMSC traces short and matched
- Minimize capacitive loading on TMSC (critical for TDO sampling)
- Use controlled impedance for high-speed operation
- Implement keeper circuits on TMSC to maintain last driven state

**Pull Resistors:**
- Standard JTAG mode: Strong pull-ups on TCKC and TMSC
- cJTAG mode: Keeper circuits recommended

**Bidirectional Buffer:**
- Fast switching time essential (direction changes within clock cycle)
- Low output impedance for driving, high impedance when tri-stated

---

## Verification and Testing

### Test Suite Overview

The project includes three comprehensive test suites:

1. **Verilator Unit/Integration Tests**: 121 tests in `tb/test_cjtag.cpp`
2. **OpenOCD Integration Tests**: 8 tests via VPI interface
3. **VPI IDCODE Test**: Direct IDCODE verification

**Combined Status**: 130 total tests, 100% passing ✅

### Verilator Test Suite (121 Tests)

Sample tests from `tb/test_cjtag.cpp`:

| Test # | Name | Description | Status |
|--------|------|-------------|--------|
| 1 | reset_state | Verify OFFLINE state after reset | ✅ PASS |
| 2 | escape_sequence_online_6_edges | 6-toggle activation | ✅ PASS |
| 3 | escape_sequence_reset_8_edges | 8-toggle reset from OSCAN1 | ✅ PASS |
| 4 | oac_validation_valid | Valid OAC acceptance | ✅ PASS |
| 5 | oac_validation_invalid | Invalid OAC rejection | ✅ PASS |
| 6 | oscan1_packet_transmission | OSCAN1 packet handling | ✅ PASS |
| 7 | tck_generation | TCK pulse generation | ✅ PASS |
| 8 | tmsc_bidirectional | TMSC direction control | ✅ PASS |
| 9 | jtag_tap_idcode | IDCODE read via JTAG TAP | ✅ PASS |
| 10 | multiple_oscan1_packets | Sustained packet operation | ✅ PASS |
| 11 | edge_ambiguity_7_edges | 7-toggle activation (tolerance) | ✅ PASS |
| 12 | edge_ambiguity_9_edges | 9-toggle reset verification | ✅ PASS |
| 13 | deselection_from_oscan1 | 10-toggle reset from OSCAN1 | ✅ PASS |
| 14 | deselection_oscan1_alt | 8-toggle minimum reset | ✅ PASS |
| 15 | ntrst_hardware_reset | Hardware reset functionality | ✅ PASS |
| 16 | stress_test_repeated_online_offline | Multiple activation cycles | ✅ PASS |

### Running Tests

```bash
# Clean build
make clean

# Build with verbose output (check for warnings)
make VERBOSE=1

# Run automated test suite
make test

# Run tests with waveform generation
make test-trace

# View waveforms
gtkwave cjtag.fst
```

### Expected Output

```
========================================
cJTAG Bridge Automated Test Suite
========================================

Running test: 01. reset_state ... PASS
Running test: 02. escape_sequence_online_6_edges ... PASS
...
Running test: 121. dmi_stress_test_100_operations ... PASS

========================================
Test Results: 121 tests passed
========================================
✅ ALL TESTS PASSED!
```

### Waveform Analysis

Key signals to observe in `cjtag.fst`:

| Signal | Description | Key Events |
|--------|-------------|------------|
| `tckc_i` | cJTAG clock | Held high during escape |
| `tmsc_i` | cJTAG data in | Toggle count for escape |
| `tmsc_o` | cJTAG data out | TDO during bit 2 |
| `tmsc_oen` | Output enable | 0=output, 1=input |
| `online_o` | Bridge status | High when in OSCAN1 |
| `tck_o` | JTAG clock | Pulses every 3rd TCKC |
| `tms_o` | JTAG TMS | From TMSC bit 1 |
| `tdi_o` | JTAG TDI | Inverted from TMSC bit 0 |
| `tdo_i` | JTAG TDO | To TMSC bit 2 |

---

## Build System

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make` or `make build` | Build Verilator simulation |
| `make test` | Run 121 Verilator automated tests |
| `make test-vpi` | Run VPI IDCODE verification test |
| `make test-openocd` | Run 8 OpenOCD integration tests |
| `make test-trace` | Run tests with waveform generation |
| `make run` | Run simulation (no waveform) |
| `make sim` | Run simulation with FST waveform |
| `make WAVE=1` | Build and run with waveform enabled |
| `make vpi` | Start VPI server for OpenOCD |
| `make clean` | Clean build artifacts |
| `make lint` | Run Verilator lint check |
| `make wave` | Open waveform in GTKWave |
| `make status` | Show build status |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WAVE` | 0 | Enable FST waveform dump (set to 1) |
| `VPI_PORT` | 3333 | VPI server port |
| `VERBOSE` | 0 | Enable verbose debug output |

### Build Process

```
User: make WAVE=1
         │
    ┌─────────┐
    │Makefile │
    └────┬────┘
         │ verilator --cc --exe --build
         ▼
    ┌─────────────────────┐
    │ Verilator Compiler  │
    └────┬────────────┬───┘
         │            │
    ┌────────┐   ┌────────┐
    │ RTL SV │   │C++ TB  │
    └────┬───┘   └───┬────┘
         │           │
         └─────┬─────┘
               ▼
         ┌───────────┐
         │ Vtop.exe  │
         └─────┬─────┘
               │ ./Vtop +trace
               ▼
         ┌───────────┐
         │ cjtag.fst │ ──► GTKWave
         └───────────┘
```

---

## OpenOCD Integration

### VPI Protocol

The simulation provides a VPI server on port 3333 (configurable) for OpenOCD connection:

```
┌──────────────┐                    ┌──────────────┐
│   OpenOCD    │                    │  Simulation  │
│  (Client)    │                    │   (Server)   │
└──────┬───────┘                    └──────┬───────┘
       │                                   │
       │  TCP Connection :3333             │
       ├──────────────────────────────────►│
       │                                   │
       │  CMD_CJTAG_TCKC (0x10) + state    │
       ├──────────────────────────────────►│
       │                                   │
       │  CMD_CJTAG_WRITE (0x11) + data    │
       ├──────────────────────────────────►│
       │                                   │
       │  CMD_CJTAG_READ (0x12)            │
       ├──────────────────────────────────►│
       │                                   │
       │  ◄─ TMSC data byte                │
       │◄──────────────────────────────────┤
       │                                   │
       │  CMD_RESET (0x00)                 │
       ├──────────────────────────────────►│
       │                                   │
```

### Usage

**Terminal 1 - Start Simulation:**
```bash
make WAVE=1 vpi
```

Output:
```
VPI: Server listening on port 3333 (cJTAG mode)
Waiting for OpenOCD connection...
```

**Terminal 2 - Connect OpenOCD:**
```bash
openocd -f openocd/cjtag.cfg
```

Expected:
```
Info : accepting 'jtag_vpi' connection from 3333
Info : cJTAG mode enabled
Info : JTAG tap: riscv.cpu tap/device found: 0x1dead3ff
```

---

## Design Constraints

### Synthesizable Code Requirements

All RTL code follows these rules:
- ✅ Single clock domain (clk_i)
- ✅ All logic uses `always_ff @(posedge clk_i)`
- ✅ No delays (`#` statements) in synthesizable modules
- ✅ No `initial` blocks in production code
- ✅ All case statements have default cases
- ✅ Signals driven from single clock domain only
- ✅ Proper reset handling for all registers

### Warning-Free Compilation

**MANDATORY**: All code must compile without warnings.

```bash
# Verify clean compilation
make clean && make VERBOSE=1

# Expected: No Verilator warnings (except benign linker warnings)
```

Common warnings and fixes:
- `CASEINCOMPLETE` → Add default cases
- `MULTIDRIVEN` → Ensure single clock domain per signal
- `UNUSEDSIGNAL` → Remove or use all declared signals
- `UNOPTFLAT` → Fix combinational loops

---

## Performance Characteristics

### Clock Ratios

- **System to TCKC**: ~10:1 oversampling
- **TCKC to TCK**: 3:1 compression (OScan1 protocol)
- **Overall**: ~30:1 (system clock to JTAG bit rate)

### Latency

| Operation | Latency | Notes |
|-----------|---------|-------|
| Input synchronization | 2 clk_i cycles | ~20 ns @ 100 MHz |
| Edge detection | 1 clk_i cycle | ~10 ns @ 100 MHz |
| State transition | 1-2 TCKC cycles | ~100-200 ns @ 10 MHz TCKC |
| JTAG bit transfer | 3 TCKC cycles | ~300 ns @ 10 MHz TCKC |

### Throughput

At TCKC = 10 MHz:
- OScan1 packets: ~3.33 Mbps
- Effective JTAG rate: ~3.33 MHz
- System clock bandwidth: 100 MHz (sufficient)

---

## References

- IEEE Std 1149.7-2009: "IEEE Standard for Reduced-Pin and Enhanced-Functionality Test Access Port and Boundary-Scan Architecture"
- IEEE Std 1149.1-2013: "IEEE Standard Test Access Port and Boundary-Scan Architecture"
- Project documentation:
  - [README.md](../README.md): Project overview and quick start
  - [PROTOCOL.md](PROTOCOL.md): Detailed cJTAG protocol specification
  - [TEST_GUIDE.md](TEST_GUIDE.md): Testing procedures and debugging
- OpenOCD configuration: [openocd/cjtag.cfg](../openocd/cjtag.cfg)
- OpenOCD patches: [openocd/patched/README.md](../openocd/patched/README.md)

---

**Last Updated**: January 2026
**Architecture Version**: 2.0 (System Clock Based)
**Status**: ✅ Production - All tests passing

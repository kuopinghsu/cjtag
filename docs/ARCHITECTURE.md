# cJTAG System Architecture

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
                                                           ▼
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
            │  │     ▼        ▼                                   │   │
            │  │  ┌──────────────────────┐                        │   │
            │  │  │  OScan1 Protocol     │                        │   │
            │  │  │  ┌────┬────┬────┐    │                        │   │
            │  │  │  │nTDI│TMS │TDO │    │  3-bit packets         │   │
            │  │  │  └────┴────┴────┘    │                        │   │
            │  │  └──────────────────────┘                        │   │
            │  │     │        │        │                          │   │
            │  │     ▼        ▼        ▼                          │   │
            │  │  ┌──────────────────────┐                        │   │
            │  │  │  4-Wire JTAG Output  │                        │   │
            │  │  │  TCK, TMS, TDI, TDO  │                        │   │
            │  │  └──────────┬───────────┘                        │   │
            │  └─────────────┼────────────────────────────────────┘   │
            │                │                                        │
            │                ▼                                        │
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

## Protocol Flow

### 1. Escape Sequence (Go Online)

8 TMSC edges (±1 tolerance) while TCKC held high transitions from OFFLINE → ESCAPE → ONLINE_ACT.

```wavedrom
{
  "signal": [
    {"name": "TCKC", "wave": "1...................0"},
    {"name": "TMSC", "wave": "0101010101010101...."},
    {},
    {"name": "State", "wave": "2...3...............4", "data": ["OFFLINE", "ESCAPE", "ONLINE_ACT"]}
  ],
  "config": {"hscale": 2},
  "head": {"text": "Escape Sequence: 8 TMSC Edges"}
}
```

[View Waveform](https://wavedrom.com/editor.html?signal=%5B%7Bname%3A%27TCKC%27%2Cwave%3A%271...................0%27%7D%2C%7Bname%3A%27TMSC%27%2Cwave%3A%270101010101010101....%27%7D%2C%7B%7D%2C%7Bname%3A%27State%27%2Cwave%3A%272...3...............4%27%2Cdata%3A%5B%27OFFLINE%27%2C%27ESCAPE%27%2C%27ONLINE_ACT%27%5D%7D%5D%2Cconfig%3A%7Bhscale%3A2%7D%2Chead%3A%7Btext%3A%27Escape%20Sequence%3A%208%20TMSC%20Edges%27%7D)

### 2. Online Activation Code (OAC + EC + CP)

12-bit sequence: OAC (4 bits) + EC (4 bits) + CP (4 bits) transmitted LSB first.

```wavedrom
{
  "signal": [
    {"name": "TCKC", "wave": "p............"},
    {"name": "TMSC", "wave": "x1100x1000x0000x"},
    {},
    {"name": "Field", "wave": "x2...3...4...x", "data": ["OAC", "EC", "CP"]},
    {"name": "State", "wave": "2............3", "data": ["ONLINE_ACT", "OSCAN1"]}
  ],
  "config": {"hscale": 2},
  "head": {"text": "OAC Sequence: 1100 + 1000 + 0000"}
}
```

[View Waveform](https://wavedrom.com/editor.html?signal=%5B%7Bname%3A%27TCKC%27%2Cwave%3A%27p............%27%7D%2C%7Bname%3A%27TMSC%27%2Cwave%3A%27x1100x1000x0000x%27%7D%2C%7B%7D%2C%7Bname%3A%27Field%27%2Cwave%3A%27x2...3...4...x%27%2Cdata%3A%5B%27OAC%27%2C%27EC%27%2C%27CP%27%5D%7D%2C%7Bname%3A%27State%27%2Cwave%3A%272............3%27%2Cdata%3A%5B%27ONLINE_ACT%27%2C%27OSCAN1%27%5D%7D%5D%2Cconfig%3A%7Bhscale%3A2%7D%2Chead%3A%7Btext%3A%27OAC%20Sequence%3A%201100%20%2B%201000%20%2B%200000%27%7D)

- **OAC**: `1100` (LSB first) = TAP.7 star-2
- **EC**: `1000` = Short form, RTI state
- **CP**: `0000` = Check packet
- **Result**: State → OSCAN1

### 3. OScan1 3-Bit Scan Packets

Each packet contains 3 bits transmitted over 3 TCKC cycles. TCK pulses on the 3rd bit.

```wavedrom
{
  "signal": [
    {"name": "TCKC", "wave": "p..p..p..p.."},
    {"name": "TMSC", "wave": "x3.4.z.3.4.z.", "data": ["nTDI", "TMS", "TDO", "nTDI", "TMS", "TDO"]},
    {"name": "TMSC_OEN", "wave": "1.....0.....0"},
    {},
    {"name": "TCK", "wave": "0.....1.0...1.0."},
    {"name": "TMS", "wave": "x.3..........", "data": ["TMS"]},
    {"name": "TDI", "wave": "x3...........", "data": ["TDI"]},
    {"name": "TDO", "wave": "x.....4......", "data": ["TDO"]},
    {},
    {"name": "Bit", "wave": "x2.3.4.2.3.4.", "data": ["0", "1", "2", "0", "1", "2"]}
  ],
  "config": {"hscale": 3},
  "head": {"text": "OScan1 3-Bit Packets (nTDI = ~TDI)"}
}
```

[View Waveform](https://wavedrom.com/editor.html?signal=%5B%7Bname%3A%27TCKC%27%2Cwave%3A%27p..p..p..p..%27%7D%2C%7Bname%3A%27TMSC%27%2Cwave%3A%27x3.4.z.3.4.z.%27%2Cdata%3A%5B%27nTDI%27%2C%27TMS%27%2C%27TDO%27%2C%27nTDI%27%2C%27TMS%27%2C%27TDO%27%5D%7D%2C%7Bname%3A%27TMSC_OEN%27%2Cwave%3A%271.....0.....0%27%7D%2C%7B%7D%2C%7Bname%3A%27TCK%27%2Cwave%3A%270.....1.0...1.0.%27%7D%2C%7Bname%3A%27TMS%27%2Cwave%3A%27x.3..........%27%2Cdata%3A%5B%27TMS%27%5D%7D%2C%7Bname%3A%27TDI%27%2Cwave%3A%27x3...........%27%2Cdata%3A%5B%27TDI%27%5D%7D%2C%7Bname%3A%27TDO%27%2Cwave%3A%27x.....4......%27%2Cdata%3A%5B%27TDO%27%5D%7D%2C%7B%7D%2C%7Bname%3A%27Bit%27%2Cwave%3A%27x2.3.4.2.3.4.%27%2Cdata%3A%5B%270%27%2C%271%27%2C%272%27%2C%270%27%2C%271%27%2C%272%27%5D%7D%5D%2Cconfig%3A%7Bhscale%3A3%7D%2Chead%3A%7Btext%3A%27OScan1%203-Bit%20Packets%20(nTDI%20%3D%20~TDI)%27%7D)


- **Bit 0**: nTDI (inverted TDI) - TMSC input
- **Bit 1**: TMS - TMSC input
- **Bit 2**: TDO readback - TMSC output (bidirectional)
- **TCK**: Pulses high during bit 2

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

### cJTAG to JTAG Clock Ratio (1:3)

TCK pulses once every 3 TCKC cycles during OScan1 operation.

```wavedrom
{
  "signal": [
    {"name": "TCKC", "wave": "p.p.p.p.p.p."},
    {"name": "Bit", "wave": "x2.....3....", "data": ["0", "1", "2", "0", "1", "2"]},
    {},
    {"name": "TCK", "wave": "0.....1.0...1.0."},
    {"name": "Count", "wave": "x2.3.4.2.3.4.", "data": ["1", "2", "3", "1", "2", "3"]}
  ],
  "config": {"hscale": 3},
  "head": {"text": "Clock Ratio: 3 TCKC = 1 JTAG Bit"}
}
```

[View Waveform](https://wavedrom.com/editor.html?signal=%5B%7Bname%3A%27TCKC%27%2Cwave%3A%27p.p.p.p.p.p.%27%7D%2C%7Bname%3A%27Bit%27%2Cwave%3A%27x2.....3....%27%2Cdata%3A%5B%270%27%2C%271%27%2C%272%27%2C%270%27%2C%271%27%2C%272%27%5D%7D%2C%7B%7D%2C%7Bname%3A%27TCK%27%2Cwave%3A%270.....1.0...1.0.%27%7D%2C%7Bname%3A%27Count%27%2Cwave%3A%27x2.3.4.2.3.4.%27%2Cdata%3A%5B%271%27%2C%272%27%2C%273%27%2C%271%27%2C%272%27%2C%273%27%5D%7D%5D%2Cconfig%3A%7Bhscale%3A3%7D%2Chead%3A%7Btext%3A%27Clock%20Ratio%3A%203%20TCKC%20%3D%201%20JTAG%20Bit%27%7D)

**Ratio**: 3 TCKC cycles = 1 JTAG bit transfer (TCK pulse on 3rd cycle)

## State Transitions

```
                     ┌─────────────┐
                     │   OFFLINE   │◄─── Reset
                     └──────┬──────┘
                            │ 8 edges on TMSC
                            ▼
                     ┌─────────────┐
                     │   ESCAPE    │
                     └──────┬──────┘
                            │ TCKC falls
                            ▼
                     ┌─────────────┐
                     │ ONLINE_ACT  │
                     └──────┬──────┘
                            │ 12 bits OAC
                            │ (if valid)
                            ▼
                     ┌─────────────┐
           ┌────────►│   OSCAN1    │
           │         └──────┬──────┘
           │                │ Hardware reset (ntrst_i)
           │                │ LIMITATION: No escape support
           │                ▼
           │         ┌─────────────┐
           └─────────┤   OFFLINE   │
      3-bit packets  └─────────────┘

**Note**: OSCAN1→OFFLINE transition requires hardware reset.
Escape sequences are not supported from OSCAN1 due to bidirectional TMSC conflicts.
```

## Waveform Signals to Observe

When viewing `cjtag.fst`:

| Signal | Description | Key Events |
|--------|-------------|------------|
| `tckc_i` | cJTAG clock | Held high during escape |
| `tmsc_i` | cJTAG data in | Toggle 8x for online |
| `tmsc_o` | cJTAG data out | TDO during bit 2 |
| `online_o` | Bridge status | High when in OSCAN1 |
| `tck_o` | JTAG clock | Pulses every 3rd TCKC |
| `tms_o` | JTAG TMS | From TMSC bit 1 |
| `tdi_o` | JTAG TDI | From ~TMSC bit 0 |
| `tdo_i` | JTAG TDO | To TMSC bit 2 |

## File Interaction Flow

```
User Command: make WAVE=1
         │
         ▼
    ┌─────────┐
    │Makefile │
    └────┬────┘
         │ verilator --build
         ▼
    ┌─────────────────────┐
    │ Verilator Compiler  │
    └────┬────────────┬───┘
         │            │
         ▼            ▼
    ┌────────┐   ┌────────┐
    │ RTL SV │   │C++ TB  │
    └────┬───┘   └───┬────┘
         │           │
         └─────┬─────┘
               ▼
         ┌──────────┐
         │ Vtop.exe │
         └────┬─────┘
              │ WAVE=1
              ▼
         ┌──────────┐
         │ VPI Port │  :3333
         │  Server  │◄───── OpenOCD
         └────┬─────┘
              │
              ▼
         ┌──────────┐
         │cjtag.fst │ ──► GTKWave
         └──────────┘
```

---

**Use this diagram to understand how all components work together!**

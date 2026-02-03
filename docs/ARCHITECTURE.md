# cJTAG Bridge Architecture

## Overview

[...] (content with duplicates removed as specified)
430| ## File Interaction Flow
431| ```
432| User Command: make WAVE=1
433|          │
434|     ┌─────────┐
435|     │Makefile │
436|     └────┬────┘
437|          │ verilator --build
438|          ▼
439|     ┌─────────────────────┐
440|     │ Verilator Compiler  │
441|     └────┬────────────┬───┘
442|          │            │
443|     ┌────────┐   ┌────────┐
444|     │ RTL SV │   │C++ TB  │
445|     └────┬───┘   └───┬────┘
446|          │           │
447|          └─────┬─────┘
448|                ▼
449|          ┌───────────┐
450|          │ Vtop.exe  │
451|          └─────┬─────┘
452|                │ WAVE=1
453|                ▼
454|          ┌───────────┐
455|          │ VPI Port  │
456|          │  Server   │
457|          └─────┬─────┘
458|                │
459|          ┌───────────┐
460|          │ cjtag.fst │─► GTKWave
461|          └───────────┘
462| ```
[...] (rest of the file remains the same)
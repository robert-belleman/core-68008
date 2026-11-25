# core-68008
Single-board 68008 system with a Elektor Junior bus interface

The core68008 board is a complete MC68008 computer on one 160 x 100 mm,
4-layer PCB: CPU, 512K RAM, 256K flash, a 68681 DUART for the serial console
and a bridge that runs cards for the Elektor Junior bus at 1 MHz. It boots
into the MON68K monitor, which includes Enhanced BASIC.

Status (2026-11-24): the first PCBs are built and run the monitor from
flash over the FTDI serial link. See [Known issues](#known-issues-and-changes-for-the-next-revision)
for the fixes made on the bench.

## Specifications

| | |
|---|---|
| CPU | MC68008P8 (48-pin DIP, 20 address lines), 8 MHz from oscillator X1 |
| RAM | 512K static RAM, AS6C4008-55 (U4) |
| ROM | 256K flash, SST39SF020A-70 PLCC-32 (U5), programmable in circuit |
| Serial | MC68681 DUART (U6), 3.6864 MHz crystal Y1. Channel A is the console on J2 (FTDI TTL-232R-5V pinout), 38400 8N1, RTS/CTS |
| Expansion | Elektor Junior bus on J1 (DIN 41612, a+c), 64K window at $C0000, 1 MHz PHI2 |
| Glue logic | three ATF22V10C GALs (see below) and a 74LS07 |
| Reset | DS1233-5 power-on reset (U14) and reset button SW1 |
| Interrupts | level 5 = 68681 (vectored), level 2 = Junior IRQ, level 7 = Junior NMI (autovectored) |
| Other | logic analyser header J4, DUART I/O header J3, prototyping area PROTO1 (7 x 20 holes) |

## Memory map

| Range | Device |
|---|---|
| $00000-$7FFFF | SRAM (at reset the boot overlay maps the flash here for reads) |
| $80000-$BFFFF | Flash: MON68K at $80000, EhBASIC at $A0000 |
| $C0000-$CFFFF | Junior bus window (1 MHz bus cycles) |
| $D0000-$EFFFF | unused, bus error |
| $F0000-$FFFFF | 68681 DUART (16 registers, repeated) |

The boot overlay is set by the power-on reset and switched off by the first
access to $80000-$BFFFF, so the CPU fetches its reset vectors from flash.
The monitor's own view of this map, with its workspace and the default
user registers, is in [monitor/MONITOR.md](monitor/MONITOR.md#memory-map-as-the-monitor-sees-it).

## Hardware

The schematic is a hierarchical KiCad 10 project, `core68008.kicad_pro`:

| Sheet | Contents |
|---|---|
| `cpu.kicad_sch` | MC68008 (U1), 74LS07 open-collector drivers (U12), pull-ups, LEDs HALT, RESET and BERR, logic analyser header J4 |
| `memory.kicad_sch` | GAL1 decode (U2), SRAM (U4), flash (U5) |
| `duart.kicad_sch` | 68681 (U6) with crystal Y1, FTDI header J2 (JP3 connects the cable's 5V), I/O header J3, LEDs D5 (OP6) and D6 (OP7) |
| `bridge.kicad_sch` | GAL2 bridge (U3), GAL3 busdbg (U11), 74LS245 buffers (U7-U9), 74HCT573 read latch (U10), Junior bus connector J1 |
| `power.kicad_sch` | 8 MHz oscillator X1, DS1233 reset (U14), reset button, decoupling |

The PCB is `core68008.kicad_pcb`; extra footprints are in `core68008.pretty/`.

### GALs

The GAL sources are in [gal/](gal/) and are built with galasm 2.1
(`make`, `make prog-decode` etc., see the header of [gal/Makefile](gal/Makefile)).
Each `.pld` file explains its equations.

| GAL | Source | Function |
|---|---|---|
| GAL1 (U2) | [decode.pld](gal/decode.pld) | address decoding, boot overlay, DTACK, BERR, RAM/ROM/DUART selects, /RD and /WR |
| GAL2 (U3) | [bridge.pld](gal/bridge.pld) | Junior bus bridge: PHI2 = CLK/8 (1 MHz, locked to the CPU clock), buffer enables, read latch, DTACK after PHI2 falls; interrupt acknowledge (VPA) |
| GAL3 (U11) | [busdbg.pld](gal/busdbg.pld) | bus clocks PHI1/PHI2, bus R/W, RAM.RW, sticky BERR LED, logic analyser trigger and debug outputs DBG0-DBG3 |
| GAL1 (temporary) | [decode_boot.pld](gal/decode_boot.pld) | only for FLASHBOOT, with a 27128 EPROM in the SRAM socket |

### LEDs

| LED | Meaning |
|---|---|
| D2 | power |
| D3, D4 | HALT, RESET |
| D7 | bus error has happened since reset (latched by GAL3) |
| D6 | 68681 OP7: monitor active |
| D5 | 68681 OP6: user LED |

## Software

| Directory | What it is | Documentation |
|---|---|---|
| [monitor/](monitor/) | MON68K, the ROM monitor: memory and register commands, S-record loading (`LO`), disassembler, breakpoints, tracing, a TRAP #15 API for user programs, and `FL` to reprogram the flash from RAM | [MONITOR.md](monitor/MONITOR.md) |
| [monitor/basic/](monitor/basic/) | Lee Davison's Enhanced BASIC 3.54 at $A0000. Start it with `BA` (cold) or `BW` (warm); `BYE` returns to the monitor | [MONITOR.md, EhBASIC](monitor/MONITOR.md#ehbasic-ba-bw) |
| [monitor/flashupd/](monitor/flashupd/) | FLASHUPD: loads a new monitor into the flash from a monitor that doesn't have `FL` yet | [MONITOR.md, FLASHUPD](monitor/MONITOR.md#the-first-time-flashupd) |
| [monitor/examples/](monitor/examples/) | example user programs and the API include file `mon68k.inc` | [MONITOR.md, API](monitor/MONITOR.md#api-for-user-programs-trap-15) |
| [monitor/test/](monitor/test/) | board emulator (Musashi core, with 68681 and SST39SF020A models) and test scripts | [test/README.md](monitor/test/README.md) |
| [flashboot/](flashboot/) | SERTEST and FLASHBOOT: program the flash in circuit from a 27128 EPROM in the SRAM socket, plus `term.py`, a terminal for odd baud rates on macOS | [flashboot/README.md](flashboot/README.md) |
| [Basic/](Basic/) | BASIC programs (a Mandelbrot plot) | |
| [breadboard/](breadboard/) | test programs and logs from the earlier breadboard version | [review.md](breadboard/review.md) |

### Tools

* [vasm](http://sun.hasenbraten.de/vasm/) (`vasmm68k_mot`, Motorola syntax) for all 68000 code. The Makefiles expect `/opt/homebrew/bin/vasmm68k_mot`; override with `make VASM=...`.
* galasm 2.1 for the GALs (`make GALASM=...` to override).
* A T48 programmer with `minipro` for the GALs, the EPROM and the flash (the flash needs a PLCC32 adapter).
* Python 3 for the host scripts (`flashboot.py`, `term.py`, `bin2srec.py`).

### Quick start

```
cd monitor && make          # monitor.bin, the 256K flash image
make flash                  # program it with the T48, or:
make s28                    # monitor.s28, to load with LO and program with FL
```

Connect the FTDI cable to J2 and open a terminal at 38400 8N1 with RTS/CTS.
After reset the monitor shows its banner and the `>` prompt; `HE` lists the
commands. To put a monitor with `FL` on a board whose monitor doesn't have
`FL` yet, use FLASHUPD (`make flashupd`); on a blank board use the T48 or
FLASHBOOT.

## Known issues and changes for the next revision

Found during bring-up of the first PCBs:

* **RxDA pull-up too strong.** The USB-serial module's TX could only pull
  RxDA (via the 10k in RN2) down to about 2.4 V, so the 68681 received
  nothing. Workaround: RN2 removed. Next revision: a separate 100k pull-up on RxDA.
* **~BR floats** now that RN2 is out, because RN2 also pulls up ~BR. Refit RN2
  with its RxDA pin clipped, or fit a 10k pull-up on ~BR.
* **68681 crystal doesn't start reliably** (it runs at about 100 kHz unless the
  board is touched). The 68681 data sheet asks for unequal load capacitors,
  but C2 and C3 are both 22 pF. Change C2 (X1, pin 32) to 12-15 pF and C3
  (X2, pin 33) to 0-5 pF. 12 pF and 4.7 pF are verified to work. An option for a
  3.6864 MHz oscillator can would also help.
* **~VPA and ~IACK5** are driven only by GAL2 and have no pull-ups, so they
  float when GAL2 is not fitted. Add pull-ups.
* **XDTACK** pull-up: use a separate 1k resistor instead of the RN1 element.

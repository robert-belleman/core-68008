# Monitor tests

`emu/` is a board model of the core68008 (20-bit bus, GAL1 map and boot
overlay, BERR range, 68681 channel A with FIFO, interrupts and RxRTS flow
control, NMI, BREAK) around the Musashi 68000 core (Karl Stenerud, see
emu/readme.txt), with small patches for the board's bus error and interrupt
acknowledge. Build with `make` in emu/ (or
`cc -O2 -w -o emu emu.c m68kcpu.c m68kops.c m68kdasm.c softfloat/softfloat.c -lm`).

Interactive: `./emu -r ../../monitor.bin -i` makes your terminal the serial
console at real 8 MHz speed (-F: as fast as the host can). Ctrl-] then
q quit, s send a file (type LO first, then send an .s28), n NMI, b BREAK,
r power-on reset, l LED state, f toggle speed.
Scripts: `./emu -r ../../monitor.bin -s ../fn/s1.txt`.

fn/   s1-s9.txt scripts, s1-s9.out their output with the final monitor.bin
      (tp.asm/ap.asm are the test programs, *.s the S-record test files):
      s1 breakpoints, pass count, T/SO/GT/CALL, register set
      s2 exceptions (bus, address, zero divide, CHK, privilege, line A/F,
         TRAP, ILLEGAL), BR/BC
      s3 Ctrl-C, BREAK, NMI, trace through TRAP #15, user mode, RESET
      s4 S-records (good, checksum, range, offset, odd entry), DU, MF/MC/MS/CM,
         range checks
      s5 LO offset, VE / VE D
      s6 API functions, user TRAP handler, breakpoint rules, trace into trap
      s7 16K S-record load with and without flow control
      s8 the example programs
      s9 breakpoint and trace in user mode
dis/  disassembler round trip: gen.py EXT makes slots0/1.bin (every opcode
      plus extension words EXT), dt.asm runs the DISASM API over them,
      cmp.py compares validity with Musashi (valid.c) and reassembles the
      output with vasm -no-opt to compare bytes.

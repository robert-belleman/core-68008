# Monitor tests

`emu/` is a board model of the core68008 (20-bit bus, GAL1 map and boot
overlay, BERR range, 68681 channel A with FIFO, interrupts, RTS on OP0
(68681 RxRTS or driven through the OPR) as the sender's CTS, NMI, BREAK) around the Musashi 68000 core (Karl Stenerud, see
emu/readme.txt), with small patches for the board's bus error and interrupt
acknowledge, and an SST39SF020A flash model (unlock/command cycles, software
ID, byte program and sector/chip erase with busy time and DQ7/DQ6 status bits,
and a warning when code is fetched from the flash while it is busy or in ID
mode). Build with `make` in emu/ (or
`cc -O2 -w -o emu emu.c m68kcpu.c m68kops.c m68kdasm.c softfloat/softfloat.c -lm`).

Interactive: `./emu -r ../../monitor.bin -i` makes your terminal the serial
console at real 8 MHz speed (-F: as fast as the host can). Ctrl-] then
q quit, s send a file (type LO first, then send an .s28), n NMI, b BREAK,
r power-on reset, l LED state, f toggle speed.
Scripts: `./emu -r ../../monitor.bin -s ../fn/s1.txt`.
Script commands for the flash: @load FILE A copies a file into memory,
@save FILE writes the 256K flash to FILE, @stuck A M makes flash byte A keep
bits M at 1 (M=0 clears it), @flashlog prints every program/erase command
(the full list is at the top of emu.c).
Serial: @fast sends at 400 clocks/character instead of 2083 (38400 baud);
@lag N makes the sender FTDI-like: it ignores the 68681 FIFO and sends N more
characters after RTS goes away (default 0: an ideal sender that never
overruns the FIFO); @track H T reports the maximum of byte H minus byte T
(the ring fill with H=v_rxhead, T=v_rxtail), at the end or at @track.

fn/   s1-s10.txt scripts, s1-s10.out their output with the final monitor.bin
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
      s10 LO of monitor.s28 at full speed with @lag 3: RTS flow control
          with slack (0 bad records, 0 overruns, CM against the flash)
dis/  disassembler round trip: gen.py EXT makes slots0/1.bin (every opcode
      plus extension words EXT), dt.asm runs the DISASM API over them,
      cmp.py compares validity with Musashi (valid.c) and reassembles the
      output with vasm -no-opt to compare bytes.
flash/ fl1-fl4.txt FL command tests, fu1-fu3.txt FLASHUPD tests, and their
      .out (fl2-fl4 run with an older ROM: /tmp/old.bin = monitor.bin with
      "Type HE for HELP." in the banner):
      fl1 ID, argument checks, blank area, sector-data refusal, Y/N,
          protection, stuck bit
      fl2 self-update from a binary in RAM, bad reset vector refusal
      fl3 self-update through LO monitor.s28
      fl4 failed self-update, retry with R
      fu1-fu3 (ROM = the a5707a9 monitor):
      fu1 FLASHUPD update through LO and GO, then FL works
      fu2 RAM not filled with $FF first, sum error, flash unchanged
      fu3 answer N, flash unchanged

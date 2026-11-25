# MON68K 1.0: ROM monitor for the core68008 board

MON68K lives in the 256K flash (SST39SF020A, $80000-$BFFFF). It starts at power-on reset and talks to you over the FTDI cable on 68681 channel A at **38400 baud, 8N1, RTS/CTS**. Everything you type is a hex number unless you say otherwise.

```
MON68K 1.0 for core68008 (MC68008, 8 MHz). Type HE for help.
RAM $00000-$7FFFF  ROM $80000-$BFFFF  Junior bus $C0000-$CFFFF  68681 $F0000
>
```

## Building and programming

| What | How |
|---|---|
| Assemble | `make` (runs `/opt/homebrew/bin/vasmm68k_mot -m68000 -Fbin`, gives `monitor.bin`, exactly 262144 bytes, and `monitor.lst`) |
| Program the flash | `make flash`. This runs `minipro -p "SST39SF020A@PLCC32" -w monitor.bin`. Check the device name first with `minipro -L SST39SF020`. You need the PLCC32-to-DIP32 adapter. |
| Example programs | `make examples` gives `examples/hello.s28` and `examples/apidemo.s28` |
| EhBASIC | `make` first assembles `basic/ehbasic.asm` into `basic/ehbasic.bin` (linked at $A0000). `monitor.asm` pads the image to $A0000 and includes it. |
| Update over the serial line | `make s28`, then `LO` and `FL` on the board (see "Programming the flash") |

The image is linked at $80000. The CPU fetches the reset vectors from flash offsets 0 and 4 through the boot overlay (see H2).

## Memory map as the monitor sees it

| Range | Use | Monitor access |
|---|---|---|
| $00000-$003FF | Exception vectors (RAM copy, made at reset) | read/write; `VE` shows changes |
| $00400-$00FFF | Monitor workspace and monitor stack | read only (protected) |
| $01000-$7FFFF | **User RAM** | everything |
| $80000-$BFFFF | Flash (monitor) | read, disassemble; `FL` programs it |
| $C0000-$CFFFF | Junior bus window (1 MHz cycles) | everything, including breakpoints |
| $D0000-$EFFFF | Unmapped: the GAL asserts BERR | refused |
| $F0000-$FFFFF | 68681 (16 registers, repeated) | single `MM` accesses only |

Default user registers (`RI` restores them): PC=$1000, SR=$2000 (supervisor, mask 0), SSP=$80000 (top of RAM), USP=$7F000, all others 0.

## Command line

* Numbers are hex. `#123` is decimal, `%1010` is binary, `'A'` is a character, and `.D0`/`.PC`/`.A7` etc. is the current value of a user register. You can add and subtract terms: `MD .A0+10`, `DI .PC-4`.
* Overflow past 32 bits and addresses beyond $FFFFF (the 68008 has 20 address lines) are errors. The monitor never wraps around silently.
* Commands are not case-sensitive. Editing keys: Backspace/DEL, Ctrl-U (erase line), ESC [A (up arrow: recall the previous line).
* An **empty line repeats** `MD`, `DI`, `T` and `SO`. `MD` and `DI` continue where they stopped.
* `.B`, `.W` and `.L` set the access size on `MM`, `MF` and `MS` (default .B). Word and long accesses at an odd address are refused, because the 68008, like the 68000, takes an address error for them. The 68008 still splits each word into two byte cycles, even address first (big-endian).
* **Ctrl-C** stops a long listing or a running program. A received **BREAK** or the bus **NMI** does the same.

## Commands

| Command | Meaning |
|---|---|
| `MD [addr [len]]` | Hex and ASCII dump (default 128 bytes) |
| `MM[.s] addr v [v..]` | Write values at addr, addr+size, … Each value is read back and checked. |
| `MM[.s] addr` | Interactive: shows the value. Type a new value, Enter for next, `-` for back, `.` to quit. I/O space is never read before you write it. |
| `MF[.s] start end v` | Fill (end inclusive) |
| `MC start end dest` | Copy. Overlapping ranges are copied correctly. |
| `MS[.s] start end v [v..]` / `MS start end "text"` | Search. Lists every match address. |
| `CM start end dest` | Compare two blocks. Lists the differences. |
| `LO [offset]` | Load S-records (see below) |
| `DU start end [entry]` | Dump as S2 records with an S0 header, an S5 count and an S8 end record |
| `GO [addr]` | Run, from addr or from the current PC, with breakpoints |
| `GT addr` | Run until addr (temporary breakpoint) |
| `CALL addr` | Call a subroutine. Its RTS returns to the monitor, and the PC goes back to where it was. |
| `T [n]` | Trace n instructions (default 1). The last one shows all registers. |
| `SO` | Step over: BSR/JSR/TRAP run at full speed to the next instruction. Anything else is a single step. |
| `R` | Show all registers and the next instruction |
| `R reg` / `R reg value` | Show or set one register: D0-D7, A0-A7 (or SP: the *active* stack pointer), PC, SR, USP, SSP |
| `RI` | Reset the user registers to their defaults |
| `BR` / `BR addr [count]` | List breakpoints, or set one (8 max). With a count it stops on the count-th pass. |
| `BC [n \| addr]` | Clear one breakpoint, or all of them |
| `DI [addr [n]]` | Disassemble (vasm syntax, see below) |
| `VE` / `VE D` | List vectors that no longer point to the monitor, or restore all of them |
| `IN` | Memory map, console settings, receive error flags |
| `BA [top]` | Start EhBASIC from scratch (cold start), with RAM $01000 to top-1 (default $80000, so all of user RAM) |
| `BW [start]` | Go back into EhBASIC (warm start). The program and variables stay. |
| `FL` | Show the flash ID and the protected monitor sectors |
| `FL start end dest [!]` | Program RAM start..end into the flash at dest (see "Programming the flash"). `!` allows changing the monitor itself. |
| `HE`, `HELP`, `?` | Help |

### S-record loading (`LO`)

* Accepted: S0 (ignored), S1/S2/S3 data, S5/S6 counts, S7/S8/S9 end. S4 is rejected. Upper or lower case hex. CR, LF or CRLF line ends. Leading blanks are allowed.
* Each record is checked **completely before any byte is written**: hex digits, the count byte, the checksum (ones' complement of the sum of count, address and data bytes), nothing after the checksum, address + offset with no 32-bit overflow, and the whole range inside writable memory below $FFFFF. User RAM and the Junior window qualify; the vector table, the workspace, the flash, I/O and unmapped space do not.
* Every written byte is read back.
* A bad record is skipped and counted. Loading goes on to the end record, so the rest of the file is not taken as commands. At the end you get bytes, records, the address range, and the first bad record with its reason.
* The PC is set to the entry address only if the **whole** load was error free and the entry is even and executable. Otherwise the PC is left alone and the monitor says why.
* `LO offset` adds the offset to every address, including the entry address.
* ESC or Ctrl-C cancels. If the S5/S6 count doesn't match, you get a warning.

### Disassembler

It covers the complete MC68000 instruction set. Output is vasm Motorola syntax, with branch and PC-relative targets shown as absolute addresses. Words that are not valid 68000 instructions show as `DC.W $xxxx`. The A-line and F-line opcodes are among those, because the 68000 takes an exception on them.

**Tested:** all 65,536 first words, with three different sets of extension words. Every one of the 45,816 decodable instructions per set was reassembled with vasm and gave back **the same bytes**. The only differences are bits the 68000 ignores: the high byte of a byte immediate, and bits 8-10 of a brief index extension word. The set of opcodes accepted as valid matches Musashi's MC68000 table, apart from `ILLEGAL` ($4AFC, shown by name) and 16 `Bcc.S` with displacement $FF (odd target on a 68000, shown as such).

## EhBASIC (`BA`, `BW`)

The flash holds Lee Davison's Enhanced BASIC 3.54 for the 68000 at $A0000 (source in `basic/`, based on Jeff Tranter's TS2 port). EhBASIC is free for personal and educational use only; see the header of `basic/ehbasic.asm`. The language manual is at http://retro.hansotten.nl/home/lee-davison-web-site/.

```
> BA
 518676 Bytes free

Enhanced 68k BASIC Version 3.54 for MON68K. BYE returns to the monitor.

Ready
```

* **`BA [top]`** is a cold start. Any program in memory is lost. BASIC gets $01000 up to top-1. Give a lower top, e.g. `BA 70000`, to keep $70000-$7FFFF free for machine code that you `CALL` from BASIC. It needs at least 16K.
* **`BW [start]`** is a warm start. BASIC checks that the RAM still holds a session it started (warm start vector, program start, end of memory). If it does, you get `Ready` with the program and variables kept. If it doesn't, it says so and nothing is changed. This also works after the reset button, because the SRAM keeps its contents. `start` is only needed if the session doesn't start at $01000.
* **Keywords are upper case** (`PRINT`, not `print`). Variable names can be either case, and `x` and `X` are different variables.
* **Ctrl-C** stops a BASIC program (`Break in line n`) and `CONT` continues it. While BASIC runs, the monitor's own Ctrl-C break is off (`IN` shows this). BASIC turns it back on when you leave with `BYE`.
* **`BYE`** goes back to the monitor. `BW` or `GO` returns to `Ready`.
* **A serial BREAK or the NMI** stops BASIC and shows the registers, like any program. `GO` continues where it was, and `BW` goes to `Ready`.
* **`LOAD` and `SAVE`** give `Not implemented Error`, because the board has no storage. To keep a program, `LIST` it and capture the text in your terminal. To load one, type `NEW` and paste it. RTS/CTS flow control makes pasting safe, even though each line takes a moment to tokenise.
* **`PEEK`, `POKE`, `DEEK`, `DOKE`, `LEEK`, `LOKE`** go straight to the bus, so `PEEK($C0000)` reads the Junior window and `POKE $F0000+n,v` writes a 68681 register. Word and long accesses need even addresses. `CALL addr` runs machine code, which ends with `RTS`. An address in $D0000-$EFFFF gives a bus error, and the monitor shows it.
* BASIC runs in supervisor mode with SR=$2000 and keeps its 1K stack at the start of its RAM. The monitor commands and breakpoints still work. A breakpoint in BASIC's RAM would be overwritten by the program, so only put breakpoints in machine code that BASIC calls.
* The `ON IRQ`/`ON NMI` statements of the 6502 EhBASIC don't exist in the 68000 version.

## Programming the flash (`FL`)

`FL` writes a block of RAM into the flash (SST39SF020A) on the board. You can use it to update the monitor itself over the serial line, without FLASHBOOT and without the T48, or to put your own code or data in the free part of the flash.

| Command | Meaning |
|---|---|
| `FL` | Show the flash ID ($BFB6 for the SST39SF020A) and which sectors hold the monitor |
| `FL start end dest` | Program RAM `start`..`end` (inclusive) into the flash at `dest` |
| `FL start end dest !` | The same, and also allow changes to the monitor's own sectors |

What `FL` does:

1. It checks the arguments. The source must be in user RAM ($01000-$7FFFF) and the whole destination must be in the flash ($80000-$BFFFF).
2. It reads the chip ID. If the ID is not $BFB6 (SST39SF020A) or $BFB7 (SST39SF040), it stops. A wrong ID usually means that the flash doesn't see its write strobe (/WE).
3. It works out the job one 4K sector at a time. A sector is erased only if a byte has to change a 0 bit back into a 1. Otherwise its bytes are programmed over the old ones. Only the bytes that differ are programmed. If a sector has to be erased but also holds data outside your range that is not $FF, `FL` refuses, because the erase would lose that data. Then copy that data into your RAM image as well (`MC`) and flash whole sectors.
4. It prints the plan (`erase n sector(s), program n byte(s)`) and asks `Program the flash (Y/N)?`. Type `Y` and Enter to go on; anything else cancels. If the flash already holds the data, it says so and does nothing.
5. It erases, programs and then compares the whole range with the RAM (`Verifying   OK`). If something fails, you get the address, the value it wrote and the value it reads back.

The routine that talks to the chip (about 1K) is copied onto the monitor stack and runs from RAM, with interrupts masked, because the flash can't be read while it erases or programs. Ctrl-C, BREAK and the NMI are ignored while it runs. Erasing takes about 25 ms per sector, and programming takes about 40 µs per byte, so a whole monitor update takes a few seconds.

### Protection of the running monitor

The sectors from $80000 to the end of the monitor code (`FL` without arguments shows the range) are protected. A job that would change one of them is refused unless you add `!`. With `!`:

* `FL` first checks that the reset vector the flash will hold afterwards (offset 4) is an even address in the flash. If it isn't, the board could not start, so `FL` refuses.
* After a successful verify, the board doesn't return to the old monitor (it is gone). It prints `Starting the new monitor.`, executes `RESET` (68681 and Junior bus) and jumps through the new reset vector, the same way as after power-on. User RAM above $01000 keeps its contents.
* If a step fails, the monitor in the flash is incomplete. The routine then stays in RAM and waits: press `R` to run the whole job again. Keep the power on. If it keeps failing, program the flash with FLASHBOOT or the T48.

EhBASIC ($A0000) and the free space between the monitor and EhBASIC are not protected.

### The first time: FLASHUPD

A monitor without `FL` (such as commit a5707a9) can't run `FL`. For that case, `make flashupd` makes `flashupd/flashupd.s28`, which holds a small RAM program (FLASHUPD, at $01000) and the new image (at $10000). The file is about 99K (101790 bytes), so it takes about 27 seconds at 38400 baud (3840 characters per second). On the board:

```
> MF 10000 4FFFF FF
> LO
Send the S-record file now (ESC or Ctrl-C cancels)
                                (send flashupd/flashupd.s28 from your terminal)
> GO
```

LO sets the PC to $01000, so `GO` starts FLASHUPD. It first checks the image in RAM against a sum that `make` stored in it, so a forgotten `MF` or a lost record is caught before anything is erased. Then it checks the image's reset vector and the flash ID, shows the plan and asks Y/N. After `Y` it uses the same engine as `FL`: erase, program, verify, and it starts the new monitor. If a step fails, you get the same `R` retry. Example (emulator test fu1, updating the a5707a9 monitor):

```
FLASHUPD: put the MON68K image at RAM $10000-$4FFFF into the flash
Flash ID $BFB6
Erase 6 sector(s), program 25947 byte(s)
This replaces the monitor. Keep the power on and don't press reset until
the new monitor starts. If a step fails, you can try it again.
Program the flash (Y/N)? Y
Erasing     ......
Programming ................................................................
Verifying   OK
Starting the new monitor.
```

If you answer anything other than `Y`, or the sum, reset vector or flash ID is wrong, FLASHUPD returns to the old monitor and the flash is unchanged. After that, use `FL` as described below.

### Updating the monitor over the serial line

This needs a monitor that already has `FL`. For the first time, see FLASHUPD above.

```
make s28
```

This makes `monitor.s28`: the 256K image as S-records at $10000-$4FFFF (`bin2srec.py`). Records that hold only $FF are left out, so the file is short (about 94K, about 25 seconds at 38400 baud, 3840 characters per second). Because those records are missing, fill the RAM with $FF first. On the board:

```
> MF 10000 4FFFF FF
> LO
Send the S-record file now (ESC or Ctrl-C cancels)
                                (send monitor.s28 from your terminal)
> FL 10000 4FFFF 80000 !
Flash ID $BFB6: SST39SF020A
Flash $80000-$BFFFF from RAM $10000: erase 1 sector(s), program 4077 byte(s)
This rewrites the running monitor. Keep the power on and don't press reset
until the new monitor starts. If a step fails, you can try it again.
Program the flash (Y/N)? Y
Erasing     .
Programming ................................................................
Verifying   OK
Starting the new monitor.
```

(This output is from emulator test fl3, where only one sector of the monitor differed.)

`FL` only erases and programs the sectors that changed, so a small change to the monitor is quick. To update only EhBASIC, flash its part of the image: `FL 30000 3FFFF A0000` (no `!` needed).

**Tested** in the emulator (`test/emu`, which now models the SST39SF020A command set, busy time and status bits, and warns when code runs from the flash while it is busy): ID, argument checks, programming a blank area, the refusal to erase other data, Y/N, the protection, a bad reset vector, a byte that won't program (with and without the monitor involved), retry with `R`, a full self-update both from a binary in RAM and through `LO` with `monitor.s28`, and FLASHUPD started from the a5707a9 monitor (fu1: update, after which `FL` works; fu2: RAM not filled with $FF first, sum error; fu3: answer N; in fu2 and fu3 the flash is unchanged). The scripts and their output are in `test/flash/`. In every successful update the flash ended up byte-identical to `monitor.bin`. Not yet tested on the board.

## Debugging: how it works

* **Breakpoints are `ILLEGAL` ($4AFC).** The illegal-instruction exception stacks the address of the offending instruction itself, so the stacked PC *is* the breakpoint address and no adjustment is needed. A TRAP-based breakpoint would stack PC+2 and need a correction, which is why TRAP is not used. Breakpoints are written into memory only while the program runs, and the monitor checks each write by reading it back. They are removed on *every* entry to the monitor, so memory always shows the program's own code. If a program overwrote a breakpoint, you get a warning. Only even addresses in RAM or the Junior window are allowed.
* **Resuming from a breakpoint** (`GO` with a breakpoint at PC): the instruction at PC is first executed alone under trace with the breakpoints out. Then all breakpoints are written back and the program runs on. Both happen with interrupts masked while the instruction words change.
* **Trace** uses the T bit in the SR of the exception frame the monitor builds for RTE. As the MC68000 manual describes:
  * If T is set at the start of an instruction, a trace exception follows it.
  * If that instruction traps (TRAP, TRAPV, CHK, DIV by zero), the trap is processed first. The trace then stops at the first instruction of the handler.
  * Illegal, privileged and unimplemented instructions, and instructions aborted by a bus or address error, are not traced. You get their own exception instead.
  * A pending interrupt is taken after the trace exception.

  A TRAP whose vector still points into the monitor (the TRAP #15 services, unused traps) is stepped over as one instruction, so `T` never stops inside the ROM. A TRAP you redirected with `SETVEC` is traced into your handler. If your own program sets T, the monitor reports a trace exception like any other.
* **Supervisor and user stacks:** the monitor keeps the program's SSP and USP separately, and A7 always means the active one (S bit). The monitor itself runs on its own stack at $1000 and never uses the program's stack. The one exception is the 6-byte RTE frame it builds on the program's SSP to start or resume it. Before resuming, the PC must be even and within 20 bits, the SSP even and in $01008-$80000, and the USP even (when in user mode). Only the defined SR bits are kept ($A71F).
* **Exceptions** get a name and a register dump. Bus and address errors also show the access address, read/write, function code, program/data, and the instruction register. The 68000 stacks a PC 2-10 bytes beyond the faulting instruction for these, so the monitor tells you they cannot be restarted. For TRAP, TRAPV, CHK and zero divide the PC shown is the next instruction. For illegal, privilege and line A/F it is the faulting instruction.
* **Monitor faults are kept apart from program faults.** Before an exception is handled, the monitor checks whether it was running itself (`v_inmon`). If it was, the program's saved registers are not touched. The fault is reported as `*** Monitor error`, or caught at a recovery point, and the monitor goes back to its prompt. Most such faults are prevented anyway, because every address a command touches is checked against the memory map first.
* **CALL** pushes a return address that points to an `ILLEGAL` in ROM. The subroutine's RTS lands there, the monitor recognises it, checks the stack pointer, and restores the old PC.
* **Ctrl-C/BREAK/NMI** while a program runs: if the CPU was in the program, it stops at once (`Break`). If it was inside a monitor service, the request waits until the TRAP #15 call returns, then the program stops at the instruction after the TRAP. With the interrupt mask at 5 or above, the 68681 interrupt can't be taken, so Ctrl-C only works when the program calls GETC/KBHIT (polling) or through the NMI.

## API for user programs (TRAP #15)

Put the function number in D0.W and the arguments in D1/D2/A0/A1, then `TRAP #15`. The result comes back in D0.L, and all other registers are preserved. It works from user and supervisor mode. The service runs on the caller's supervisor stack and needs about 64 bytes of it. The caller's interrupt mask is kept. `examples/mon68k.inc` has the equates and a `MONCALL` macro. Unknown function numbers return D0 = -1.

| D0 | Name | In | Out |
|---|---|---|---|
| 0 | EXIT | D1 = exit code | back to the monitor prompt (registers kept for `R`) |
| 1 | GETC | | D0 = character (waits); -1 if Ctrl-C/BREAK |
| 2 | PUTC | D1.B = character | |
| 3 | PUTS | A0 = NUL-terminated string | |
| 4 | KBHIT | | D0 = number of characters waiting |
| 5 | GETLINE | A0 = buffer, D1.W = size | D0 = length (line is NUL terminated, with editing and echo), -1 if aborted |
| 6 | PUTHEX | D1.L = value, D2.W = digits 1-8 | |
| 7 | PUTDEC | D1.L = unsigned value | |
| 8 | CRLF | | |
| 9 | SETVEC | D1.W = vector 2-255, A0 = handler | D0 = old handler; -1 if the vector number is bad |
| 10 | GETVEC | D1.W = vector 0-255 | D0 = handler |
| 11 | ABORTCTL | D1.B = 0 Ctrl-C off, 1 on | D0 = old setting |
| 12 | LED | D1 bit 0 = user LED D5 (OP6) | |
| 13 | DISASM | A0 = address (even), A1 = 64-byte buffer | D0 = instruction length in bytes; text in buffer |
| 14 | INFO | | A0 = info block (see `mon68k.inc`), D0 = version $0100 |
| 15 | GETCNB | | D0 = character or -1 if none |

Notes for programs:

* A program can end with `EXIT`. If it was started with `CALL`, it can also end with `RTS`.
* SETVEC replaces the vector in a single long write, so no interrupt can see half of it. Don't replace vectors 4 (illegal), 9 (trace), 47 (TRAP #15) or 64 (68681) if you still want breakpoints, tracing, the API and the console. `VE D` puts everything back.
* Your own level-2 (Junior bus IRQ, vector 26) or level-7 (NMI, vector 31) handler can be installed with SETVEC.
* The receive buffer is 256 bytes. The receive interrupt always empties the 68681 FIFO into it. When the buffer holds 128 characters, the monitor negates RTS (OP0) to tell the FTDI to pause, and it asserts RTS again when a program has read it down below 64. The other 127 places are slack for a sender that stops a few characters late (an FTDI sends up to 3 more), so nothing overruns. A host without RTS/CTS can still lose characters if a program doesn't read the console for a long time.
* Executing `RESET` is safe. It resets the 68681 and the Junior bus (see H3), and the monitor re-initialises the 68681 on its next output or entry. The boot overlay is *not* turned back on.

## Reset and start-up (what happens at power-on)

1. The DS1233 releases ~PORST. GAL1 sets the boot overlay, so reads of $00000-$7FFFF come from the flash. The CPU fetches SSP=$1000 and PC=`cold_start` (in $80000-$BFFFF) from flash offsets 0 and 4. The first instruction fetch at $8xxxx clears the overlay.
2. `MOVE #$2700,SR`, then a RAM test of $00000-$00FFF that uses no RAM (no stack). If it fails, both LEDs light and a polled message goes out on the serial port.
3. The workspace is cleared, initialised data is copied from ROM to RAM (the size is checked when the image is assembled), and the vector table is copied to $00000 and verified.
4. The 68681 is set up (38400 8N1, RTS asserted by the monitor, receive interrupt on level 5, IVR = 64), SR goes to $2400, and the banner is printed.

## Hardware assumptions

Taken from the rev 0.2 netlist and the GAL equations. If one of these is different on the real board, the monitor needs changing.

* **H1** Memory map as in the table above. The Junior window always gets DTACK, even with no card present. $D0000-$EFFFF gets BERR from GAL1. The 68681 has RS1-RS4 on A0-A3.
* **H2** The boot overlay is set only by ~PORST and cleared by the first cycle at $8xxxx. Writes always reach the SRAM. The RESET instruction does not turn the overlay back on.
* **H3** The CPU's ~RESET output resets the 68681 and the Junior bus (BRES). The monitor detects a reset 68681 from its IVR reading back $0F.
* **H4** Interrupt levels: 5 = 68681 (vectored, IVR = 64), 2 = Junior IRQ (autovector 26), 7 = Junior NMI (autovector 31, edge-triggered, can't be masked). The 48-pin 68008 has only levels 2, 5 and 7.
* **H5** The 68681 crystal is 3.6864 MHz. Channel A goes to the FTDI cable: OP0 = RTS out, IP0 = CTS in. The monitor drives OP0 itself through the OPR; the 68681's RxRTS mode (MR1A bit 7) is off, because it negates RTS only when the 3-character FIFO is already full, and the characters an FTDI still sends after that are lost (68681 overrun). The monitor's transmitter doesn't use CTS (MR2A = $07). Set MR2A bit 4 if the host needs it.
* **H6** OP7 lights D6 ("monitor active") and OP6 lights D5 (user LED). Setting an OPR bit drives the pin low.
* **H7** There is no other bus master, cache or MMU. CPU clock 8 MHz (TX timeout ≈ 1 s).

## Source files

| File | Content |
|---|---|
| `monitor.asm` | Equates, RAM layout, vector table, cold start, initialised data |
| `util.asm` | Text output and number formatting |
| `serial.asm` | 68681 driver: interrupt receive ring buffer, flow control, Ctrl-C/BREAK |
| `except.asm` | Exception entry and exit, trace, breakpoints, stepping, register display |
| `cmds.asm` | Command parser and commands, memory-range checks |
| `srec.asm` | S-record loader and dumper |
| `api.asm` | TRAP #15 services |
| `disasm.asm` | MC68000 disassembler |
| `flash.asm` | FL command: plans the job, and the RAM-resident erase/program/verify engine |
| `bin2srec.py` | monitor.bin as S-records at $10000 for LO (make s28) |
| `flashupd/` | FLASHUPD (`flashupd.asm`, a RAM program that puts a new monitor into the flash from a monitor without `FL`) and `mkflashupd.py`, which makes `flashupd.s28` (make flashupd) |
| `flash_defs.inc`, `flash_engine.asm` | Flash constants and the erase/program/verify engine, shared by `FL` and FLASHUPD |
| `test/` | Emulator board model (`emu.c`, for Musashi) and the test scripts used |

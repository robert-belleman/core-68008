# FLASHBOOT: program the flash in circuit from a 27128 EPROM

This is a stopgap for while the PLCC32 adapter for the T48 hasn't arrived. A small
loader in a 27128 EPROM runs from the SRAM socket. It receives the flash image
over the FTDI cable and programs the SST39SF020A on the board.

## 1. EPROM

Use the **AM27128A-2DC** (200 ns). With no wait states at 8 MHz, the EPROM has
about 220 ns from /CE and /OE to valid data, so a 200 ns part is fine. Don't use
the NEC D27128D: with no speed suffix it is probably a 250 ns part, and that is too slow.

```
make blank      # must say the EPROM is blank; otherwise erase it under UV first
make eprom      # writes eprom.bin (16K) with the T48
```

`eprom.bin` holds two programs, so the EPROM never has to be erased in
between:
- **SERTEST**, `sertest.asm`, runs at reset and only tests the serial port.
- **FLASHBOOT**, `flashboot.asm`, is copied in at $2000. It is started from
  SERTEST with `F`. `flashboot.py` sends that `F` itself.

## 2. GAL1

```
cd ../gal && make prog-decode_boot
```

`decode_boot.pld` is `decode.pld` with two equations changed:
- /RAMCE selects the EPROM for reads in $00000-$7FFFF only.
- /ROMCE selects the flash in $80000-$BFFFF only, for reads and writes.

The boot overlay is not used.

## 3. Wiring: 27128 in the 32-pin SRAM position

With the power off, take the AS6C4008 out. Put the 27128 in the **bottom 28
positions**: EPROM pin 1 goes where SRAM pin 3 was, and EPROM pin 28 goes where
SRAM pin 30 was. Pin 1 of both chips points the same way. SRAM positions 1, 2, 31
and 32 stay empty.

| EPROM pin | SRAM position | Board signal there | Do |
|---|---|---|---|
| 1 VPP | 3 | A14 | **disconnect from A14, connect to +5V** |
| 2-13 | 4-15 | A12, A7-A0, D0-D2 | as is |
| 14 GND | 16 | GND | as is |
| 15-19 | 17-21 | D3-D7 | as is |
| 20 /CE | 22 | ~RAMCE | as is |
| 21-26 | 23-28 | A10, /OE=~RD, A11, A9, A8, A13 | as is |
| 27 /PGM | 29 | ~WR | **disconnect from ~WR, connect to +5V** |
| 28 VCC | 30 | A17 | **disconnect from A17, connect to +5V** |

Check pin 28 before you power up. If it is left on A17, the EPROM has no supply
voltage and the A17 line is loaded.

The board has no RAM while the EPROM is in. The loader doesn't need any: it
uses no stack, and interrupts stay masked.

## 4. Serial test (SERTEST)

Connect the FTDI cable, open a terminal at 38400 8N1 and power up. You should see:

```
SERTEST 1.0 for core68008: 68681 channel A, 38400 8N1
Type characters to see them echoed, U for a $55 burst, F for FLASHBOOT.
alive 0000
alive 0001
...
```

You get one `alive` line about every second, and LED D5 toggles with it.
LED D6 stays on.
- Every key you type comes back as a line like `rx 'A' $41`. If the line ends
  with `status error $xx`, the 68681 saw an error: $10 overrun, $20 parity,
  $40 framing (wrong baud rate), $80 break.
- `U` sends 256 `U` characters. That makes a clean square wave on TxDA
  (52 µs per bit at 38400 baud) to look at with the scope.

What the result tells you:
- **Nothing at all, and D6 off:** the CPU isn't running from the EPROM. Check the
  three +5V wires, the GAL1 swap and the EPROM speed.
- **D6 on but no text:** check TxDA, the FTDI wiring and the baud rate.
- **Text appears but typed keys do nothing:** check RxDA, and RTS/CTS on the FTDI side.

## 5. Program the flash

In SERTEST, type `F`. FLASHBOOT starts and shows:

```
FLASHBOOT 1.0 for core68008 (27128 in the SRAM socket)
ID BFB6
>
```

If the ID isn't BFB6, the flash isn't responding to commands.
Check its /WE (pin 31 = ~WR) and /CE.

You don't have to do this step by hand. Close the terminal and then run:

```
make send PORT=/dev/cu.usbserial-XXXX
```

The script reads the ID and erases the whole chip (it then checks that it is
blank). It programs the two used ranges of `monitor.bin` ($80000-$859FF, then
$A0000-$A36FF; about 10 s). Then it compares a checksum of each range, and of the
whole 256K, with the file. It ends with `Done: the flash matches ...`.
Use `python3 flashboot.py PORT IMAGE --verify` to compare again without
programming. Use `--no-rtscts` if the host hangs waiting for CTS: the loader keeps up
without flow control.

Here's a capture of an actual run:

```
% make send PORT=/dev/cu.usbserial-A901ROZL
python3 flashboot.py /dev/cu.usbserial-A901ROZL ../monitor/monitor.bin
Waiting for FLASHBOOT (press reset on the board if nothing happens)...
  ID BFB6
Chip erase and blank check...
  Erasing... OK
Programming $80000-$859FF (23040 bytes)...
  100%    4.2 s
  OK
Programming $A0000-$A36FF (14080 bytes)...
  100%    0.0 s
  OK
Verifying...
  sum $00000+$05A00: board 001A575F, file 001A575F ok
  sum $20000+$03700: board 00129428, file 00129428 ok
  sum of all 256K: board 03987C87, file 03987C87 ok
Done: the flash matches ../monitor/monitor.bin.
```

Commands for typing by hand on the terminal: `I` shows the ID, `s` gives the sum of
all 256K, `H` shows help. Do not type `E`, `P` or `S` by hand: `E` erases
the whole flash immediately, and `P` and `S` expect binary arguments.

## 6. Back to normal

Power off. Take the EPROM out, remove the three +5V wires, and put the
AS6C4008 back with its original wiring (A14, ~WR, A17). Then:

```
cd ../gal && make prog-decode
```

The monitor starts from flash, at 38400 baud as usual.

## Testing

This was tested in a copy of the `monitor/test/emu` board model. The copy had an
SST39SF020A command and status model (unlock sequences, ID, chip erase with
DQ6 toggle, byte program with DQ7 data polling and busy timing) and the
decode_boot map: EPROM reads only, no RAM. A flash full of random data was
erased and programmed with monitor.bin, and the result was byte-identical, both
with and without RTS/CTS flow control (0 receive overruns). The combined
eprom.bin was tested too: SERTEST echo, alive lines and the U burst, then
flashboot.py starting FLASHBOOT with F and programming the flash. The real 27128 timing
and the wiring above have not been tested on the board.

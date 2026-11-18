; mon68k.inc - MON68K TRAP #15 interface for user programs
;
;   moveq   #FN,d0          ; function number in D0.W
;   ...arguments in D1/D2/A0/A1...
;   trap    #15             ; result in D0.L, other registers preserved
;
; See MONITOR.md for the full description.

MON_EXIT        equ     0               ; D1 = exit code; back to the monitor prompt
MON_GETC        equ     1               ; -> D0 = character, waits (-1 if Ctrl-C/BREAK)
MON_PUTC        equ     2               ; D1.B = character
MON_PUTS        equ     3               ; A0 -> NUL-terminated string
MON_KBHIT       equ     4               ; -> D0 = number of characters waiting
MON_GETLINE     equ     5               ; A0 = buffer, D1.W = size -> D0 = length, -1 if aborted
MON_PUTHEX      equ     6               ; D1.L = value, D2.W = number of digits 1-8
MON_PUTDEC      equ     7               ; D1.L = unsigned value
MON_CRLF        equ     8
MON_SETVEC      equ     9               ; D1.W = vector 2-255, A0 = handler -> D0 = old handler
MON_GETVEC      equ     10              ; D1.W = vector 0-255 -> D0 = handler
MON_ABORTCTL    equ     11              ; D1.B = 0: Ctrl-C off, 1: on -> D0 = old setting
MON_LED         equ     12              ; D1 bit 0 = user LED D5 (68681 OP6)
MON_DISASM      equ     13              ; A0 = address, A1 = 64-byte buffer -> D0 = length in bytes
MON_INFO        equ     14              ; -> A0 = info block, D0 = version
MON_GETCNB      equ     15              ; -> D0 = character, or -1 if none waiting

; MONCALL fn : call a monitor function (D0 is overwritten with the result)
MONCALL         macro
                moveq   #\1,d0
                trap    #15
                endm

; info block offsets (MON_INFO)
MI_USERRAM      equ     0               ; first free RAM byte ($01000)
MI_RAMTOP       equ     4               ; end of RAM, exclusive ($80000)
MI_SSP          equ     8               ; default supervisor stack
MI_USP          equ     12              ; default user stack
MI_WINDOW       equ     16              ; Junior bus window ($C0000)
MI_DUART        equ     20              ; 68681 base ($F0000)
MI_DUARTISR     equ     24              ; monitor's 68681 interrupt routine
MI_DUARTVEC     equ     28              ; word: its vector number (64)
MI_VERSION      equ     30              ; word

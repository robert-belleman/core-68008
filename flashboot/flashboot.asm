;-----------------------------------------------------------------------------
; FLASHBOOT: in-circuit programmer for the SST39SF020A on the core68008 board
;
; Runs from a 27128 EPROM (16K) plugged into the SRAM socket, with GAL1
; programmed with gal/decode_boot.jed (EPROM reads at $00000, flash at
; $80000-$BFFFF for reads and writes). See README.md for the wiring.
;
; There is NO RAM while the EPROM is fitted, so this program never uses the
; stack: subroutines are called with CALL (return address in A6) and return
; with JMP (A6); they do not call further subroutines. Interrupts stay masked.
;
; Serial: 68681 channel A, 38400 8N1, RxRTS flow control (as the monitor).
; Every reply ends with CR LF and then '>' when the next command can be sent.
;
; Commands:
;   I               show the flash ID (SST39SF020A = BFB6)
;   E               chip erase, then blank check of all 256K
;   P o o o n n n   program: 24-bit offset and 24-bit length (big-endian,
;                   binary), followed by exactly that many data bytes. $FF
;                   bytes are skipped (already erased). Every byte is checked.
;   S o o o n n n   32-bit sum of the bytes in the range, 8 hex digits
;   s               32-bit sum of the whole flash
;   H or ?          help
;
; The code from start onwards must stay position independent (PC-relative
; only) and below $1C00 bytes: sertest.asm copies it to $2000 of eprom.bin.
;
; Register use: A3 = flash base, A4 = DUART, A6 = return address.
;
; Assemble: vasmm68k_mot -m68000 -Fbin -o flashboot.bin -L flashboot.lst flashboot.asm
;-----------------------------------------------------------------------------

DUART           equ     $F0000
FLASH           equ     $80000
FLASH_SIZE      equ     $40000
CMD1            equ     FLASH+$5555     ; SST command addresses
CMD2            equ     FLASH+$2AAA
SST_ID          equ     $BFB6           ; manufacturer BF, device B6

; 68681 register offsets (read / write)
D_MRA           equ     0
D_SRA           equ     1               ; SRA / CSRA
D_CSRA          equ     1
D_CRA           equ     2
D_RHRA          equ     3               ; RHRA / THRA
D_THRA          equ     3
D_ACR           equ     4
D_IMR           equ     5
D_CRB           equ     10
D_OPCR          equ     13
D_SOPR          equ     14
D_ROPR          equ     15

SR_RXRDY        equ     0
SR_TXRDY        equ     2

MR1A_VAL        equ     $93             ; RxRTS on, char errors, no parity, 8 bits
MR2A_VAL        equ     $07             ; normal, no TxRTS, no CTS gating, 1 stop
BAUD_ACR        equ     $00             ; baud rate set 1
BAUD_CSR        equ     $CC             ; 38400 Rx and Tx
OP_RTS          equ     $01             ; OP0
OP_LED_USER     equ     $40             ; OP6 -> D5
OP_LED_MON      equ     $80             ; OP7 -> D6

POLL_TIMEOUT    equ     400000          ; erase: about 3 s of polling
PROG_TIMEOUT    equ     2000            ; byte program: about 10 ms (needs 20 us)

;------------------------------------------------------------------ macros
; PUTC: send D0.B (waits for the transmitter)
PUTC            macro
.w\@            btst    #SR_TXRDY,D_SRA(a4)
                beq.s   .w\@
                move.b  d0,D_THRA(a4)
                endm

; GETC: receive one byte into D0.B; ORs the error bits of SRA into D5
GETC            macro
.w\@            move.b  D_SRA(a4),d0
                btst    #SR_RXRDY,d0
                beq.s   .w\@
                andi.b  #$F0,d0
                or.b    d0,d5
                move.b  D_RHRA(a4),d0
                endm

; CALL sub: call a leaf subroutine, return address in A6
CALL            macro
                lea     .r\@(pc),a6
                bra     \1
.r\@
                endm

; PRINT label: send the zero-terminated string at label
PRINT           macro
                lea     \1(pc),a1
                CALL    puts
                endm

; UNLOCK cmd: SST three-byte command sequence
UNLOCK          macro
                move.b  #$AA,CMD1
                move.b  #$55,CMD2
                move.b  #\1,CMD1
                endm

;------------------------------------------------------------------ vectors
                org     0
                dc.l    $00080000               ; SSP (there is no RAM)
                dc.l    start                   ; PC
                rept    254
                dc.l    fault
                endr

;------------------------------------------------------------------ reset
start:
                move.w  #$2700,sr
                lea     FLASH,a3
                lea     DUART,a4

                move.b  #0,D_IMR(a4)
                move.b  #$0A,D_CRA(a4)          ; Rx and Tx disabled
                move.b  #$20,D_CRA(a4)          ; reset receiver
                move.b  #$30,D_CRA(a4)          ; reset transmitter
                move.b  #$40,D_CRA(a4)          ; reset error status
                move.b  #$50,D_CRA(a4)          ; reset break
                move.b  #$10,D_CRA(a4)          ; MR pointer -> MR1A
                move.b  #MR1A_VAL,D_MRA(a4)
                move.b  #MR2A_VAL,D_MRA(a4)
                move.b  #BAUD_ACR,D_ACR(a4)
                move.b  #BAUD_CSR,D_CSRA(a4)
                move.b  #0,D_OPCR(a4)
                move.b  #OP_LED_USER,D_ROPR(a4) ; D5 off
                move.b  #OP_RTS|OP_LED_MON,D_SOPR(a4) ; RTS on, D6 on
                move.b  #$0A,D_CRB(a4)
                move.b  #$05,D_CRA(a4)          ; Rx and Tx enabled

                PRINT   s_banner
                bra     cmd_id

;------------------------------------------------------------------ command loop
prompt:
                PRINT   s_prompt
.get            GETC
                cmpi.b  #'I',d0
                beq     cmd_id
                cmpi.b  #'i',d0
                beq     cmd_id
                cmpi.b  #'E',d0
                beq     cmd_erase
                cmpi.b  #'P',d0
                beq     cmd_prog
                cmpi.b  #'S',d0
                beq     cmd_sum
                cmpi.b  #'s',d0
                beq     cmd_sumall
                cmpi.b  #'H',d0
                beq     cmd_help
                cmpi.b  #'h',d0
                beq     cmd_help
                cmpi.b  #'?',d0
                beq     cmd_help
                cmpi.b  #13,d0                  ; ignore CR and LF
                beq     .get
                cmpi.b  #10,d0
                beq     .get
                PRINT   s_what
                bra     prompt

cmd_help:
                PRINT   s_help
                bra     prompt

;------------------------------------------------------------------ I
cmd_id:
                UNLOCK  $90                     ; software ID entry
                moveq   #0,d1
                move.b  (a3),d1                 ; manufacturer
                lsl.w   #8,d1
                move.b  1(a3),d1                ; device
                move.b  #$F0,(a3)               ; ID exit
                move.l  d1,d7
                PRINT   s_id
                move.l  d7,d1
                moveq   #4,d2
                CALL    puthex
                cmpi.w  #SST_ID,d7
                beq.s   .ok
                PRINT   s_badid
                bra     prompt
.ok             PRINT   s_crlf
                bra     prompt

;------------------------------------------------------------------ E
cmd_erase:
                PRINT   s_erasing
                UNLOCK  $80
                UNLOCK  $10                     ; chip erase
                movea.l a3,a2
                CALL    wait_toggle
                tst.l   d4
                bne.s   .blank
                PRINT   s_timeout
                bra     prompt
.blank          movea.l a3,a2
                move.l  #FLASH_SIZE,d6
.chk            cmpi.b  #$FF,(a2)+
                bne.s   .notblank
                subq.l  #1,d6
                bne.s   .chk
                PRINT   s_ok
                bra     prompt
.notblank       PRINT   s_notblank
                move.l  a2,d1
                subq.l  #1,d1
                moveq   #5,d2
                CALL    puthex
                PRINT   s_crlf
                bra     prompt

;------------------------------------------------------------------ P
; D5 = receive error bits, D6 = bytes left, D7 = number of bad bytes,
; A2 = flash address, A5 = first bad address
cmd_prog:
                moveq   #0,d5
                CALL    get24                   ; offset
                move.l  d1,d3
                CALL    get24                   ; length
                move.l  d1,d6
                lea     0(a3,d3.l),a2
                moveq   #0,d7
                suba.l  a5,a5
                tst.l   d6
                beq     .done
.next           GETC
                cmpi.b  #$FF,d0
                beq.s   .skip
                UNLOCK  $A0                     ; byte program
                move.b  d0,(a2)
                move.l  #PROG_TIMEOUT,d4
.poll           cmp.b   (a2),d0                 ; data# polling: equal = done
                beq.s   .skip
                subq.l  #1,d4
                bne.s   .poll
                tst.l   d7                      ; failed: count it
                bne.s   .cnt
                movea.l a2,a5
.cnt            addq.l  #1,d7
.skip           addq.l  #1,a2
                subq.l  #1,d6
                bne     .next
.done           tst.b   d5
                bne.s   .rxerr
                tst.l   d7
                bne.s   .bad
                PRINT   s_ok
                bra     prompt
.rxerr          move.b  #$40,D_CRA(a4)          ; reset error status
                PRINT   s_rxerr
                moveq   #0,d1
                move.b  d5,d1
                moveq   #2,d2
                CALL    puthex
                PRINT   s_crlf
                bra     prompt
.bad            PRINT   s_bad
                move.l  d7,d1
                moveq   #5,d2
                CALL    puthex
                PRINT   s_first
                move.l  a5,d1
                moveq   #5,d2
                CALL    puthex
                PRINT   s_crlf
                bra     prompt

;------------------------------------------------------------------ S / s
cmd_sum:
                moveq   #0,d5
                CALL    get24
                move.l  d1,d3
                CALL    get24
                move.l  d1,d6
                lea     0(a3,d3.l),a2
                bra.s   sum_range
cmd_sumall:
                movea.l a3,a2
                move.l  #FLASH_SIZE,d6
sum_range:
                moveq   #0,d1
                moveq   #0,d0
                tst.l   d6
                beq.s   .out
.add            move.b  (a2)+,d0
                add.l   d0,d1
                subq.l  #1,d6
                bne.s   .add
.out            moveq   #8,d2
                CALL    puthex
                PRINT   s_crlf
                bra     prompt

;------------------------------------------------------------------ subroutines
; puts: send the string at A1. Uses D0, A1.
puts:
.l              move.b  (a1)+,d0
                beq.s   .x
                PUTC
                bra.s   .l
.x              jmp     (a6)

; puthex: send the low D2 hex digits of D1 (D2 = 1..8). Uses D0, D2, D3.
puthex:
                move.l  d1,d3
                moveq   #8,d0
                sub.w   d2,d0
                lsl.w   #2,d0
                rol.l   d0,d3
                subq.w  #1,d2
.l              rol.l   #4,d3
                move.b  d3,d0
                andi.b  #$0F,d0
                addi.b  #'0',d0
                cmpi.b  #'9',d0
                bls.s   .o
                addq.b  #7,d0
.o              PUTC
                dbra    d2,.l
                jmp     (a6)

; get24: receive a 24-bit big-endian number into D1. Uses D0.
get24:
                moveq   #0,d1
                GETC
                move.b  d0,d1
                lsl.l   #8,d1
                GETC
                move.b  d0,d1
                lsl.l   #8,d1
                GETC
                move.b  d0,d1
                jmp     (a6)

; wait_toggle: wait until DQ6 at (A2) stops toggling (erase finished).
; D4 = 0 on time-out. Uses D0, D3, D4.
wait_toggle:
                move.l  #POLL_TIMEOUT,d4
.l              move.b  (a2),d0
                move.b  (a2),d3
                eor.b   d3,d0
                btst    #6,d0
                beq.s   .x
                subq.l  #1,d4
                bne.s   .l
.x              jmp     (a6)

;------------------------------------------------------------------ faults
; Any exception: report and stop. The exception frame went to $7FFxx, where
; nothing is selected for writes, so it is simply lost.
fault:
                move.w  #$2700,sr
                lea     DUART,a4
                lea     s_fault(pc),a1
.l              move.b  (a1)+,d0
                beq.s   .stop
                PUTC
                bra.s   .l
.stop           bra.s   .stop

;------------------------------------------------------------------ strings
s_banner        dc.b    13,10,"FLASHBOOT 1.0 for core68008 (27128 in the SRAM socket)",13,10,0
s_prompt        dc.b    ">",0
s_crlf          dc.b    13,10,0
s_ok            dc.b    "OK",13,10,0
s_what          dc.b    "?",13,10,0
s_id            dc.b    "ID ",0
s_badid         dc.b    " (expected BFB6)",13,10,0
s_erasing       dc.b    "Erasing... ",0
s_timeout       dc.b    "ERR timeout",13,10,0
s_notblank      dc.b    "ERR not blank at ",0
s_rxerr         dc.b    "ERR receive status ",0
s_bad           dc.b    "ERR bad bytes ",0
s_first         dc.b    " first at ",0
s_fault         dc.b    13,10,"FAULT (exception), press reset",13,10,0
s_help          dc.b    "I id, E erase, P program (binary), S sum (binary), s sum all",13,10,0
                even

                dcb.b   $4000-*,$FF             ; pad to the 27128's 16K

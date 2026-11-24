;-----------------------------------------------------------------------------
; SERTEST: serial test ROM for the 27128 EPROM in the SRAM socket
;
; Same set-up as FLASHBOOT (gal/decode_boot.jed in GAL1, EPROM wiring in
; README.md), but it only exercises the 68681 channel A:
;   - banner at reset
;   - "alive nnnn" once a second, LED D5 toggles with it (D6 stays on)
;   - every received character is echoed as  rx 'c' $hh  (with error bits)
;   - U sends 256 'U' characters ($55, a square wave on TxDA for the scope)
;   - F starts FLASHBOOT, which is in the same image at $2000 (so one EPROM
;     holds both and needs no UV erase in between). flashboot.py sends the F
;     itself, so you can run it straight after this test.
;
; 38400 8N1, RxRTS as the monitor. No RAM, no stack, interrupts masked.
;
; Assemble flashboot.bin first, then:
;   vasmm68k_mot -m68000 -Fbin -o eprom.bin -L sertest.lst sertest.asm
;-----------------------------------------------------------------------------

DUART           equ     $F0000

D_MRA           equ     0
D_SRA           equ     1
D_CSRA          equ     1
D_CRA           equ     2
D_RHRA          equ     3
D_THRA          equ     3
D_ACR           equ     4
D_IMR           equ     5
D_CRB           equ     10
D_IVR           equ     12
D_OPCR          equ     13
D_SOPR          equ     14
D_ROPR          equ     15

SR_RXRDY        equ     0
SR_TXRDY        equ     2

MR1A_VAL        equ     $93
MR2A_VAL        equ     $07
BAUD_ACR        equ     $00
BAUD_CSR        equ     $CC
OP_RTS          equ     $01
OP_LED_USER     equ     $40             ; D5
OP_LED_MON      equ     $80             ; D6

FB_BASE         equ     $2000           ; FLASHBOOT code (from flashboot.bin $400)
FB_ENTRY        equ     FB_BASE         ; its start label is at $400 there
ONE_SECOND      equ     85000           ; idle loop passes per second (about 94 clocks each)

PUTC            macro
.w\@            btst    #SR_TXRDY,D_SRA(a4)
                beq.s   .w\@
                move.b  d0,D_THRA(a4)
                endm

CALL            macro
                lea     .r\@(pc),a6
                bra     \1
.r\@
                endm

PRINT           macro
                lea     \1(pc),a1
                CALL    puts
                endm

;------------------------------------------------------------------ vectors
                org     0
                dc.l    $00080000
                dc.l    start
                rept    254
                dc.l    fault
                endr

;------------------------------------------------------------------ reset
; D5 = alive counter, D6 = idle countdown, D7 = LED state
start:
                move.w  #$2700,sr
                lea     DUART,a4

                move.b  #0,D_IMR(a4)
                move.b  #$0A,D_CRA(a4)
                move.b  #$20,D_CRA(a4)
                move.b  #$30,D_CRA(a4)
                move.b  #$40,D_CRA(a4)
                move.b  #$50,D_CRA(a4)
                move.b  #$10,D_CRA(a4)
                move.b  #MR1A_VAL,D_MRA(a4)
                move.b  #MR2A_VAL,D_MRA(a4)
                move.b  #BAUD_ACR,D_ACR(a4)
                move.b  #BAUD_CSR,D_CSRA(a4)
                move.b  #0,D_OPCR(a4)
                move.b  #OP_LED_USER,D_ROPR(a4)
                move.b  #OP_RTS|OP_LED_MON,D_SOPR(a4)
                move.b  #$0A,D_CRB(a4)
                move.b  #$05,D_CRA(a4)

                PRINT   s_banner
                moveq   #0,d5
                moveq   #0,d7

idle:
                move.l  #ONE_SECOND,d6
.poll           move.b  D_SRA(a4),d4
                btst    #SR_RXRDY,d4
                bne.s   got_char
                subq.l  #1,d6
                bne.s   .poll
                ; one second: alive line and LED toggle
                eori.b  #1,d7
                beq.s   .off
                move.b  #OP_LED_USER,D_SOPR(a4)
                bra.s   .msg
.off            move.b  #OP_LED_USER,D_ROPR(a4)
.msg            PRINT   s_alive
                move.l  d5,d1
                moveq   #4,d2
                CALL    puthex
                PRINT   s_crlf
                addq.w  #1,d5
                bra.s   idle

got_char:
                move.b  D_RHRA(a4),d3           ; D4 = SRA before the read
                PRINT   s_rx
                move.b  d3,d0
                cmpi.b  #' ',d0
                blo.s   .dot
                cmpi.b  #$7E,d0
                bls.s   .pr
.dot            moveq   #'.',d0
.pr             PUTC
                PRINT   s_dollar
                moveq   #0,d1
                move.b  d3,d1
                moveq   #2,d2
                CALL    puthex
                andi.b  #$F0,d4                 ; error bits: RB FE PE OE
                beq.s   .noerr
                PRINT   s_err
                moveq   #0,d1
                move.b  d4,d1
                moveq   #2,d2
                CALL    puthex
                move.b  #$40,D_CRA(a4)          ; reset error status
.noerr          PRINT   s_crlf
                cmpi.b  #'F',d3
                beq.s   .fb
                cmpi.b  #'U',d3
                bne     idle
                move.w  #255,d2
                moveq   #'U',d0
.u              PUTC
                dbra    d2,.u
                PRINT   s_crlf
                bra     idle
.fb             jmp     FB_ENTRY

;------------------------------------------------------------------ subroutines
puts:
.l              move.b  (a1)+,d0
                beq.s   .x
                PUTC
                bra.s   .l
.x              jmp     (a6)

; puthex: low D2 hex digits of D1. Uses D0, D2, D3 (D3 saved in A2).
puthex:
                movea.l d3,a2
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
                move.l  a2,d3
                jmp     (a6)

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
s_banner        dc.b    13,10,"SERTEST 1.0 for core68008: 68681 channel A, 38400 8N1",13,10
                dc.b    "Type characters to see them echoed, U for a $55 burst, F for FLASHBOOT.",13,10,0
s_alive         dc.b    "alive ",0
s_rx            dc.b    "rx '",0
s_dollar        dc.b    "' $",0
s_err           dc.b    " status error $",0
s_crlf          dc.b    13,10,0
s_fault         dc.b    13,10,"FAULT (exception), press reset",13,10,0
                even

; FLASHBOOT code: position independent (PC-relative), its vectors are not
; used (all exceptions come here to fault).
                dcb.b   FB_BASE-*,$FF
                incbin  "flashboot.bin",$400,$1C00
                dcb.b   $4000-*,$FF

;=============================================================================
; api.asm - TRAP #15 services for user programs
;
;   D0.W = function number, arguments in D1/D2/A0/A1, result in D0.L.
;   All other registers are preserved. Works from user and supervisor mode
;   (TRAP switches to supervisor mode; the service runs on the caller's
;   supervisor stack and needs about 64 bytes of it). The caller's
;   interrupt mask is kept; with a mask of 5 or more console input is
;   polled instead of interrupt driven.
;   Unknown function: D0.L = -1.
;
;   If Ctrl-C/BREAK/NMI arrived during the call, the program stops in the
;   monitor after the call (PC = the instruction after the TRAP).
;=============================================================================

API_EXIT        equ     0               ; D1 = exit code -> back to the monitor
API_GETC        equ     1               ; -> D0 = character (-1 if interrupted)
API_PUTC        equ     2               ; D1.B = character
API_PUTS        equ     3               ; A0 -> NUL-terminated string
API_KBHIT       equ     4               ; -> D0 = characters waiting
API_GETLINE     equ     5               ; A0 = buffer, D1.W = size -> D0 = length or -1
API_PUTHEX      equ     6               ; D1.L = value, D2.W = digits (1-8)
API_PUTDEC      equ     7               ; D1.L = unsigned value
API_CRLF        equ     8
API_SETVEC      equ     9               ; D1.W = vector (2-255), A0 = handler -> D0 = old
API_GETVEC      equ     10              ; D1.W = vector -> D0 = handler
API_ABORTCTL    equ     11              ; D1.B = 0 off / 1 on (Ctrl-C) -> D0 = old
API_LED         equ     12              ; D1.B bit 0 = user LED (OP6, D5)
API_DISASM      equ     13              ; A0 = address, A1 = buffer (64 bytes) -> D0 = length
API_INFO        equ     14              ; -> A0 = info block, D0 = version ($0100)
API_GETCNB      equ     15              ; -> D0 = character or -1 if none
API_COUNT       equ     16

api_entry:
                cmpi.w  #API_COUNT,d0
                bhs    .bad
                move.l  a6,-(sp)
                move.w  d0,-(sp)                ; keep D0 (EXIT reports it unchanged)
                lea     api_table(pc),a6
                add.w   d0,d0
                adda.w  0(a6,d0.w),a6
                move.w  (sp)+,d0
                jsr     (a6)
                movea.l (sp)+,a6
.ret            tst.b   v_abort
                bne    .abort
                rte
.bad            moveq   #-1,d0
                bra    .ret
.abort          tst.b   v_inmon
                bne    .r
                clr.b   v_abort
                move.w  #V_BREAK,-(sp)          ; stop after the call
                bra     exc_entry
.r              rte

api_table:      dc.w    api_exit-api_table
                dc.w    api_getc-api_table
                dc.w    api_putc-api_table
                dc.w    api_puts-api_table
                dc.w    api_kbhit-api_table
                dc.w    api_getline-api_table
                dc.w    api_puthex-api_table
                dc.w    api_putdec-api_table
                dc.w    api_crlf-api_table
                dc.w    api_setvec-api_table
                dc.w    api_getvec-api_table
                dc.w    api_abortctl-api_table
                dc.w    api_led-api_table
                dc.w    api_disasm-api_table
                dc.w    api_info-api_table
                dc.w    api_getcnb-api_table

api_exit:       addq.l  #4,sp                   ; drop the JSR return
                movea.l (sp)+,a6
                move.w  #V_EXIT,-(sp)           ; trap frame is below
                bra     exc_entry

api_getc:       bra     getc
api_getcnb:     bra     getc_nb
api_kbhit:      bra     kbhit
api_crlf:       bra     crlf

api_putc:       move.l  d1,d0
                bra     putc

api_puts:       bra     puts

api_getline:    bra     getline

api_puthex:     movem.l d1,-(sp)
                move.l  d1,d0
                move.w  d2,d1
                beq    .x
                cmpi.w  #8,d1
                bhi    .x
                bsr     .p
.x              movem.l (sp)+,d1
                moveq   #0,d0
                rts
.p              move.l  d1,-(sp)                ; puthexn pops D1 itself, then returns
                bra     puthexn

api_putdec:     move.l  d1,d0
                bsr     putdec
                moveq   #0,d0
                rts

api_setvec:     cmpi.w  #2,d1
                blo    api_badarg
                cmpi.w  #255,d1
                bhi    api_badarg
                move.l  a1,-(sp)
                move.w  d1,d0
                lsl.w   #2,d0
                movea.w d0,a1                   ; vector address (RAM table)
                move.l  (a1),d0
                move.l  a0,(a1)                 ; one instruction: no interrupt can
                movea.l (sp)+,a1                ; see half a vector
                rts

api_getvec:     cmpi.w  #255,d1
                bhi    api_badarg
                move.l  a1,-(sp)
                move.w  d1,d0
                lsl.w   #2,d0
                movea.w d0,a1
                move.l  (a1),d0
                movea.l (sp)+,a1
                rts

api_badarg:     moveq   #-1,d0
                rts

api_abortctl:   moveq   #0,d0
                move.b  v_abort_en,d0
                andi.b  #1,d0
                tst.b   d1
                sne     v_abort_en
                rts

api_led:        btst    #0,d1
                beq    .off
                move.b  #OP_LED_USER,DUART+D_SOPR
                bra    .x
.off            move.b  #OP_LED_USER,DUART+D_ROPR
.x              moveq   #0,d0
                rts

api_disasm:     movem.l d1-d7/a0-a5,-(sp)
                move.l  a0,d0
                btst    #0,d0
                bne    .bad
                bsr     dis_one                 ; A0 = address, A1 = buffer
                movem.l (sp)+,d1-d7/a0-a5
                rts
.bad            movem.l (sp)+,d1-d7/a0-a5
                bra    api_badarg

api_info:       lea     api_infoblk(pc),a0
                move.l  #$0100,d0
                rts

api_infoblk:    dc.l    USER_RAM                ; first free RAM byte
                dc.l    RAM_TOP                 ; end of RAM (exclusive)
                dc.l    USER_SSP_INIT           ; default SSP
                dc.l    USER_USP_INIT           ; default USP
                dc.l    WIN_BASE                ; Junior bus window
                dc.l    DUART                   ; 68681 base
                dc.l    duart_isr               ; monitor's 68681 interrupt routine
                dc.w    VEC_DUART               ; its vector number
                dc.w    $0100                   ; monitor version

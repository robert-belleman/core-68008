;=============================================================================
; serial.asm - MC68681 channel A console (H4, H5)
;
; Receive: interrupt driven (level 5, vector VEC_DUART) into a 256-byte ring
; buffer v_rxbuf. Only the receive service writes v_rxhead, only the
; consumer writes v_rxtail; both are bytes, so each update is a single
; indivisible write and the 8-bit index wraps at 256 by itself. One slot is
; kept free (head+1 = tail means full).
;
; Flow control: when the ring holds RX_HIWATER characters the RxRDY
; interrupt is disabled, so the 68681's 3-character FIFO fills and its
; RxRTS logic (MR1A[7]=1) negates RTSN (OP0 high), which tells the FTDI
; cable to stop sending (if the host uses RTS/CTS). The consumer re-enables
; the interrupt when the fill drops below RX_LOWATER.
;
; When the caller's interrupt mask is 5 or more (the receive interrupt
; cannot be taken) getc polls the 68681 itself, so console input still
; works from user code that runs with interrupts masked.
;
; Transmit: polled (TxRDY), with a timeout that re-initialises the 68681
; if a user program reset it with the RESET instruction (H3).
;
; Ctrl-C (if v_abort_en) and a received BREAK set v_abort; they are not
; stored in the buffer.
;=============================================================================

; duart_init: full channel A set-up; channel B is left disabled.
; Keeps the contents of the receive ring buffer.
duart_init:
                movem.l d0/a0,-(sp)
                move.w  sr,-(sp)
                ori.w   #$0700,sr
                lea     DUART,a0
                move.b  #0,D_IMR(a0)
                move.b  #CR_RXDIS|CR_TXDIS,D_CRA(a0)
                move.b  #CR_RSTRX,D_CRA(a0)
                move.b  #CR_RSTTX,D_CRA(a0)
                move.b  #CR_RSTERR,D_CRA(a0)
                move.b  #CR_RSTBRK,D_CRA(a0)
                move.b  #CR_RSTMR,D_CRA(a0)
                move.b  #MR1A_VAL,D_MRA(a0)     ; MR pointer -> MR2A
                move.b  #MR2A_VAL,D_MRA(a0)
                move.b  #BAUD_ACR,D_ACR(a0)
                move.b  #BAUD_CSR,D_CSRA(a0)
                move.b  #0,D_OPCR(a0)           ; OP2-OP7 are plain outputs
                move.b  #OP_RTS,D_SOPR(a0)      ; assert RTSN (OP0 low)
                move.b  #VEC_DUART,D_IVR(a0)
                move.b  #CR_RXDIS|CR_TXDIS,D_CRB(a0)
                move.b  #CR_RXEN|CR_TXEN,D_CRA(a0)
                move.b  #1<<IM_RXRDYA,d0
                move.b  d0,v_imr
                move.b  d0,D_IMR(a0)
                move.w  (sp)+,sr
                movem.l (sp)+,d0/a0
                rts

; duart_check: re-initialise the 68681 if it was reset (IVR is $0F after a
; reset, H3). Called on every monitor entry and on a transmit timeout.
duart_check:
                cmpi.b  #VEC_DUART,DUART+D_IVR
                beq    .ok
                bsr     duart_init
.ok             rts

;----------------------------------------------------------------- output
; putc: send D0.B. All registers preserved.
putc:
                movem.l d1/a0,-(sp)
                lea     DUART,a0
                move.l  #TX_TIMEOUT,d1
.w              btst    #SR_TXRDY,D_SRA(a0)
                bne    .rdy
                subq.l  #1,d1
                bne    .w
                bsr    duart_check             ; transmitter dead: was the 68681 reset?
                move.l  #TX_TIMEOUT,d1
.w2             btst    #SR_TXRDY,D_SRA(a0)
                bne    .rdy
                subq.l  #1,d1
                bne    .w2
                bra    .x                      ; still not ready: drop the character
.rdy            move.b  d0,D_THRA(a0)
.x              movem.l (sp)+,d1/a0
                rts

; tx_drain: wait until the transmitter is empty (TxEMT), with a timeout.
tx_drain:
                move.l  d1,-(sp)
                move.l  #TX_TIMEOUT,d1
.w              btst    #SR_TXEMT,DUART+D_SRA
                bne    .e
                subq.l  #1,d1
                bne    .w
.e              move.l  (sp)+,d1
                rts

;------------------------------------------------------------------ input
; rx_service: move every character waiting in the 68681 FIFO into the ring
; buffer. Must be called with the receive interrupt unable to occur (from
; the ISR, or with the mask at 5 or more). Uses D0, D1, A0, A1.
rx_service:
                lea     DUART,a0
.loop           move.b  D_SRA(a0),d0            ; status of the character at the FIFO top
                btst    #SR_RXRDY,d0
                beq    .done
                move.b  D_RHRA(a0),d1           ; pop it
                tst.b   d0
                bmi    .brk                    ; SR_RB: received break
                btst    #SR_OE,d0
                beq    .noovr
                move.b  #CR_RSTERR,D_CRA(a0)    ; overrun: earlier characters were lost
                bset    #1,v_rxflags
.noovr          andi.b  #(1<<SR_PE)|(1<<SR_FE),d0
                beq    .good
                bset    #2,v_rxflags            ; framing/parity error: drop it
                bra    .loop
.good           cmpi.b  #3,d1                   ; Ctrl-C
                bne    .store
                tst.b   v_abort_en
                beq    .store
                st      v_abort
                bra    .loop
.store          moveq   #0,d0
                move.b  v_rxhead,d0
                lea     v_rxbuf,a1
                move.b  d1,0(a1,d0.w)
                addq.b  #1,d0
                cmp.b   v_rxtail,d0
                beq    .full
                move.b  d0,v_rxhead             ; publish the character
                sub.b   v_rxtail,d0             ; fill level 0..255
                cmpi.b  #RX_HIWATER,d0
                blo    .loop
                bclr    #IM_RXRDYA,v_imr        ; nearly full: let the FIFO and RTS hold the rest
                move.b  v_imr,D_IMR(a0)
                bra    .done
.full           bset    #0,v_rxflags            ; ring full: character lost
                bra    .loop
.brk            st      v_abort                 ; BREAK always requests an abort
                move.b  #CR_RSTBRK,D_CRA(a0)
                bra    .loop
.done           rts

; rx_resume: re-enable the receive interrupt once the ring has drained.
rx_resume:
                btst    #IM_RXRDYA,v_imr
                bne    .e
                move.l  d0,-(sp)
                move.b  v_rxhead,d0
                sub.b   v_rxtail,d0
                cmpi.b  #RX_LOWATER,d0
                bhs    .x
                move.w  sr,-(sp)
                ori.w   #$0700,sr
                bset    #IM_RXRDYA,v_imr
                move.b  v_imr,DUART+D_IMR
                move.w  (sp)+,sr
.x              move.l  (sp)+,d0
.e              rts

; rx_poll: if the receive interrupt is masked at the current priority, read
; the 68681 FIFO here. Uses nothing (saves what rx_service uses).
rx_poll:
                move.l  d0,-(sp)
                move.w  sr,d0
                andi.w  #$0700,d0
                cmpi.w  #$0400,d0
                bls    .e                      ; mask 0..4: the ISR does the work
                movem.l d1/a0-a1,-(sp)
                bsr     rx_service
                movem.l (sp)+,d1/a0-a1
.e              move.l  (sp)+,d0
                rts

; kbhit: D0.L = number of characters waiting (0 = none). Flags set from D0.
kbhit:
                bsr    rx_poll
                moveq   #0,d0
                move.b  v_rxhead,d0
                sub.b   v_rxtail,d0
                rts

; getc_nb: D0.L = next character, or -1 if none is waiting.
getc_nb:
                bsr    kbhit
                bne    getc_take
                moveq   #-1,d0
                rts

; getc: wait for a character, D0.L = character. Returns -1 if an abort
; request (v_abort) arrives while waiting; v_abort is left set.
getc:
.w              tst.b   v_abort
                bne    .ab
                bsr    kbhit
                beq    .w
                bra    getc_take
.ab             moveq   #-1,d0
                rts

getc_take:      move.l  a0,-(sp)
                lea     v_rxbuf,a0
                moveq   #0,d0
                move.b  v_rxtail,d0
                move.b  0(a0,d0.w),d0
                addq.b  #1,v_rxtail             ; release the slot
                bsr    rx_resume
                movea.l (sp)+,a0
                rts

; rx_flush: discard everything received so far
rx_flush:
                move.l  d0,-(sp)
.l              bsr     getc_nb
                tst.l   d0
                bpl    .l
                move.l  (sp)+,d0
                rts

;-------------------------------------------------------- 68681 interrupt
; Level 5, vector VEC_DUART (68681 IVR, IACK5). Only RxRDYA is enabled.
duart_isr:
                movem.l d0-d1/a0-a1,-(sp)
                bsr     rx_service
                movem.l (sp)+,d0-d1/a0-a1
                tst.b   v_abort
                bne    .abort
                rte
.abort:         ; an abort was requested: break into the monitor if a user
                ; program was interrupted outside the monitor's ROM code.
                ; Otherwise leave v_abort set; the monitor or the TRAP #15
                ; return path acts on it at a safe point.
                tst.b   v_inmon
                bne    .x
                cmpi.l  #ROM_BASE,2(sp)
                blo    .user
                cmpi.l  #ROM_TOP,2(sp)
                blo    .x
.user           clr.b   v_abort
                move.w  #V_BREAK,-(sp)
                bra     exc_entry
.x              rte

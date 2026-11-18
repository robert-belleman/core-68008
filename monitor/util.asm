;=============================================================================
; util.asm - console output and formatting helpers
;
; Unless stated otherwise every routine preserves all registers except the
; documented outputs. The s_xxx routines append text to a buffer at A1 and
; advance A1 (no terminator is written until s_end).
;=============================================================================

; puts_inline: print the NUL-terminated string that follows the BSR, then
; return to the first even address after it. Used by the PRINT macro.
puts_inline:
                movem.l d0/a0,-(sp)
                movea.l 8(sp),a0
.l              move.b  (a0)+,d0
                beq    .e
                bsr     putc
                bra    .l
.e              move.l  a0,d0
                addq.l  #1,d0
                andi.w  #$FFFE,d0               ; round up to an even address
                move.l  d0,8(sp)
                movem.l (sp)+,d0/a0
                rts

; puts: print the NUL-terminated string at A0.
puts:
                movem.l d0/a0,-(sp)
.l              move.b  (a0)+,d0
                beq    .e
                bsr     putc
                bra    .l
.e              movem.l (sp)+,d0/a0
                rts

crlf:           move.l  d0,-(sp)
                moveq   #13,d0
                bsr     putc
                moveq   #10,d0
                bsr     putc
                move.l  (sp)+,d0
                rts

putspace:       move.l  d0,-(sp)
                moveq   #' ',d0
                bsr     putc
                move.l  (sp)+,d0
                rts

; putspaces: print D1.W spaces (D1 <= 0 prints none)
putspaces:      move.l  d1,-(sp)
.l              subq.w  #1,d1
                bmi    .e
                bsr     putspace
                bra    .l
.e              move.l  (sp)+,d1
                rts

; puthex2/4/5/8: print the low 2/4/5/8 hex digits of D0.
puthex2:        move.l  d1,-(sp)
                moveq   #2,d1
                bra    puthexn
puthex4:        move.l  d1,-(sp)
                moveq   #4,d1
                bra    puthexn
puthex5:        move.l  d1,-(sp)
                moveq   #5,d1
                bra    puthexn
puthex8:        move.l  d1,-(sp)
                moveq   #8,d1
puthexn:        ; D1 = digits (1..8); D1 saved by caller entry above
                movem.l d0/d2,-(sp)
                move.l  d0,d2
                ; rotate so that the first digit wanted is in bits 31-28
                moveq   #8,d0
                sub.w   d1,d0                   ; 8-n
                lsl.w   #2,d0                   ; *4
                lsl.l   d0,d2
                subq.w  #1,d1
.l              rol.l   #4,d2
                move.b  d2,d0
                bsr    hexdigit
                bsr     putc
                dbra    d1,.l
                movem.l (sp)+,d0/d2
                move.l  (sp)+,d1
                rts

; hexdigit: low nibble of D0 -> ASCII in D0.B (D0 high bits cleared)
hexdigit:       andi.l  #$0F,d0
                move.b  .tab(pc,d0.w),d0
                rts
.tab            dc.b    "0123456789ABCDEF"

; putdec: print D0.L as an unsigned decimal number.
putdec:         movem.l d0-d2/a0,-(sp)
                lea     v_decbuf+12,a0          ; build digits backwards
                clr.b   -(a0)                   ; (10 digits + NUL fit)
.l              bsr     udiv10                  ; d0 = d0/10, d1 = remainder
                addi.b  #'0',d1
                move.b  d1,-(a0)
                tst.l   d0
                bne    .l
                bsr     puts
                movem.l (sp)+,d0-d2/a0
                rts

; udiv10: D0.L = D0.L / 10 (unsigned), D1.L = remainder. Uses DIVU twice so
; that 32-bit dividends are handled (DIVU is 32/16 -> 16:16 only).
udiv10:         move.l  d2,-(sp)
                moveq   #0,d1
                move.w  d0,d2                   ; low word
                clr.w   d0
                swap    d0                      ; high word
                divu.w  #10,d0                  ; high / 10: quotient.w, remainder in hi word
                move.l  d0,d1                   ; d1.hi = remainder
                move.w  d2,d1                   ; d1 = rem:low
                divu.w  #10,d1                  ; (rem*65536+low)/10, fits in 16 bits
                swap    d0
                move.w  d1,d0                   ; d0 = qhigh:qlow
                clr.w   d1
                swap    d1                      ; d1 = remainder
                move.l  (sp)+,d2
                rts

;--------------------------------------------------------- buffer writers
; s_char: append D0.B at A1
s_char:         move.b  d0,(a1)+
                rts

; s_str: append the NUL-terminated string at A0 (A0 preserved)
s_str:          move.l  a0,-(sp)
.l              move.b  (a0)+,(a1)+
                bne    .l
                subq.l  #1,a1
                movea.l (sp)+,a0
                rts

; s_hex: append D0 as D1.W hex digits (1..8) with a leading '$'
s_hexd:         move.b  #'$',(a1)+
; s_hex: append D0 as D1.W hex digits (1..8)
s_hex:          movem.l d0-d2,-(sp)
                move.l  d0,d2
                moveq   #8,d0
                sub.w   d1,d0
                lsl.w   #2,d0
                lsl.l   d0,d2
                subq.w  #1,d1
.l              rol.l   #4,d2
                move.b  d2,d0
                bsr     hexdigit
                move.b  d0,(a1)+
                dbra    d1,.l
                movem.l (sp)+,d0-d2
                rts

; s_dec: append D0.L as an unsigned decimal number
s_dec:          movem.l d0-d1/a0,-(sp)
                lea     v_decbuf+12,a0
                clr.b   -(a0)
.l              bsr     udiv10
                addi.b  #'0',d1
                move.b  d1,-(a0)
                tst.l   d0
                bne    .l
                bsr     s_str
                movem.l (sp)+,d0-d1/a0
                rts

;--------------------------------------------------------- character class
; toupper: D0.B -> upper case
toupper:        cmpi.b  #'a',d0
                blo    .e
                cmpi.b  #'z',d0
                bhi    .e
                subi.b  #'a'-'A',d0
.e              rts

; hexval: D0.B ASCII -> value 0-15 in D0.L, carry set if not a hex digit
hexval:         bsr    toupper
                cmpi.b  #'0',d0
                blo    .bad
                cmpi.b  #'9',d0
                bls    .dig
                cmpi.b  #'A',d0
                blo    .bad
                cmpi.b  #'F',d0
                bhi    .bad
                subi.b  #'A'-10,d0
                bra    .ok
.dig            subi.b  #'0',d0
.ok             andi.l  #$0F,d0                 ; also clears carry
                rts
.bad            ori.b   #1,ccr                  ; set carry
                rts

;--------------------------------------------------------- LEDs (H6)
led_mon_on:     move.b  #OP_LED_MON,DUART+D_SOPR
                rts
led_mon_off:    move.b  #OP_LED_MON,DUART+D_ROPR
                rts

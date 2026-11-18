;=============================================================================
; srec.asm - Motorola S-record loader (LO) and dumper (DU)
;
; Record: S<type><count><address><data><checksum><CR/LF>
;   count    = number of bytes that follow (address + data + checksum)
;   checksum = ones' complement of the low byte of the sum of count,
;              address and data bytes
;   S0 header (16-bit address, ignored), S1/S2/S3 data with 16/24/32-bit
;   address, S5/S6 record count (16/24-bit), S7/S8/S9 end with a 32/24/16-bit
;   start address. S4 is not defined.
;
; Each record is checked completely (hex digits, count, checksum, nothing
; after the checksum, address + offset without overflow, whole range
; writable and below $FFFFF) BEFORE any of its bytes are written; every
; written byte is read back. A bad record is skipped and counted; loading
; continues until the end record so that the rest of the file is not taken
; as commands. PC is only set when the whole load was error free.
;=============================================================================

; loader state (in v_scratch; the disassembler does not run during LO)
ls_nrec         equ     v_scratch+0     ; data records
ls_nbytes       equ     v_scratch+4
ls_lo           equ     v_scratch+8     ; lowest address written
ls_hi           equ     v_scratch+12    ; highest address written
ls_nerr         equ     v_scratch+16
ls_line         equ     v_scratch+20    ; record number
ls_errline      equ     v_scratch+24
ls_entry        equ     v_scratch+28
ls_count        equ     v_scratch+32    ; value of an S5/S6 record
ls_offset       equ     v_scratch+36
ls_errcode      equ     v_scratch+40    ; word
ls_flags        equ     v_scratch+42    ; byte: bit 0 entry seen, 1 count record seen
ls_type         equ     v_scratch+43    ; byte
ls_sum          equ     v_scratch+44    ; byte

SE_NOTS         equ     1
SE_HEX          equ     2
SE_COUNT        equ     3
SE_CSUM         equ     4
SE_TRAIL        equ     5
SE_RANGE        equ     6
SE_VERIFY       equ     7
SE_TYPE         equ     8
SE_OVF          equ     9

; LO [offset]
cmd_lo:
                moveq   #0,d0
                bsr     opt_expr
                bcc    .o
                moveq   #0,d0
.o              move.l  d0,d1
                bsr     end_args
                lea     v_scratch,a0
                moveq   #48/4-1,d0
.clr            clr.l   (a0)+
                dbra    d0,.clr
                move.l  d1,ls_offset            ; (after clearing the state)
                move.l  #$FFFFFFFF,ls_lo
                PRINT   <"Send the S-record file now (ESC or Ctrl-C cancels)",13,10>

.rec            ; ---- wait for 'S'
                bsr     lo_getc
                cmpi.b  #'S',d0
                beq    .s
                cmpi.b  #'s',d0
                beq    .s
                cmpi.b  #' ',d0                 ; blanks and line ends between records
                bls    .rec
                addq.l  #1,ls_line
                moveq   #SE_NOTS,d0
                bra     .bad
.s              addq.l  #1,ls_line
                clr.b   ls_sum
                bsr     lo_getc                 ; type digit
                subi.b  #'0',d0
                cmpi.b  #9,d0
                bhi     .badtype
                cmpi.b  #4,d0
                beq     .badtype
                move.b  d0,ls_type
                moveq   #0,d6
                lea     .alen(pc),a0
                move.b  0(a0,d0.w),d6           ; address length in bytes
                bsr     lo_byte                 ; count
                bcs     .badhex
                moveq   #0,d5
                move.b  d0,d5
                sub.w   d6,d5
                subq.w  #1,d5                   ; d5 = number of data bytes
                bmi     .badcount
                moveq   #0,d7                   ; address
                move.w  d6,d4
                subq.w  #1,d4
.ab             bsr     lo_byte
                bcs     .badhex
                lsl.l   #8,d7
                move.b  d0,d7
                dbra    d4,.ab
                lea     v_recbuf,a2             ; data
                move.w  d5,d4
                bra    .dbe
.db             bsr     lo_byte
                bcs     .badhex
                move.b  d0,(a2)+
.dbe            dbra    d4,.db
                bsr     lo_byte                 ; checksum
                bcs     .badhex
                cmpi.b  #$FF,ls_sum             ; sum of everything incl. checksum
                bne     .badsum
.trail          bsr     lo_getc                 ; only blanks may follow
                cmpi.b  #13,d0
                beq    .eol
                cmpi.b  #10,d0
                beq    .eol
                cmpi.b  #' ',d0
                beq    .trail
                cmpi.b  #9,d0
                beq    .trail
                moveq   #SE_TRAIL,d0
                bra     .bad

.alen           dc.b    2,2,3,4,0,2,3,4,3,2
                even

.eol            ; ---- record is well formed: act on it
                moveq   #0,d0
                move.b  ls_type,d0
                beq     .rec                    ; S0 header
                cmpi.b  #3,d0
                bls    .data
                cmpi.b  #6,d0
                bls    .cnt
                ; S7/S8/S9: end of file
                add.l   ls_offset,d7
                bcs    .endovf
                move.l  d7,ls_entry
                bset    #0,ls_flags
                bra     .summary
.endovf         moveq   #SE_OVF,d0
                bsr     .note
                bra     .summary
.cnt            move.l  d7,ls_count             ; S5/S6
                bset    #1,ls_flags
                bra     .rec
.data           tst.w   d5
                beq     .counted                ; no data bytes
                add.l   ls_offset,d7
                bcs    .ovf
                move.l  d7,d2
                move.l  d7,d3
                add.l   d5,d3
                bcs    .ovf
                subq.l  #1,d3
                moveq   #ACC_W|ACC_B,d4
                bsr     range_test
                tst.w   d0
                bne    .range
                movea.l d2,a0                   ; write and verify
                lea     v_recbuf,a2
                move.w  d5,d4
                subq.w  #1,d4
.wr             move.b  (a2),(a0)
                move.b  (a0)+,d0
                cmp.b   (a2)+,d0
                bne    .verify
                dbra    d4,.wr
                cmp.l   ls_lo,d2
                bhs    .h
                move.l  d2,ls_lo
.h              cmp.l   ls_hi,d3
                bls    .b
                move.l  d3,ls_hi
.b              add.l   d5,ls_nbytes
.counted        addq.l  #1,ls_nrec
                bra     .rec
.ovf            moveq   #SE_OVF,d0
                bra    .note_rec
.range          moveq   #SE_RANGE,d0
                bra    .note_rec
.verify         moveq   #SE_VERIFY,d0
.note_rec       bsr    .note
                addq.l  #1,ls_nrec
                bra     .rec

; malformed record: note the error, skip the rest of the line
.badtype        moveq   #SE_TYPE,d0
                bra    .bad
.badhex         moveq   #SE_HEX,d0
                bra    .bad
.badcount       moveq   #SE_COUNT,d0
                bra    .bad
.badsum         moveq   #SE_CSUM,d0
.bad            bsr    .note
.skip           bsr     lo_getc
                cmpi.b  #13,d0
                beq     .rec
                cmpi.b  #10,d0
                beq     .rec
                bra    .skip

; .note: count an error with code D0; remember the first one
.note           tst.l   ls_nerr
                bne    .n2
                move.w  d0,ls_errcode
                move.l  ls_line,ls_errline
.n2             addq.l  #1,ls_nerr
                rts

.summary        ; let trailing line ends arrive, then drop them
                bsr     lo_drain
                bsr     lo_report
                tst.l   ls_nerr
                bne    .x
                btst    #0,ls_flags
                beq    .x
                move.l  ls_entry,d0             ; set PC if the entry is usable
                cmpi.l  #ADDR_MAX,d0
                bhi    .noent
                btst    #0,d0
                bne    .noent
                move.l  d0,d2
                move.l  d0,d3
                addq.l  #1,d3
                moveq   #ACC_X,d4
                bsr     range_test
                tst.w   d0
                bne    .noent
                move.l  d2,r_pc
                PRINT   "PC set to $"
                move.l  d2,d0
                bsr     puthex5
                bsr     crlf
                rts
.noent          PRINT   "Entry address $"
                move.l  ls_entry,d0
                bsr     puthex8
                PRINT   <" not used (odd or not executable); PC unchanged",13,10>
.x              rts

; lo_getc: next character; ESC or an abort cancels the load
lo_getc:
                bsr     getc
                tst.l   d0
                bmi    lo_cancel
                cmpi.b  #27,d0
                beq    lo_cancel
                rts
lo_cancel:      lea     MON_STACK_TOP,sp        ; leave from any depth
                clr.b   v_abort
                bsr     crlf
                PRINT   <"Load cancelled",13,10>
                bsr     lo_report
                bra     cmd_loop

; lo_byte: two hex digits -> D0.B, added to ls_sum; carry set if not hex
lo_byte:
                move.l  d1,-(sp)
                bsr    lo_getc
                bsr     hexval
                bcs    .x
                move.b  d0,d1
                lsl.b   #4,d1
                bsr    lo_getc
                bsr     hexval
                bcs    .x
                or.b    d1,d0
                add.b   d0,ls_sum
                andi.b  #$FE,ccr
.x              move.l  (sp)+,d1
                rts

; lo_drain: discard CR/LF/blank characters that arrive within ~50 ms
lo_drain:
                move.l  d1,-(sp)
.w              move.l  #4000,d1
.l              bsr     getc_nb
                tst.l   d0
                bpl    .got
                subq.l  #1,d1
                bne    .l
                move.l  (sp)+,d1
                rts
.got            bra    .w

; lo_report: print the load summary
lo_report:
                move.l  ls_nbytes,d0
                bsr     putdec
                PRINT   " bytes in "
                move.l  ls_nrec,d0
                bsr     putdec
                PRINT   " data records"
                tst.l   ls_nbytes
                beq    .nr
                PRINT   ", $"
                move.l  ls_lo,d0
                bsr     puthex5
                PRINT   "-$"
                move.l  ls_hi,d0
                bsr     puthex5
.nr             bsr     crlf
                btst    #1,ls_flags
                beq    .nc
                move.l  ls_count,d0
                cmp.l   ls_nrec,d0
                beq    .nc
                PRINT   "Warning: S5/S6 record says "
                bsr     putdec
                PRINT   <" data records",13,10>
.nc             tst.l   ls_nerr
                beq    .x
                move.l  ls_nerr,d0
                bsr     putdec
                PRINT   " bad record(s); first is record "
                move.l  ls_errline,d0
                bsr     putdec
                PRINT   ": "
                move.w  ls_errcode,d0
                lea     se_text(pc),a0
                bra    .f2
.f1             tst.b   (a0)+
                bne    .f1
.f2             dbra    d0,.f1
                bsr     puts
                bsr     crlf
                PRINT   <"LOAD FAILED: bad records were not written; PC unchanged",13,10>
.x              rts

se_text         dc.b    0                                       ; 0 unused
                dc.b    "not an S-record (no S)",0              ; 1
                dc.b    "bad hex digit",0                       ; 2
                dc.b    "byte count too small for the type",0   ; 3
                dc.b    "checksum error",0                      ; 4
                dc.b    "characters after the checksum",0       ; 5
                dc.b    "address not writable (or beyond $FFFFF)",0     ; 6
                dc.b    "verify error (no memory there?)",0     ; 7
                dc.b    "S4 or unknown record type",0           ; 8
                dc.b    "address overflow with the offset",0    ; 9
                even

;------------------------------------------------------------ DU
; DU start end [entry]   S0 header, S2 data (16 bytes per record), S5, S8
cmd_du:
                bsr     get_range
                move.l  d2,d5                   ; entry default: start
                bsr     opt_expr
                bcs    .e
                bsr     chk_addr
                move.l  d0,d5
.e              bsr     end_args
                moveq   #ACC_R|ACC_B,d4
                bsr     chk_range
                ; S0 header: address 0000, data "MON68K"
                PRINT   "S0"
                clr.b   ls_sum
                moveq   #2+6+1,d0
                bsr     du_byte
                moveq   #0,d0
                bsr     du_byte
                bsr     du_byte
                lea     .hdr(pc),a0
.h              move.b  (a0)+,d0
                beq    .he
                bsr     du_byte
                bra    .h
.he             bsr     du_end
                moveq   #0,d6                   ; record count
                movea.l d2,a2
.rec            bsr     chk_abort
                move.l  d3,d7                   ; bytes left = end - a2 + 1
                sub.l   a2,d7
                addq.l  #1,d7
                cmpi.l  #16,d7
                bls    .n
                moveq   #16,d7
.n              PRINT   "S2"
                clr.b   ls_sum
                move.l  d7,d0
                addq.l  #4,d0                   ; 3 address bytes + checksum
                bsr     du_byte
                move.l  a2,d0
                swap    d0
                bsr     du_byte
                move.l  a2,d0
                lsr.w   #8,d0
                bsr     du_byte
                move.l  a2,d0
                bsr     du_byte
                move.w  d7,d4
                subq.w  #1,d4
.d              move.b  (a2)+,d0
                bsr     du_byte
                dbra    d4,.d
                bsr     du_end
                addq.l  #1,d6
                move.l  a2,d0
                subq.l  #1,d0
                cmp.l   d3,d0
                blo    .rec
                cmpi.l  #$FFFF,d6               ; S5: number of data records
                bhi    .s8
                PRINT   "S5"
                clr.b   ls_sum
                moveq   #3,d0
                bsr     du_byte
                move.w  d6,d0
                lsr.w   #8,d0
                bsr     du_byte
                move.b  d6,d0
                bsr     du_byte
                bsr     du_end
.s8             PRINT   "S8"                    ; S8: 24-bit entry address
                clr.b   ls_sum
                moveq   #4,d0
                bsr     du_byte
                move.l  d5,d0
                swap    d0
                bsr     du_byte
                move.l  d5,d0
                lsr.w   #8,d0
                bsr     du_byte
                move.l  d5,d0
                bsr     du_byte
                bra     du_end
.hdr            dc.b    "MON68K",0
                even

; du_byte: print D0.B as two hex digits and add it to the checksum
du_byte:        add.b   d0,ls_sum
                bra     puthex2
; du_end: print the checksum and CR LF
du_end:         move.b  ls_sum,d0
                not.b   d0
                bsr     puthex2
                bra     crlf

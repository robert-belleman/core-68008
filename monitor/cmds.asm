;=============================================================================
; cmds.asm - command loop, line editor, parser and commands
;
; Numbers are hexadecimal by default. Prefixes: $ hex, # decimal,
; % binary, 'c' character, .Dn .An .SP .PC .SR .USP .SSP register value.
; Terms can be joined with + and -. Every result is checked for 32-bit
; overflow; addresses are checked against the 20-bit bus ($FFFFF).
;=============================================================================

; ERROR "text": print "Error: text" and restart the command loop
ERROR           macro
                bsr     err_inline
                dc.b    \1,0
                even
                endm

ACC_R           equ     1               ; may be read
ACC_W           equ     2               ; may be written
ACC_B           equ     4               ; block commands allowed (no side effects on read)
ACC_X           equ     8               ; may hold code to execute

;------------------------------------------------------------ command loop
cmd_loop:
                lea     MON_STACK_TOP,sp
                move.w  #$2400,sr
                st      v_inmon
                clr.l   v_recpc
                clr.b   v_abort
                clr.b   v_stepmode
                bsr     led_mon_on
                PRINT   "> "
                lea     v_linebuf,a0
                moveq   #LINEMAX,d1
                bsr     getline
                tst.l   d0
                bmi    cmd_loop
                beq    .empty
                lea     v_linebuf,a0            ; remember it for up-arrow
                lea     v_lastline,a1
.cp             move.b  (a0)+,(a1)+
                bne    .cp
                clr.b   v_repeat
                lea     v_linebuf,a0
                bsr     run_command
                bra    cmd_loop
.empty          moveq   #0,d0                   ; empty line: repeat MD/DI/T/SO
                move.b  v_repeat,d0
                beq    cmd_loop
                lea     v_linebuf,a0            ; (empty argument list)
                lea     cmdtab(pc),a1
                subq.w  #1,d0
                mulu.w  #CMD_SIZE,d0
                movea.l 8(a1,d0.w),a1
                jsr     (a1)
                bra    cmd_loop

cmd_aborted:    PRINT   <"^C",13,10>
                bra     cmd_loop

; err_inline: print "Error: " + the inline string, restart the command loop
err_inline:
                bsr     crlf
                PRINT   "Error: "
                movea.l (sp)+,a0
                bsr     puts
                bsr     crlf
                bra     cmd_loop

; chk_abort: return unless Ctrl-C/BREAK/NMI was seen
chk_abort:      tst.b   v_abort
                bne    cmd_aborted
                rts

;------------------------------------------------------------ line editor
; getline: read a line into the buffer at A0 (size D1.W including the NUL).
; Editing: BS/DEL erase, Ctrl-U erase line, ESC [ A recall the previous
; command (monitor command line only). CR, LF or CR LF end the line.
; Returns D0.L = length, or -1 when an abort (Ctrl-C/BREAK) arrives (the
; v_abort flag is then left set for the caller).
getline:
                movem.l d1-d3/a0-a2,-(sp)
                movea.l a0,a2
                moveq   #0,d2                   ; length
                subq.w  #1,d1                   ; room for characters
.next           bsr     getc
                tst.l   d0
                bmi    .abort
                cmpi.b  #10,d0
                bne    .notlf
                tst.b   v_lastcr                ; LF right after CR: ignore
                beq    .end
                clr.b   v_lastcr
                bra    .next
.notlf          clr.b   v_lastcr
                cmpi.b  #13,d0
                beq    .cr
                cmpi.b  #8,d0
                beq    .bs
                cmpi.b  #127,d0
                beq    .bs
                cmpi.b  #21,d0                  ; Ctrl-U
                beq    .kill
                cmpi.b  #27,d0                  ; ESC
                beq    .esc
                cmpi.b  #' ',d0
                blo    .next                   ; other control characters
                cmpi.b  #126,d0
                bhi    .next
                cmp.w   d1,d2
                bhs    .next                   ; full
                move.b  d0,0(a2,d2.w)
                addq.w  #1,d2
                bsr    .echo
                bra    .next
.bs             tst.w   d2
                beq    .next
                subq.w  #1,d2
                bsr    .rubout
                bra    .next
.kill           tst.w   d2
                beq    .next
                subq.w  #1,d2
                bsr    .rubout
                bra    .kill
.esc            bsr     getc                    ; ESC [ A = cursor up
                cmpi.b  #'[',d0
                bne    .next
                bsr     getc
                cmpi.b  #'A',d0
                bne    .next
                cmpa.l  #v_linebuf,a2           ; only for the command line
                bne    .next
.k2             tst.w   d2                      ; erase what is there
                beq    .rec
                subq.w  #1,d2
                bsr    .rubout
                bra    .k2
.rec            lea     v_lastline,a1
.rl             move.b  (a1)+,d0
                beq    .next
                cmp.w   d1,d2
                bhs    .next
                move.b  d0,0(a2,d2.w)
                addq.w  #1,d2
                bsr    .echo
                bra    .rl
.cr             st      v_lastcr
.end            clr.b   0(a2,d2.w)
                tst.b   v_echo
                beq    .ne
                bsr     crlf
.ne             moveq   #0,d0
                move.w  d2,d0
                movem.l (sp)+,d1-d3/a0-a2
                rts
.abort          clr.b   0(a2,d2.w)
                PRINT   <"^C",13,10>
                moveq   #-1,d0
                movem.l (sp)+,d1-d3/a0-a2
                rts
.echo           tst.b   v_echo
                beq    .x
                bra     putc
.rubout         tst.b   v_echo
                beq    .x
                PRINT   <8," ",8>
.x              rts

;------------------------------------------------------------ dispatcher
CMD             macro                   ; CMD "NAME",handler (name up to 7 chars)
cmdn\@          dc.b    \1
                dcb.b   8-(*-cmdn\@),0
                dc.l    \2
                endm
CMD_SIZE        equ     12

cmdtab:
cmd_md_i        equ     1
                CMD     "MD",cmd_md             ; 1 (v_repeat indices: 1-based)
cmd_di_i        equ     2
                CMD     "DI",cmd_di             ; 2
cmd_t_i         equ     3
                CMD     "T",cmd_t               ; 3
cmd_so_i        equ     4
                CMD     "SO",cmd_so             ; 4
                CMD     "TR",cmd_t
                CMD     "MM",cmd_mm
                CMD     "MF",cmd_mf
                CMD     "MC",cmd_mc
                CMD     "MS",cmd_ms
                CMD     "CM",cmd_cm
                CMD     "LO",cmd_lo
                CMD     "DU",cmd_du
                CMD     "G",cmd_go
                CMD     "GO",cmd_go
                CMD     "GT",cmd_gt
                CMD     "CALL",cmd_call
                CMD     "R",cmd_r
                CMD     "RD",cmd_r
                CMD     "RI",cmd_ri
                CMD     "BR",cmd_br
                CMD     "BC",cmd_bc
                CMD     "HE",cmd_help
                CMD     "HELP",cmd_help
                CMD     "?",cmd_help
                CMD     "IN",cmd_info
                CMD     "INFO",cmd_info
                CMD     "VE",cmd_ve
                dc.b    0                       ; end of table
                even

; run_command: A0 = command line
run_command:
                bsr     skipsp
                tst.b   d0
                beq    .x
                ; command name -> v_tmp (upper case, max 7), then optional .B/.W/.L
                lea     v_tmp,a1
                clr.l   (a1)
                clr.l   4(a1)
                moveq   #0,d1
.w              move.b  (a0),d0
                beq    .wend
                cmpi.b  #' ',d0
                beq    .wend
                cmpi.b  #'.',d0
                beq    .wend
                cmpi.b  #9,d0
                beq    .wend
                addq.l  #1,a0
                cmpi.w  #7,d1
                bhs     .unk
                bsr     toupper
                move.b  d0,0(a1,d1.w)
                addq.w  #1,d1
                bra    .w
.wend           move.b  #1,v_size               ; default byte size
                cmpi.b  #'.',d0
                bne    .find
                addq.l  #1,a0
                move.b  (a0)+,d0
                bsr     toupper
                cmpi.b  #'B',d0
                beq    .find
                move.b  #2,v_size
                cmpi.b  #'W',d0
                beq    .find
                move.b  #4,v_size
                cmpi.b  #'L',d0
                bne    .badsz
.find           lea     cmdtab(pc),a2
                moveq   #1,d2                   ; 1-based index
.l              tst.b   (a2)
                beq    .unk
                move.l  v_tmp,d0
                cmp.l   (a2),d0
                bne    .nx
                move.l  v_tmp+4,d0
                cmp.l   4(a2),d0
                bne    .nx
                movea.l 8(a2),a1
                cmpi.w  #cmd_so_i,d2            ; remember repeatable commands
                bhi    .go
                move.b  d2,v_repeat
.go             jmp     (a1)                    ; A0 -> arguments
.nx             lea     CMD_SIZE(a2),a2
                addq.w  #1,d2
                bra    .l
.x              rts
.unk            ERROR   "unknown command (type HE for help)"
.badsz          ERROR   "size must be .B, .W or .L"

;------------------------------------------------------------ parsing
; skipsp: skip blanks at A0; D0.B = next character (not consumed)
skipsp:
.l              move.b  (a0),d0
                cmpi.b  #' ',d0
                beq    .s
                cmpi.b  #9,d0
                bne    .x
.s              addq.l  #1,a0
                bra    .l
.x              rts

; at_end: Z set if no more arguments
at_end:         move.l  d0,-(sp)
                bsr    skipsp
                tst.b   d0
                movem.l (sp)+,d0                ; keeps the flags
                rts

; end_args: error if anything is left on the line
end_args:       bsr    at_end
                beq    .x
                ERROR   "too many arguments"
.x              rts

; get_expr: D0.L = value of the next expression (error if missing or bad)
get_expr:
                movem.l d1-d2,-(sp)
                bsr     get_term
                move.l  d0,d2
.l              bsr     skipsp
                cmpi.b  #'+',d0
                beq    .add
                cmpi.b  #'-',d0
                beq    .sub
                move.l  d2,d0
                movem.l (sp)+,d1-d2
                rts
.add            addq.l  #1,a0
                bsr     get_term
                add.l   d0,d2
                bcs    .ovf
                bra    .l
.sub            addq.l  #1,a0
                bsr     get_term
                sub.l   d0,d2
                bcs    .ovf
                bra    .l
.ovf            ERROR   "arithmetic overflow (result outside 0..$FFFFFFFF)"

; opt_expr: if an argument follows, D0 = its value and carry clear;
; otherwise carry set.
opt_expr:       bsr     at_end
                bne    get_expr                ; (get_expr ends with carry clear)
                ori.b   #1,ccr
                rts

; get_addr: expression that must be a valid 20-bit address
get_addr:       bsr    get_expr
chk_addr:       cmpi.l  #ADDR_MAX,d0
                bhi    .bad
                rts
.bad            ERROR   "address beyond $FFFFF (20-bit address bus)"

; get_term: one number, character or register value -> D0.L
get_term:
                movem.l d1-d3,-(sp)
                bsr     skipsp
                cmpi.b  #'$',d0
                beq    .hexp
                cmpi.b  #'#',d0
                beq    .dec
                cmpi.b  #'%',d0
                beq    .bin
                cmpi.b  #'.',d0
                beq     .reg
                cmpi.b  #$27,d0                 ; '
                beq     .chr
                move.b  d0,d1
                bsr     hexval
                bcs     .bad
                bra    .hex
.hexp           addq.l  #1,a0
.hex            moveq   #0,d2
                moveq   #0,d3                   ; digit count
.hl             move.b  (a0),d0
                bsr     hexval
                bcs    .hend
                addq.l  #1,a0
                addq.w  #1,d3
                move.l  d2,d1
                andi.l  #$F0000000,d1
                bne     .ovf
                lsl.l   #4,d2
                or.l    d0,d2
                bra    .hl
.hend           tst.w   d3
                beq     .bad
                bra     .done
.dec            addq.l  #1,a0
                moveq   #0,d2
                moveq   #0,d3
.dl             moveq   #0,d0
                move.b  (a0),d0
                subi.b  #'0',d0
                cmpi.b  #9,d0
                bhi    .dend
                addq.l  #1,a0
                addq.w  #1,d3
                cmpi.l  #$19999999,d2           ; d2*10 must not overflow
                bhi     .ovf
                move.l  d2,d1
                lsl.l   #2,d2                   ; *4
                add.l   d1,d2                   ; *5
                add.l   d2,d2                   ; *10 (<= $FFFFFFFA)
                add.l   d0,d2
                bcs     .ovf
                bra    .dl
.dend           tst.w   d3
                beq     .bad
                bra    .done
.bin            addq.l  #1,a0
                moveq   #0,d2
                moveq   #0,d3
.bl             move.b  (a0),d0
                subi.b  #'0',d0
                cmpi.b  #1,d0
                bhi    .bend
                addq.l  #1,a0
                addq.w  #1,d3
                tst.l   d2
                bmi    .ovf
                add.l   d2,d2
                andi.l  #1,d0
                or.l    d0,d2
                bra    .bl
.bend           tst.w   d3
                beq    .bad
                bra    .done
.chr            addq.l  #1,a0
                moveq   #0,d2
                move.b  (a0)+,d2
                beq    .bad
                cmpi.b  #$27,(a0)
                bne    .done
                addq.l  #1,a0                   ; closing quote is optional
                bra    .done
.reg            addq.l  #1,a0
                bsr     parse_reg
                bcs    .badreg
                bsr     reg_get
                move.l  d0,d2
.done           move.l  d2,d0
                movem.l (sp)+,d1-d3
                andi.b  #$FE,ccr                ; carry clear
                rts
.bad            ERROR   "number expected"
.badreg         ERROR   "unknown register (D0-D7, A0-A7, SP, PC, SR, USP, SSP)"
.ovf            ERROR   "number too large (more than 32 bits)"

;------------------------------------------------------------ registers
; Register codes: 0-7 D0-D7, 8-14 A0-A6, 15 A7/SP (active stack pointer),
; 16 PC, 17 SR, 18 USP, 19 SSP
REG_A7          equ     15
REG_PC          equ     16
REG_SR          equ     17
REG_USP         equ     18
REG_SSP         equ     19

; parse_reg: register name at A0 -> D1.W code, carry set if none
parse_reg:
                movem.l d0/d2/a1,-(sp)
                move.b  (a0),d0
                bsr     toupper
                move.b  d0,d2
                move.b  1(a0),d0
                bsr     toupper
                lsl.w   #8,d2
                move.b  d0,d2                   ; d2 = first two letters
                move.b  2(a0),d0
                bsr     toupper
                cmpi.w  #'US',d2
                beq    .us
                cmpi.w  #'SS',d2
                beq    .ss
                cmpi.w  #'SP',d2
                beq    .sp
                cmpi.w  #'PC',d2
                beq    .pc
                cmpi.w  #'SR',d2
                beq    .sr
                move.w  d2,d0
                andi.w  #$00FF,d0
                subi.b  #'0',d0
                cmpi.b  #7,d0
                bhi    .no
                move.w  d0,d1
                lsr.w   #8,d2
                cmpi.b  #'D',d2
                beq    .ok2
                addq.w  #8,d1
                cmpi.b  #'A',d2
                beq    .ok2
.no             movem.l (sp)+,d0/d2/a1
                ori.b   #1,ccr
                rts
.us             cmpi.b  #'P',d0
                bne    .no
                moveq   #REG_USP,d1
                bra    .ok3
.ss             cmpi.b  #'P',d0
                bne    .no
                moveq   #REG_SSP,d1
                bra    .ok3
.sp             moveq   #REG_A7,d1
                bra    .ok2
.pc             moveq   #REG_PC,d1
                bra    .ok2
.sr             moveq   #REG_SR,d1
.ok2            addq.l  #2,a0
                bra    .ok
.ok3            addq.l  #3,a0
.ok             move.b  (a0),d0                 ; must end here
                bsr     isident
                bcc    .no2
                movem.l (sp)+,d0/d2/a1
                andi.b  #$FE,ccr
                rts
.no2            subq.l  #2,a0                   ; (only used for error text)
                bra    .no

; isident: carry clear if D0.B is a letter or digit
isident:        move.l  d0,-(sp)
                bsr     toupper
                cmpi.b  #'0',d0
                blo    .n
                cmpi.b  #'9',d0
                bls    .y
                cmpi.b  #'A',d0
                blo    .n
                cmpi.b  #'Z',d0
                bhi    .n
.y              move.l  (sp)+,d0
                andi.b  #$FE,ccr
                rts
.n              move.l  (sp)+,d0
                ori.b   #1,ccr
                rts

; reg_get: D1.W code -> D0.L value
reg_get:
                cmpi.w  #REG_A7,d1
                blo    .da
                beq    .a7
                cmpi.w  #REG_PC,d1
                beq    .pc
                cmpi.w  #REG_SR,d1
                beq    .sr
                cmpi.w  #REG_USP,d1
                beq    .usp
                move.l  r_ssp,d0
                rts
.da             move.l  a1,-(sp)
                lea     r_d0,a1
                move.w  d1,d0
                lsl.w   #2,d0
                move.l  0(a1,d0.w),d0
                movea.l (sp)+,a1
                rts
.a7             bra     active_sp
.pc             move.l  r_pc,d0
                rts
.sr             moveq   #0,d0
                move.w  r_sr,d0
                rts
.usp            move.l  r_usp,d0
                rts

; reg_set: D1.W code, D0.L value. Validates SR bits and stack pointers.
reg_set:
                movem.l d0-d1/a1,-(sp)
                cmpi.w  #REG_A7,d1
                blo    .da
                beq    .a7
                cmpi.w  #REG_PC,d1
                beq    .pc
                cmpi.w  #REG_SR,d1
                beq    .sr
                cmpi.w  #REG_USP,d1
                beq    .usp
                bra    .ssp
.da             lsl.w   #2,d1
                lea     r_d0,a1
                move.l  d0,0(a1,d1.w)
                bra    .x
.a7             btst    #5,r_sr                 ; S bit selects SSP or USP
                bne    .ssp
.usp            btst    #0,d0
                bne    .odd
                move.l  d0,r_usp
                bra    .x
.ssp            btst    #0,d0
                bne    .odd
                move.l  d0,r_ssp
                bra    .x
.pc             btst    #0,d0
                bne    .odd
                bsr     chk_addr
                move.l  d0,r_pc
                bra    .x
.sr             cmpi.l  #$FFFF,d0
                bhi    .big
                move.w  d0,d1
                andi.w  #$A71F,d1               ; T, S, I2-I0, X N Z V C
                cmp.w   d0,d1
                beq    .srok
                PRINT   <"Note: SR bits 14, 12, 11 and 7-5 do not exist on the 68000; cleared",13,10>
.srok           move.w  d1,r_sr
.x              movem.l (sp)+,d0-d1/a1
                rts
.odd            ERROR   "stack pointers and PC must be even"
.big            ERROR   "SR is 16 bits"

;------------------------------------------------------------ memory regions
; Region table: start, end (inclusive), access flags, name.
REGION          macro
                dc.l    \1,\2
                dc.w    \3
                dc.l    \4
                endm
REG_SIZE        equ     14

regions:
                REGION  $00000,$003FF,ACC_R|ACC_W|ACC_B,rn_vec
                REGION  $00400,$00FFF,ACC_R|ACC_B,rn_mon
                REGION  $01000,$7FFFF,ACC_R|ACC_W|ACC_B|ACC_X,rn_ram
                REGION  $80000,$BFFFF,ACC_R|ACC_B|ACC_X,rn_rom
                REGION  $C0000,$CFFFF,ACC_R|ACC_W|ACC_B|ACC_X,rn_win
                REGION  $D0000,$EFFFF,0,rn_none
                REGION  $F0000,$FFFFF,ACC_R|ACC_W,rn_duart
                dc.l    -1

rn_vec          dc.b    "the vector table ($00000-$003FF)",0
rn_mon          dc.b    "the monitor workspace ($00400-$00FFF)",0
rn_ram          dc.b    "user RAM ($01000-$7FFFF)",0
rn_rom          dc.b    "the flash ROM ($80000-$BFFFF, use an SST programming routine)",0
rn_win          dc.b    "the Junior bus window ($C0000-$CFFFF)",0
rn_none         dc.b    "unmapped space ($D0000-$EFFFF, bus error)",0
rn_duart        dc.b    "the 68681 registers ($F0000-$FFFFF; single accesses with MM only)",0
                even

; chk_range: D2 = start, D3 = end (inclusive), D4.W = required ACC_ flags.
; Errors out naming the first region that does not allow the access.
chk_range:
                movem.l d0/a1,-(sp)
                bsr    range_test
                tst.w   d0
                bne    .err
                movem.l (sp)+,d0/a1
                rts
.err            subq.w  #2,d0
                bmi    .order
                beq    .beyond
                bsr     crlf
                PRINT   "Error: not allowed in "
                movea.l 10(a1),a0
                bsr     puts
                bsr     crlf
                bra     cmd_loop
.order          ERROR   "end address is below start address"
.beyond         ERROR   "range beyond $FFFFF (20-bit address bus)"

; range_test: like chk_range but returns D0.W = 0 (allowed), 1 (end below
; start), 2 (beyond $FFFFF) or 3 (denied; A1 -> region entry, name at 10(A1)).
range_test:
                move.l  d1,-(sp)
                moveq   #1,d0
                cmp.l   d2,d3
                blo    .x
                moveq   #2,d0
                cmpi.l  #ADDR_MAX,d3
                bhi    .x
                lea     regions(pc),a1
.l              move.l  (a1),d0
                bmi    .ok
                move.l  4(a1),d1
                cmp.l   d1,d2                   ; region ends before the range?
                bhi    .n
                cmp.l   d0,d3                   ; region starts after it?
                blo    .ok
                move.w  8(a1),d0
                and.w   d4,d0
                cmp.w   d4,d0
                bne    .deny
.n              lea     REG_SIZE(a1),a1
                bra    .l
.ok             moveq   #0,d0
.x              move.l  (sp)+,d1
                rts
.deny           moveq   #3,d0
                bra    .x

; get_range: two addresses "start end" -> D2, D3 (checked: start <= end)
get_range:
                bsr     get_addr
                move.l  d0,d2
                bsr     get_addr
                move.l  d0,d3
                cmp.l   d2,d3
                blo    .bad
                rts
.bad            ERROR   "end address is below start address"

; chk_bp_addr: Z set if D0 can hold a breakpoint/temporary breakpoint
; (even, in user RAM or the Junior window). All registers preserved.
chk_bp_addr:
                btst    #0,d0
                bne    .no
                cmpi.l  #USER_RAM,d0
                blo    .no
                cmpi.l  #RAM_TOP-2,d0
                bls    .yes
                cmpi.l  #WIN_BASE,d0
                blo    .no
                cmpi.l  #WIN_TOP-2,d0
                bhi    .no
.yes            ori.b   #$04,ccr
                rts
.no             andi.b  #$FB,ccr
                rts

; chk_size_align: D2 = address; error if not aligned for v_size (68000
; rule: word and long accesses need an even address)
chk_size_align:
                cmpi.b  #1,v_size
                beq    .ok
                btst    #0,d2
                bne    .odd
.ok             rts
.odd            ERROR   "odd address: a word/long access here would cause an address error"

; chk_value_size: error if D0 does not fit in v_size bytes
chk_value_size:
                cmpi.b  #4,v_size
                beq    .ok
                move.l  d0,-(sp)
                cmpi.b  #2,v_size
                beq    .w
                andi.l  #$FFFFFF00,d0
                bra    .t
.w              andi.l  #$FFFF0000,d0
.t              movem.l (sp)+,d0
                bne    .big
.ok             rts
.big            ERROR   "value does not fit the size (.B: $FF, .W: $FFFF)"

; mem_read_sz: D0 = value of size v_size at A0 (A0 advanced)
mem_read_sz:    cmpi.b  #2,v_size
                beq    .w
                bhi    .l
                moveq   #0,d0
                move.b  (a0)+,d0
                rts
.w              moveq   #0,d0
                move.w  (a0)+,d0
                rts
.l              move.l  (a0)+,d0
                rts

; mem_write_sz: write D0 (size v_size) at A0, A0 advanced
mem_write_sz:   cmpi.b  #2,v_size
                beq    .w
                bhi    .l
                move.b  d0,(a0)+
                rts
.w              move.w  d0,(a0)+
                rts
.l              move.l  d0,(a0)+
                rts

; put_val_sz: print D0 with 2/4/8 digits for v_size
put_val_sz:     cmpi.b  #2,v_size
                beq     puthex4
                bhi     puthex8
                bra     puthex2

;============================================================ commands

;------------------------------------------------------------ MD
; MD [addr [length]]  hex and ASCII dump; empty line continues
cmd_md:
                bsr     at_end
                bne    .args
                move.l  v_mdaddr,d2
                move.l  v_mdlen,d5
                bra    .go
.args           bsr     get_addr
                move.l  d0,d2
                move.l  v_mdlen,d5
                bsr     opt_expr
                bcs    .go
                move.l  d0,d5
                beq    .zero
.go             bsr     end_args
                move.l  d2,d3                   ; end = start + len - 1, checked
                add.l   d5,d3
                bcs    .big
                subq.l  #1,d3
                cmpi.l  #ADDR_MAX,d3
                bls    .rng
                move.l  #ADDR_MAX,d3            ; clip at the top of the address space
.rng            moveq   #ACC_R|ACC_B,d4
                bsr     chk_range
                movea.l d2,a3
.line           bsr     chk_abort
                move.l  a3,d0
                bsr     puthex5
                bsr     putspace
                bsr     putspace
                movea.l a3,a0
                moveq   #16-1,d6                ; hex part
.hx             move.l  a0,d0
                cmp.l   d3,d0
                bhi    .hpad
                move.b  (a0)+,d0
                bsr     puthex2
                bra    .hs
.hpad           PRINT   "  "
.hs             bsr     putspace
                cmpi.w  #8,d6
                bne    .hn
                bsr     putspace
.hn             dbra    d6,.hx
                bsr     putspace
                movea.l a3,a0
                moveq   #16-1,d6                ; ASCII part (bytes read again:
.as             move.l  a0,d0                   ; RAM/ROM/window only, no side effects)
                cmp.l   d3,d0
                bhi    .aend
                move.b  (a0)+,d0
                cmpi.b  #' ',d0
                blo    .dot
                cmpi.b  #126,d0
                bls    .pr
.dot            moveq   #'.',d0
.pr             bsr     putc
                dbra    d6,.as
.aend           bsr     crlf
                lea     16(a3),a3
                move.l  a3,d0
                subq.l  #1,d0
                cmp.l   d3,d0
                blo    .line
                move.l  d3,d0                   ; continue after the end
                addq.l  #1,d0
                andi.l  #ADDR_MAX,d0
                move.l  d0,v_mdaddr
                move.l  d5,v_mdlen
                rts
.zero           ERROR   "length must be at least 1"
.big            ERROR   "range beyond $FFFFF (20-bit address bus)"

;------------------------------------------------------------ MM
; MM[.B|.W|.L] addr [value ...]
cmd_mm:
                bsr     get_addr
                move.l  d0,d2
                bsr     chk_size_align
                bsr     at_end
                beq    .inter
.vals           bsr     get_expr                ; write the given values
                bsr     chk_value_size
                move.l  d0,d5
                bsr     .check
                movea.l a0,a5                   ; keep the parse pointer
                movea.l d2,a0
                move.l  d5,d0
                bsr     mem_write_sz
                bsr     .verify
                movea.l a5,a0
                moveq   #0,d0
                move.b  v_size,d0
                add.l   d0,d2
                bsr     at_end
                bne    .vals
                rts
.inter          ; interactive: addr  old ? new / Enter = next / - = back / . = end
                bsr     .check
                move.l  d2,d0
                bsr     puthex5
                bsr     putspace
                bsr     putspace
                btst    #2,d6                   ; ACC_B: reading has no side effects
                beq    .noread
                movea.l d2,a0
                bsr     mem_read_sz
                bsr     put_val_sz
                bra    .ask
.noread         PRINT   "(not read)"
.ask            PRINT   " ? "
                lea     v_linebuf,a0
                moveq   #LINEMAX,d1
                bsr     getline
                tst.l   d0
                bmi     cmd_loop
                lea     v_linebuf,a0
                bsr     skipsp
                tst.b   d0
                beq    .next
                cmpi.b  #'.',d0
                beq    .quit
                cmpi.b  #'q',d0
                beq    .quit
                cmpi.b  #'Q',d0
                beq    .quit
                cmpi.b  #'-',d0
                beq    .back
                cmpi.b  #'^',d0
                beq    .back
                bsr     get_expr
                bsr     chk_value_size
                move.l  d0,d5
                bsr     end_args
                movea.l d2,a0
                bsr     mem_write_sz
                bsr     .verify
.next           moveq   #0,d0
                move.b  v_size,d0
                add.l   d0,d2
                cmpi.l  #ADDR_MAX,d2
                bhi    .quit
                bra    .inter
.back           moveq   #0,d0
                move.b  v_size,d0
                sub.l   d0,d2
                bcs    .quit
                bra    .inter
.quit           rts
; .check: range check of one element at D2 (R|W); D6 = region flags
.check          move.l  d2,d3
                moveq   #0,d0
                move.b  v_size,d0
                add.l   d0,d3
                subq.l  #1,d3
                moveq   #ACC_W,d4
                bsr     chk_range
                bsr     region_flags
                move.w  d0,d6
                rts
; .verify: re-read RAM after a write (not for I/O)
.verify         cmpi.l  #RAM_TOP,d2
                bhs    .vx
                movea.l d2,a0
                bsr     mem_read_sz
                cmp.l   d5,d0
                beq    .vx
                PRINT   "Verify error at $"
                move.l  d2,d0
                bsr     puthex5
                PRINT   ": read $"
                movea.l d2,a0
                bsr     mem_read_sz
                bsr     put_val_sz
                bsr     crlf
.vx             rts

; region_flags: D2 = address -> D0.W = its ACC_ flags
region_flags:
                move.l  a1,-(sp)
                lea     regions(pc),a1
.l              move.l  (a1),d0
                bmi    .none
                cmp.l   4(a1),d2
                bls    .f
                lea     REG_SIZE(a1),a1
                bra    .l
.f              move.w  8(a1),d0
                movea.l (sp)+,a1
                rts
.none           moveq   #0,d0
                movea.l (sp)+,a1
                rts

;------------------------------------------------------------ MF
; MF[.B|.W|.L] start end value
cmd_mf:
                bsr     get_range
                bsr     get_expr
                bsr     chk_value_size
                move.l  d0,d5
                bsr     end_args
                bsr     chk_size_align
                moveq   #ACC_W|ACC_B,d4
                bsr     chk_range
                move.l  d3,d0                   ; length must be a multiple of the size
                sub.l   d2,d0
                addq.l  #1,d0
                moveq   #0,d1
                move.b  v_size,d1
                subq.l  #1,d1
                and.l   d1,d0
                beq    .ok
                ERROR   "length is not a multiple of the size"
.ok             movea.l d2,a0
                move.l  d5,d0
.l              bsr     mem_write_sz
                move.l  a0,d1
                andi.w  #$0FFF,d1
                bne    .n
                bsr     chk_abort               ; every 4K
.n              move.l  a0,d1
                subq.l  #1,d1
                cmp.l   d3,d1
                blo    .l
                rts

;------------------------------------------------------------ MC
; MC start end dest   copy (overlapping ranges handled)
cmd_mc:
                bsr     get_range
                bsr     get_addr
                move.l  d0,d5                   ; dest
                bsr     end_args
                moveq   #ACC_R|ACC_B,d4
                bsr     chk_range
                movem.l d2-d3,-(sp)
                move.l  d3,d6
                sub.l   d2,d6                   ; length-1
                move.l  d5,d2
                move.l  d5,d3
                add.l   d6,d3                   ; dest end (no carry: both <= $FFFFF)
                moveq   #ACC_W|ACC_B,d4
                bsr     chk_range
                movem.l (sp)+,d2-d3
                movea.l d2,a0
                movea.l d5,a1
                move.l  d6,d0
                addq.l  #1,d0                   ; byte count
                cmp.l   d2,d5
                bls    .fwd
                cmp.l   d3,d5
                bhi    .fwd
                adda.l  d0,a0                   ; dest inside the source: copy backwards
                adda.l  d0,a1
.bl             move.b  -(a0),-(a1)
                subq.l  #1,d0
                bne    .bl
                rts
.fwd            move.b  (a0)+,(a1)+
                subq.l  #1,d0
                bne    .fwd
                rts

;------------------------------------------------------------ MS
; MS[.B|.W|.L] start end value [value ...]   or   MS start end "text"
cmd_ms:
                bsr     get_range
                moveq   #ACC_R|ACC_B,d4
                bsr     chk_range
                lea     v_scratch,a1            ; pattern bytes
                moveq   #0,d5                   ; pattern length
                bsr     skipsp
                cmpi.b  #'"',d0
                bne    .vals
                addq.l  #1,a0
.str            move.b  (a0)+,d0
                beq    .pend
                cmpi.b  #'"',d0
                beq    .pend
                cmpi.w  #64,d5
                bhs    .long
                move.b  d0,(a1)+
                addq.w  #1,d5
                bra    .str
.vals           bsr     get_expr
                bsr     chk_value_size
                moveq   #0,d1
                move.b  v_size,d1
                add.w   d1,d5
                cmpi.w  #64,d5
                bhi    .long
                cmpi.b  #2,d1                   ; store big-endian
                blo    .vb
                beq    .vw
                move.l  d0,d1
                swap    d1
                move.w  d1,d6
                lsr.w   #8,d6
                move.b  d6,(a1)+
                move.b  d1,(a1)+
.vw             move.w  d0,d6
                lsr.w   #8,d6
                move.b  d6,(a1)+
.vb             move.b  d0,(a1)+
                bsr     at_end
                bne    .vals
.pend           tst.w   d5
                beq    .none
                bsr     end_args
                ; search every byte position from D2 to D3-len+1
                move.l  d3,d6
                sub.l   d2,d6
                addq.l  #1,d6                   ; bytes in range
                cmp.l   d5,d6
                blo    .done
                sub.l   d5,d6                   ; positions - 1
                movea.l d2,a2
                moveq   #0,d7                   ; matches
.pos            movea.l a2,a0
                lea     v_scratch,a1
                move.w  d5,d1
                subq.w  #1,d1
.cmp            cmpm.b  (a0)+,(a1)+
                dbne    d1,.cmp
                bne    .nm
                move.l  a2,d0
                bsr     puthex5
                bsr     crlf
                addq.l  #1,d7
.nm             move.l  a2,d0
                andi.w  #$03FF,d0
                bne    .nn
                bsr     chk_abort
.nn             addq.l  #1,a2
                subq.l  #1,d6
                bcc    .pos
.done           move.l  d7,d0
                bsr     putdec
                PRINT   <" match(es)",13,10>
                rts
.long           ERROR   "pattern longer than 64 bytes"
.none           ERROR   "no search pattern"

;------------------------------------------------------------ CM
; CM start end dest   compare two blocks, list the differences
cmd_cm:
                bsr     get_range
                bsr     get_addr
                move.l  d0,d5
                bsr     end_args
                moveq   #ACC_R|ACC_B,d4
                bsr     chk_range
                movem.l d2-d3,-(sp)
                move.l  d3,d6
                sub.l   d2,d6
                move.l  d5,d2
                move.l  d5,d3
                add.l   d6,d3
                bsr     chk_range
                movem.l (sp)+,d2-d3
                movea.l d2,a2
                movea.l d5,a3
                moveq   #0,d7
.l              move.b  (a2),d0
                cmp.b   (a3),d0
                beq    .n
                addq.l  #1,d7
                move.l  a2,d0
                bsr     puthex5
                PRINT   ": "
                move.b  (a2),d0
                bsr     puthex2
                PRINT   "   "
                move.l  a3,d0
                bsr     puthex5
                PRINT   ": "
                move.b  (a3),d0
                bsr     puthex2
                bsr     crlf
                bsr     chk_abort
.n              addq.l  #1,a2
                addq.l  #1,a3
                subq.l  #1,d6
                bcc    .l
                move.l  d7,d0
                bsr     putdec
                PRINT   <" difference(s)",13,10>
                rts

;------------------------------------------------------------ GO / GT / CALL
; GO [addr]   start or continue the program (with breakpoints)
cmd_go:
                bsr     opt_expr
                bcs    .cont
                bsr     set_pc_checked
.cont           bsr     end_args
                clr.b   v_stepmode
                bra     mon_resume

; set_pc_checked: D0 -> r_pc, error unless even and in executable memory
set_pc_checked:
                movem.l d2-d4,-(sp)
                bsr     chk_addr
                btst    #0,d0
                bne    .odd
                move.l  d0,d2
                move.l  d0,d3
                addq.l  #1,d3
                moveq   #ACC_X,d4
                bsr     chk_range
                move.l  d0,r_pc
                movem.l (sp)+,d2-d4
                rts
.odd            ERROR   "odd address: the 68000 would take an address error"

; GT addr   run until addr (temporary breakpoint)
cmd_gt:
                bsr     get_addr
                bsr     end_args
                bsr     chk_bp_addr
                beq    .ok
                ERROR   "a breakpoint needs an even address in RAM $01000-$7FFFE or $C0000-$CFFFE"
.ok             bsr     bp_set_temp
                clr.b   v_stepmode
                bra     mon_resume

; CALL addr   call a subroutine; its RTS returns to the monitor
cmd_call:
                bsr     get_addr
                bsr     end_args
                move.l  r_pc,d7                 ; keep the current PC
                bsr     set_pc_checked
                bsr     active_sp
                subq.l  #4,d0
                move.l  d0,d2                   ; the return address goes here
                move.l  d0,d3
                addq.l  #3,d3
                btst    #0,d2
                bne    .bad
                cmpi.l  #USER_RAM,d2
                blo    .bad
                cmpi.l  #RAM_TOP-4,d2
                bhi    .bad
                movea.l d2,a0
                move.l  #call_return,(a0)
                btst    #5,r_sr
                beq    .usr
                move.l  d2,r_ssp
                bra    .s
.usr            move.l  d2,r_usp
.s              addq.l  #4,d2
                move.l  d2,v_callsp             ; SP expected after the RTS
                move.l  d7,v_callpc
                st      v_incall
                clr.b   v_stepmode
                bra     mon_resume
.bad            move.l  d7,r_pc
                ERROR   "the active stack pointer must be even and in RAM $01004-$80000"

;------------------------------------------------------------ T / SO
; T [n]   trace n instructions (default 1); empty line repeats
cmd_t:
                moveq   #1,d0
                bsr     at_end
                beq    .one
                bsr     get_expr
                tst.l   d0
                bne    .one
                moveq   #1,d0
.one            move.l  d0,v_stepcnt
                bsr     end_args
                bra     step_once

; SO   step over: BSR, JSR and TRAP run at full speed to the next instruction
cmd_so:
                bsr     end_args
                movea.l r_pc,a0
                move.l  a0,d0
                btst    #0,d0
                bne     err_oddpc
                move.w  (a0),d0
                move.w  d0,d1
                andi.w  #$FF00,d1
                cmpi.w  #$6100,d1               ; BSR
                beq    .over
                move.w  d0,d1
                andi.w  #$FFC0,d1
                cmpi.w  #$4E80,d1               ; JSR
                beq    .over
                move.w  d0,d1
                andi.w  #$FFF0,d1
                cmpi.w  #$4E40,d1               ; TRAP #n
                beq    .over
                moveq   #1,d0
                move.l  d0,v_stepcnt
                bra     step_once
.over           movea.l r_pc,a0
                bsr     dis_length              ; D0 = instruction length
                add.l   r_pc,d0
                bsr     chk_bp_addr
                beq    .ok
                moveq   #1,d0                   ; cannot place it: single step
                move.l  d0,v_stepcnt
                bra     step_once
.ok             bsr     bp_set_temp
                clr.b   v_stepmode
                bra     mon_resume

;------------------------------------------------------------ R / RI
; R                 show registers
; R reg value       set a register (D0-D7 A0-A7 SP PC SR USP SSP)
cmd_r:
                bsr     at_end
                bne    .set
                bra     show_regs
.set            bsr     skipsp
                cmpi.b  #'.',d0                 ; ".D0" accepted too
                bne    .n
                addq.l  #1,a0
.n              bsr     parse_reg
                bcs    .bad
                bsr     at_end
                beq    .show                   ; "R D0": show one register
                move.w  d1,-(sp)
                bsr     skipsp
                cmpi.b  #'=',d0                 ; "R D0=5" accepted too
                bne    .v
                addq.l  #1,a0
.v              bsr     get_expr
                bsr     end_args
                move.w  (sp)+,d1
                bsr     reg_set
                bra     show_regs
.show           bsr     reg_get
                move.b  #'$',d2
                exg     d0,d2
                bsr     putc
                exg     d0,d2
                cmpi.w  #REG_SR,d1
                bne    .s8
                bsr     puthex4
                bra     crlf
.s8             bsr     puthex8
                bra     crlf
.bad            ERROR   "unknown register (D0-D7, A0-A7, SP, PC, SR, USP, SSP)"

; RI   reset the program registers to their defaults
cmd_ri:
                bsr     end_args
                bsr     user_ctx_init
                clr.b   v_incall
                bra     show_regs

;------------------------------------------------------------ BR / BC
; BR                 list breakpoints
; BR addr [count]    set a breakpoint (stop on the count-th pass)
cmd_br:
                bsr     at_end
                beq    .list
                bsr     get_addr
                move.l  d0,d5
                moveq   #1,d6
                bsr     opt_expr
                bcs    .c
                move.l  d0,d6
                cmpi.l  #$FFFF,d6
                bhi    .badc
                tst.l   d6
                beq    .badc
.c              bsr     end_args
                move.l  d5,d0
                bsr     chk_bp_addr
                bne    .badaddr
                bsr     bp_find
                tst.w   d1
                bpl    .have                   ; update the count of an existing one
                moveq   #0,d1                   ; find the lowest free slot
.f              lea     bp_flags,a0
                btst    #BPF_USED,0(a0,d1.w)
                beq    .free
                addq.w  #1,d1
                cmpi.w  #NBP,d1
                blo    .f
                ERROR   "all 8 breakpoints are in use (BC clears)"
.free           move.w  d1,d0
                lsl.w   #2,d0
                lea     bp_addr,a0
                move.l  d5,0(a0,d0.w)
                lea     bp_flags,a0
                move.b  #1<<BPF_USED,0(a0,d1.w)
.have           move.w  d1,d0
                add.w   d0,d0
                lea     bp_count,a0
                move.w  d6,0(a0,d0.w)
.list           moveq   #0,d7                   ; list all
                moveq   #0,d1
.ll             lea     bp_flags,a0
                btst    #BPF_USED,0(a0,d1.w)
                beq    .ln
                addq.w  #1,d7
                move.l  d1,d0
                addq.l  #1,d0
                bsr     putdec
                PRINT   ": $"
                move.w  d1,d0
                lsl.w   #2,d0
                lea     bp_addr,a0
                move.l  0(a0,d0.w),d0
                bsr     puthex5
                move.w  d1,d0
                add.w   d0,d0
                lea     bp_count,a0
                moveq   #0,d2
                move.w  0(a0,d0.w),d2
                cmpi.w  #1,d2
                bls    .nc
                PRINT   "  count "
                move.l  d2,d0
                bsr     putdec
.nc             bsr     crlf
.ln             addq.w  #1,d1
                cmpi.w  #NBP,d1
                blo    .ll
                tst.w   d7
                bne    .x
                PRINT   <"No breakpoints",13,10>
.x              rts
.badc           ERROR   "count must be 1..$FFFF"
.badaddr        ERROR   "a breakpoint needs an even address in RAM $01000-$7FFFE or $C0000-$CFFFE"

; BC           clear all breakpoints
; BC n         clear breakpoint number n (1-8)
; BC addr      clear the breakpoint at addr
cmd_bc:
                bsr     at_end
                bne    .one
                moveq   #NBP-1,d1
                lea     bp_flags,a0
.all            clr.b   0(a0,d1.w)
                dbra    d1,.all
                PRINT   <"All breakpoints cleared",13,10>
                rts
.one            bsr     get_expr
                bsr     end_args
                cmpi.l  #NBP,d0
                bhi    .addr
                tst.l   d0
                beq    .addr
                move.w  d0,d1
                subq.w  #1,d1
                lea     bp_flags,a0
                btst    #BPF_USED,0(a0,d1.w)
                beq    .nf
                bra    .clr
.addr           bsr     bp_find
                tst.w   d1
                bmi    .nf
.clr            lea     bp_flags,a0
                clr.b   0(a0,d1.w)
                rts
.nf             ERROR   "no such breakpoint"

;------------------------------------------------------------ DI
; DI [addr [n]]   disassemble n instructions (default 16); empty line continues
cmd_di:
                move.l  v_diaddr,d2
                move.l  v_dilen,d5
                bsr     at_end
                beq    .go
                bsr     get_addr
                move.l  d0,d2
                bsr     opt_expr
                bcs    .go
                move.l  d0,d5
                beq    .go1
.go             bsr     end_args
                btst    #0,d2
                beq    .even
                ERROR   "odd address: instructions start at even addresses"
.go1            moveq   #1,d5
                bra    .go
.even           move.l  d5,v_dilen
.l              bsr     chk_abort
                move.l  d2,d3                   ; the longest instruction is 10 bytes
                addi.l  #9,d3
                cmpi.l  #ADDR_MAX,d3
                bls    .r
                move.l  #ADDR_MAX,d3
.r              moveq   #ACC_R|ACC_B,d4
                bsr     chk_range
                move.l  d2,d0
                bsr     dis_line                ; prints, D0 = length
                add.l   d0,d2
                cmpi.l  #ADDR_MAX,d2
                bhi    .wrap
                subq.l  #1,d5
                bne    .l
.wrap           andi.l  #ADDR_MAX,d2
                move.l  d2,v_diaddr
                rts

; dis_line_safe: disassemble one line at D0 if that memory may be read
; (used by the register display); prints nothing otherwise.
dis_line_safe:
                movem.l d0-d4,-(sp)
                btst    #0,d0
                bne    .x
                move.l  d0,d2
                move.l  d0,d3
                addi.l  #9,d3
                cmpi.l  #ADDR_MAX,d3
                bhi    .x
                bsr     region_flags
                btst    #2,d0                   ; ACC_B
                beq    .x
                exg     d2,d3
                bsr     region_flags            ; end must be readable too
                exg     d2,d3
                btst    #2,d0
                beq    .x
                move.l  d2,d0
                bsr     dis_line
.x              movem.l (sp)+,d0-d4
                rts

;------------------------------------------------------------ VE
; VE   list the exception vectors that differ from the monitor's defaults
cmd_ve:
                bsr     at_end
                beq    .list
                bsr     skipsp
                bsr     toupper
                cmpi.b  #'D',d0                 ; VE D: restore the monitor's vectors
                bne    .bad
                addq.l  #1,a0
                bsr     end_args
                move.w  sr,-(sp)
                ori.w   #$0700,sr
                lea     VEC_TABLE+8,a2
                lea     rom_vectors+8(pc),a3
                move.w  #254-1,d0
.c              move.l  (a3)+,(a2)+
                dbra    d0,.c
                move.w  (sp)+,sr
.list           lea     VEC_TABLE+8,a2
                lea     rom_vectors+8(pc),a3
                moveq   #2,d2
                moveq   #0,d7
.l              move.l  (a2)+,d0
                cmp.l   (a3)+,d0
                beq    .n
                addq.w  #1,d7
                move.l  d2,d0
                bsr     putdec
                PRINT   " ("
                move.w  d2,d0
                bsr     put_vecname
                PRINT   ") -> $"
                move.l  -4(a2),d0
                bsr     puthex8
                bsr     crlf
.n              addq.w  #1,d2
                cmpi.w  #256,d2
                blo    .l
                tst.w   d7
                bne    .x
                PRINT   <"All vectors point to the monitor's handlers",13,10>
.x              rts
.bad            ERROR   "use VE (list) or VE D (restore the monitor's vectors)"

;------------------------------------------------------------ IN
cmd_info:
                bsr     end_args
                PRINT   <"MON68K 1.0  MC68008 at 8 MHz, 20-bit address bus",13,10>
                PRINT   <"  $00000-$003FF  vector table (RAM copy, user may change)",13,10>
                PRINT   <"  $00400-$00FFF  monitor workspace and stack (protected)",13,10>
                PRINT   <"  $01000-$7FFFF  user RAM",13,10>
                PRINT   <"  $80000-$BFFFF  flash ROM (monitor; read-only here)",13,10>
                PRINT   <"  $C0000-$CFFFF  Junior bus window (1 MHz bus cycles)",13,10>
                PRINT   <"  $D0000-$EFFFF  unmapped (bus error)",13,10>
                PRINT   <"  $F0000-$FFFFF  68681 DUART (16 registers, repeated)",13,10>
                PRINT   <"Console 38400 8N1 on channel A, RTS/CTS (RTS from the receiver)",13,10>
                PRINT   "Receive errors since reset: "
                btst    #0,v_rxflags
                beq    .1
                PRINT   "buffer-overflow "
.1              btst    #1,v_rxflags
                beq    .2
                PRINT   "68681-overrun "
.2              btst    #2,v_rxflags
                beq    .3
                PRINT   "framing/parity "
.3              tst.b   v_rxflags
                bne    .4
                PRINT   "none"
.4              bsr     crlf
                PRINT   "Ctrl-C break into the monitor: "
                tst.b   v_abort_en
                bne    .on
                PRINT   <"off",13,10>
                rts
.on             PRINT   <"on",13,10>
                rts

;------------------------------------------------------------ HE
cmd_help:
                lea     help_text(pc),a0
                bra     puts

help_text:
 dc.b "MON68K commands (numbers are hex; #dec %bin 'c' .reg; + and - allowed)",13,10
 dc.b " MD [addr [len]]          memory dump (Enter continues)",13,10
 dc.b " MM[.B/.W/.L] addr [v..]  modify memory; no values: interactive",13,10
 dc.b "                          (Enter next, - back, . quit)",13,10
 dc.b " MF[.B/.W/.L] start end v fill memory",13,10
 dc.b " MC start end dest        copy memory (overlap safe)",13,10
 dc.b " MS[.B/.W/.L] start end v [v..]  search;  MS start end ",34,"text",34,13,10
 dc.b " CM start end dest        compare memory",13,10
 dc.b " LO [offset]              load S-records (S1/S2/S3, S5/S6, S7/S8/S9)",13,10
 dc.b " DU start end [entry]     dump memory as S-records",13,10
 dc.b " GO [addr]                run (from addr, or continue)",13,10
 dc.b " GT addr                  run until addr",13,10
 dc.b " CALL addr                call a subroutine; RTS returns to the monitor",13,10
 dc.b " T [n]                    trace n instructions (Enter repeats)",13,10
 dc.b " SO                       step over BSR/JSR/TRAP",13,10
 dc.b " R  /  R reg value        show / set registers (D0-D7 A0-A7 SP PC SR USP SSP)",13,10
 dc.b " RI                       reset program registers to defaults",13,10
 dc.b " BR [addr [count]]        set / list breakpoints (8)",13,10
 dc.b " BC [n | addr]            clear one / all breakpoints",13,10
 dc.b " DI [addr [n]]            disassemble (Enter continues)",13,10
 dc.b " VE [D]                   list changed exception vectors (D: restore all)",13,10
 dc.b " IN                       memory map and status",13,10
 dc.b "Ctrl-C or BREAK stops a running program; NMI too. Programs call the monitor",13,10
 dc.b "with TRAP #15 (D0.W = function), see MONITOR.md.",13,10
 dc.b 0
                even

;=============================================================================
; except.asm - exception entry and exit, tracing, breakpoints
;
; MC68000/MC68008 exception stack frames (supervisor stack, lowest address
; first; the 68000 and 68008 have no format word):
;
;   group 1 and 2 (everything except bus/address error and reset), 6 bytes:
;       +0  SR (word)   status register before the exception
;       +2  PC (long)   see below
;   group 0 (bus error, address error), 14 bytes:
;       +0  special status word: bit 4 R/W (1 = read), bit 3 I/N
;           (0 = instruction, 1 = not), bits 2-0 function code
;       +2  access address (long)
;       +6  instruction register (first word of the instruction)
;       +8  SR
;       +10 PC: advanced 2 to 10 bytes beyond the first word of the
;           instruction (MC68000UM 6.3.9.1), so the instruction can neither
;           be found exactly nor restarted.
;
; Stacked PC for group 1/2: TRAP #n, TRAPV, CHK, DIVx by zero and trace
; stack the address of the NEXT instruction; illegal, line A/F and
; privilege violation stack the address of the offending instruction;
; interrupts stack the address of the next instruction to execute.
; The breakpoint instruction is ILLEGAL ($4AFC), so a breakpoint's stacked
; PC is the breakpoint address itself and needs no adjustment.
; (A TRAP-based breakpoint would stack PC+2 and need PC-2.)
;
; Tracing (MC68000UM 6.3.8): if T is set at the start of an instruction, a
; trace exception follows its completion. If the instruction itself traps
; (TRAP, TRAPV, CHK, DIVx by zero) the trap is processed first and the
; trace exception is taken before the handler's first instruction, so the
; trace frame sits directly on top of the trap frame. Illegal, privileged
; and unimplemented instructions are not traced (not executed), nor are
; instructions aborted by bus/address errors. If an interrupt is pending,
; the trace exception is processed before the interrupt.
;
; Exception processing copies SR, sets S, clears T; interrupts also raise
; the mask to their level. Nothing else changes the mask.
;=============================================================================

;------------------------------------------------------------ vector stubs
; One 8-byte stub per vector 2-255: push the vector number, enter.
exc_stubs:
vn              set     2
                rept    254
                move.w  #vn,-(sp)
                bra.w   exc_entry
vn              set     vn+1
                endr
exc_stubs_end:
                if      (exc_stubs_end-exc_stubs)!=(254*8)
                fail    "exception stubs are not 8 bytes each"
                endif

;------------------------------------------------------------ entry
; Stack on entry: vector number (word), then the exception frame.
exc_entry:
                ori.w   #$0700,sr               ; mask 7 (NMI still possible, see nmi_handler)
                tst.b   v_inmon
                bne     mon_fault               ; the monitor itself faulted
                movem.l d0-d7/a0-a6,r_d0        ; user registers
                move.w  (sp)+,d0
                move.w  d0,r_vec
                cmpi.w  #V_ADDRERR,d0
                bhi    .g12
                cmpi.w  #V_BUSERR,d0
                blo    .g12
                move.w  (sp)+,r_ssw             ; group 0 frame
                move.l  (sp)+,r_fa
                move.w  (sp)+,r_ir
.g12            move.w  (sp)+,r_sr
                move.l  (sp)+,r_pc
                move.l  sp,r_ssp                ; user SSP as before the exception
                move.l  usp,a0
                move.l  a0,r_usp
                lea     MON_STACK_TOP,sp        ; from here on: the monitor's own stack
                st      v_inmon
                tst.b   v_stepmode              ; T was set by the monitor: give the
                beq    .nt                     ; user back their own T bit
                andi.w  #$7FFF,r_sr
                tst.b   v_usert
                bpl    .nt
                ori.w   #$8000,r_sr
.nt             bsr     bp_remove_all
                bra     mon_entry

; mon_fault: an exception while the monitor was running. The user context
; is not touched. With a recovery point set (v_recpc) control goes there
; with D0 = vector and D1 = access address (group 0) or 0; otherwise the
; fault is reported and the command loop restarts.
mon_fault:
                move.w  (sp)+,d0
                moveq   #0,d1
                lea     2(sp),a1                ; -> PC of a group 1/2 frame
                cmpi.w  #V_ADDRERR,d0
                bhi    .g12
                cmpi.w  #V_BUSERR,d0
                blo    .g12
                move.l  2(sp),d1                ; access address
                move.w  (sp),d2                 ; special status word
                lea     10(sp),a1
.g12            move.l  (a1),d3                 ; faulting PC
                tst.l   v_recpc
                beq    .rep
                movea.l v_recsp,sp
                movea.l v_recpc,a0
                clr.l   v_recpc
                jmp     (a0)
.rep            lea     MON_STACK_TOP,sp
                move.w  #$2400,sr
                bsr     duart_check
                bsr     crlf
                PRINT   "*** Monitor error: "
                bsr     put_vecname
                cmpi.w  #V_ADDRERR,d0
                bhi    .pc
                cmpi.w  #V_BUSERR,d0
                blo    .pc
                bsr     put_g0info
.pc             PRINT   " at PC=$"
                move.l  d3,d0
                bsr     puthex8
                PRINT   <13,10,"    (your program's registers are unchanged)",13,10>
                bra     cmd_loop

; nmi_handler: level 7 autovector (Junior bus NMI). Breaks into the monitor
; when a user program is interrupted outside the monitor's ROM code; inside
; the monitor or one of its services it only sets v_abort, which stops a
; running command or is acted on when the TRAP #15 service returns.
nmi_handler:
                tst.b   v_inmon
                bne    .flag
                cmpi.l  #ROM_BASE,2(sp)
                blo    .user
                cmpi.l  #ROM_TOP,2(sp)
                blo    .flag
.user           move.w  #V_NMI,-(sp)
                bra     exc_entry
.flag           st      v_abort
                rte

; trace_handler: vector 9.
trace_handler:
                ori.w   #$0700,sr
                tst.b   v_inmon
                bne    .enter                  ; (monitor fault)
                move.l  d0,-(sp)
                move.l  6(sp),d0                ; PC in the trace frame
                cmpi.l  #exc_stubs,d0
                blo    .api
                cmpi.l  #exc_stubs_end,d0
                blo    .vectored
.api            cmpi.l  #api_entry,d0
                bne    .normal
.vectored:      ; The traced instruction trapped into a monitor handler (TRAP,
                ; TRAPV, CHK, DIVx by 0). Its 6-byte frame lies under this one.
                ; Give it the user's own T bit back and let the handler run.
                andi.w  #$7FFF,4+6(sp)
                tst.b   v_usert
                bpl    .v1
                ori.w   #$8000,4+6(sp)
.v1             cmpi.b  #SM_RESUME,v_stepmode
                bne    .v2
                bsr     bp_insert_all           ; the breakpoint was stepped over
                clr.b   v_stepmode
.v2             move.l  (sp)+,d0
                rte
.normal         move.l  (sp)+,d0
                cmpi.b  #SM_RESUME,v_stepmode
                bne    .enter
                ; stepped off a breakpoint: re-insert all breakpoints and run on
                bsr     bp_insert_all
                clr.b   v_stepmode
                andi.w  #$7FFF,(sp)
                tst.b   v_usert
                bpl    .r
                ori.w   #$8000,(sp)
.r              rte
.enter          move.w  #V_TRACE,-(sp)
                bra     exc_entry

;------------------------------------------------------------ resume
; mon_resume: start or continue the user context. v_stepmode must be 0 (run)
; or SM_STEP (execute one instruction). Breakpoints are inserted here; if a
; breakpoint sits at PC the instruction is first executed with the
; breakpoints out (trace), then they are inserted (SM_RESUME).
; Does not return; errors go back to the command loop.
mon_resume:
                move.l  r_pc,d0
                btst    #0,d0
                bne     err_oddpc
                cmpi.l  #ADDR_MAX,d0
                bhi     err_pcrange
                move.l  r_ssp,d0
                btst    #0,d0
                bne     err_ssp
                cmpi.l  #USER_RAM+8,d0
                blo     err_ssp
                cmpi.l  #RAM_TOP,d0
                bhi     err_ssp
                move.w  r_sr,d1
                andi.w  #$A71F,d1               ; only bits the 68000 implements
                move.w  d1,r_sr
                btst    #13,d1
                bne    .sup
                move.l  r_usp,d0                ; user mode: USP must be usable
                btst    #0,d0
                bne     err_usp
.sup            clr.b   v_usert
                tst.w   d1
                bpl    .not
                st      v_usert
.not            cmpi.b  #SM_STEP,v_stepmode
                beq    .trace
                bsr     bp_at_pc                ; Z clear if a user breakpoint is at PC
                beq    .run
                move.b  #SM_RESUME,v_stepmode
.trace          ori.w   #$8000,d1               ; T = 1
                bra    .go
.run            bsr     bp_insert_all
                clr.b   v_stepmode
.go             clr.b   v_abort
                clr.b   v_hitbp
                bsr     led_mon_off
                ori.w   #$0700,sr
                ; ---- from here: no use of the monitor stack, interrupts masked
                ; (an NMI here is seen as "in ROM" and only sets v_abort)
                movea.l r_usp,a0
                move.l  a0,usp
                movea.l r_ssp,sp                ; user's supervisor stack
                move.l  r_pc,-(sp)              ; build a 6-byte frame on it
                move.w  d1,-(sp)
                movem.l r_d0,d0-d7/a0-a6
                clr.b   v_inmon
                rte

err_oddpc:      bsr     crlf
                PRINT   <"PC is odd: the 68000 would take an address error",13,10>
                bra     cmd_loop
err_pcrange:    bsr     crlf
                PRINT   <"PC is beyond $FFFFF (the 68008 has a 20-bit address bus)",13,10>
                bra     cmd_loop
err_ssp:        bsr     crlf
                PRINT   <"SSP must be even and in RAM $01008-$80000 (set it with R SSP value)",13,10>
                bra     cmd_loop
err_usp:        bsr     crlf
                PRINT   <"USP is odd (set it with R USP value)",13,10>
                bra     cmd_loop

;------------------------------------------------------------ breakpoints
; bp_index: D0.W = index -> A0 = &bp_addr[i], A1 = &bp_save[i] ... helpers
; are open-coded below for speed and clarity.

; bp_insert_all: put ILLEGAL at every used breakpoint. All registers
; preserved; runs with interrupts masked so that no handler executes a
; half-written instruction (H7: a word write is two byte cycles).
bp_insert_all:
                movem.l d0-d2/a0,-(sp)
                move.w  sr,-(sp)
                ori.w   #$0700,sr
                moveq   #NBPALL-1,d2
.l              lea     bp_flags,a0
                btst    #BPF_USED,0(a0,d2.w)
                beq    .n
                btst    #BPF_IN,0(a0,d2.w)
                bne    .n
                move.w  d2,d0
                lsl.w   #2,d0
                lea     bp_addr,a0
                movea.l 0(a0,d0.w),a0
                move.w  (a0),d1                 ; original instruction word
                move.w  #ILLEGAL_OP,(a0)
                cmpi.w  #ILLEGAL_OP,(a0)
                bne    .n                      ; not writable: leave it out
                move.w  d2,d0
                add.w   d0,d0
                lea     bp_save,a0
                move.w  d1,0(a0,d0.w)
                lea     bp_flags,a0
                bset    #BPF_IN,0(a0,d2.w)
.n              dbra    d2,.l
                move.w  (sp)+,sr
                movem.l (sp)+,d0-d2/a0
                rts

; bp_remove_all: restore the original words. Sets v_hitbp = 1+index when a
; breakpoint is at r_pc and the entry was its ILLEGAL; warns when a
; program overwrote an inserted breakpoint (the word is then left alone).
bp_remove_all:
                movem.l d0-d3/a0-a1,-(sp)
                clr.b   v_hitbp
                moveq   #NBPALL-1,d2
.l              lea     bp_flags,a1
                btst    #BPF_IN,0(a1,d2.w)
                beq    .n
                bclr    #BPF_IN,0(a1,d2.w)
                move.w  d2,d0
                lsl.w   #2,d0
                lea     bp_addr,a0
                movea.l 0(a0,d0.w),a0
                move.w  d2,d0
                add.w   d0,d0
                lea     bp_save,a1
                move.w  0(a1,d0.w),d1
                cmpi.w  #ILLEGAL_OP,(a0)
                bne    .over
                move.w  d1,(a0)
                cmpa.l  r_pc,a0
                bne    .n
                cmpi.w  #V_ILLEGAL,r_vec
                bne    .n
                move.b  d2,d0
                addq.b  #1,d0
                move.b  d0,v_hitbp
                bra    .n
.over           PRINT   <13,10,"Warning: breakpoint at $">
                move.l  a0,d0
                bsr     puthex5
                PRINT   " was overwritten by the program"
.n              dbra    d2,.l
                movem.l (sp)+,d0-d3/a0-a1
                rts

; bp_at_pc: Z clear (NE) if a user breakpoint is set at r_pc.
bp_at_pc:
                movem.l d0-d1/a0,-(sp)
                move.l  r_pc,d1
                moveq   #NBPALL-1,d0
.l              lea     bp_flags,a0
                btst    #BPF_USED,0(a0,d0.w)
                beq    .n
                move.w  d0,-(sp)
                lsl.w   #2,d0
                lea     bp_addr,a0
                cmp.l   0(a0,d0.w),d1
                movem.w (sp)+,d0                ; (movem does not change flags)
                bne    .n
                andi.b  #$FB,ccr                ; Z = 0: found
                bra    .x
.n              dbra    d0,.l
                ori.b   #$04,ccr                ; Z = 1: none
.x              movem.l (sp)+,d0-d1/a0          ; (movem does not change flags)
                rts

; bp_find: D0.L = address -> D1.W = index of the user breakpoint there, or -1
bp_find:
                movem.l d2/a0,-(sp)
                moveq   #NBP-1,d1
.l              lea     bp_flags,a0
                btst    #BPF_USED,0(a0,d1.w)
                beq    .n
                move.w  d1,d2
                lsl.w   #2,d2
                lea     bp_addr,a0
                cmp.l   0(a0,d2.w),d0
                beq    .x
.n              dbra    d1,.l
.x              movem.l (sp)+,d2/a0
                rts

; bp_set_temp: temporary breakpoint at D0 (address already validated).
; Not needed when a user breakpoint is already there.
bp_set_temp:
                movem.l d1/a0,-(sp)
                bsr    bp_find
                tst.w   d1
                bpl    .x
                move.l  d0,bp_addr+BP_TEMP*4
                move.w  #1,bp_count+BP_TEMP*2
                move.b  #1<<BPF_USED,bp_flags+BP_TEMP
.x              movem.l (sp)+,d1/a0
                rts

;------------------------------------------------------------ CALL support
; A CALLed subroutine returns here (RTS). ILLEGAL makes it enter the
; monitor with r_pc = call_return, which mon_entry recognises.
call_return:
                illegal

;------------------------------------------------------------ monitor entry
; mon_entry: the user context is saved, breakpoints are out, we are on the
; monitor stack with mask 7.
mon_entry:
                bsr     duart_check
                move.w  #$2400,sr
                bsr     led_mon_on
                move.b  v_stepmode,d7           ; why we were running
                clr.b   v_stepmode
                moveq   #0,d6
                move.b  v_hitbp,d6              ; 1+breakpoint index or 0
                clr.b   bp_flags+BP_TEMP        ; the temporary breakpoint is single use
                move.w  r_vec,d0
                cmpi.w  #V_ILLEGAL,d0
                beq    .illegal
                cmpi.w  #V_TRACE,d0
                beq    .trace
                cmpi.w  #V_EXIT,d0
                beq    .exit
                cmpi.w  #V_BREAK,d0
                beq    .break
                bsr     report_exception        ; any other exception
                bra    .show
.exit           move.l  r_pc,d0
                cmpi.l  #BASIC_ROM,d0
                blo    .exitp
                cmpi.l  #ROM_TOP,d0
                bhs    .exitp
                tst.l   r_d0+4                  ; BASIC's BYE (exit code 0)
                bne    cmd_loop                ; BASIC said why already
                PRINT   <"Back in the monitor. BW (or GO) returns to BASIC.",13,10>
                bra     cmd_loop
.exitp          bsr     crlf
                PRINT   "Program exit (TRAP #15 EXIT), D1=$"
                move.l  r_d0+4,d0
                bsr     puthex8
                bsr     crlf
                bra    .show
.break          bsr     crlf
                PRINT   <"Break",13,10>
                bra    .show
.illegal        move.l  r_pc,d0
                cmpi.l  #call_return,d0
                beq    .callret
                tst.w   d6
                beq    .genill
                subq.w  #1,d6
                cmpi.w  #BP_TEMP,d6
                beq    .show                   ; temporary breakpoint: just stop
                move.w  d6,d0
                add.w   d0,d0
                lea     bp_count,a0
                cmpi.w  #1,0(a0,d0.w)
                bls    .stop
                subq.w  #1,0(a0,d0.w)           ; pass count not reached: continue
                tst.b   v_abort
                bne    .stop
                clr.b   v_stepmode
                bra     mon_resume
.stop           bsr     crlf
                PRINT   "Breakpoint "
                move.l  d6,d0
                addq.l  #1,d0                   ; numbered 1..NBP for the user
                bsr     putdec
                PRINT   " at $"
                move.l  r_pc,d0
                bsr     puthex5
                bsr     crlf
                bra    .show
.genill         bsr     report_exception
                bra    .show
.callret        move.l  v_callpc,r_pc           ; continue where the context was
                clr.b   v_incall
                bsr     crlf
                PRINT   "Subroutine returned, D0=$"
                move.l  r_d0,d0
                bsr     puthex8
                bsr     crlf
                bsr     active_sp
                cmp.l   v_callsp,d0
                beq    .show
                PRINT   <"Warning: stack pointer differs from its value before CALL",13,10>
                bra    .show
.trace          cmpi.b  #SM_STEP,d7
                beq    .stepped
                bsr     report_exception        ; the program set T itself
                bra    .show
.stepped        subq.l  #1,v_stepcnt
                bls    .show                   ; last (or only) step: full display
                tst.b   v_abort
                bne    .show
                bsr     show_step_line          ; one line per intermediate step
                bra     step_once
.show           bsr     show_regs
                bra     cmd_loop

; active_sp: D0 = the user's active stack pointer (A7): SSP if S=1 else USP
active_sp:      move.l  r_ssp,d0
                btst    #5,r_sr                 ; S is bit 13 = bit 5 of the high byte
                bne    .s
                move.l  r_usp,d0
.s              rts

;------------------------------------------------------------ stepping
; step_once: execute one instruction of the user context. TRAP #n whose
; vector points into the monitor's ROM (the TRAP #15 services and the
; default handlers) is run at full speed to the next instruction with a
; temporary breakpoint, so the step does not stop inside the monitor.
step_once:
                movea.l r_pc,a0
                move.l  a0,d0
                btst    #0,d0
                bne     err_oddpc
                move.w  (a0),d0
                move.w  d0,d1
                andi.w  #$FFF0,d1
                cmpi.w  #$4E40,d1               ; TRAP #n
                bne    .t
                andi.w  #$000F,d0
                addi.w  #32,d0
                lsl.w   #2,d0
                movea.w d0,a1
                move.l  (a1),d0                 ; vector from the RAM table
                cmpi.l  #ROM_BASE,d0
                blo    .t
                cmpi.l  #ROM_TOP,d0
                bhs    .t
                move.l  a0,d0
                addq.l  #2,d0
                bsr     chk_bp_addr             ; Z set if a breakpoint may go there
                bne    .t
                bsr     bp_set_temp
                clr.b   v_stepmode
                bra     mon_resume
.t              move.b  #SM_STEP,v_stepmode
                bra     mon_resume

;------------------------------------------------------------ reports
; report_exception: print the name and details of r_vec.
report_exception:
                bsr     crlf
                PRINT   "*** "
                move.w  r_vec,d0
                bsr     put_vecname
                cmpi.w  #V_ADDRERR,d0
                bhi    .pc
                cmpi.w  #V_BUSERR,d0
                blo    .pc
                move.l  r_fa,d1
                move.w  r_ssw,d2
                bsr     put_g0info
                PRINT   ", IR=$"
                move.w  r_ir,d0
                bsr     puthex4
                PRINT   <" ***",13,10,"    (stacked PC is 2-10 bytes past the faulting instruction; not restartable)",13,10>
                rts
.pc             cmpi.w  #V_ZERODIV,d0           ; these stack the address of the
                beq    .after                  ; next instruction
                cmpi.w  #V_CHK,d0
                beq    .after
                cmpi.w  #V_TRAPV,d0
                beq    .after
                cmpi.w  #32,d0                  ; TRAP #0-#15
                blo    .at
                cmpi.w  #47,d0
                bhi    .at
.after          PRINT   " (PC is after the instruction)"
                bra    .e
.at             PRINT   " at $"
                move.l  r_pc,d0
                bsr     puthex5
.e              PRINT   <" ***",13,10>
                rts

; put_g0info: D1 = access address, D2 = special status word
put_g0info:
                move.l  d0,-(sp)
                PRINT   ", "
                btst    #4,d2
                beq    .w
                PRINT   "read"
                bra    .a
.w              PRINT   "write"
.a              PRINT   " $"
                move.l  d1,d0
                bsr     puthex8
                PRINT   " FC="
                move.w  d2,d0
                andi.w  #7,d0
                bsr     hexdigit
                bsr     putc
                andi.w  #3,d0                   ; FC1:FC0 = 2 program, 1 data
                cmpi.w  #2,d0
                bne    .d
                PRINT   " (program)"
                bra    .in
.d              cmpi.w  #1,d0
                bne    .in
                PRINT   " (data)"
.in             btst    #3,d2                   ; I/N = 1: not processing an instruction
                beq    .x
                PRINT   " during exception processing"
.x              move.l  (sp)+,d0
                rts

; put_vecname: print the name of vector D0.W (also pseudo vectors).
put_vecname:
                movem.l d0-d1/a0,-(sp)
                cmpi.w  #V_BREAK,d0
                bne    .nb
                PRINT   "Break"
                bra     .x
.nb             cmpi.w  #V_EXIT,d0
                bne    .ne
                PRINT   "Exit"
                bra     .x
.ne             cmpi.w  #64,d0
                blo    .tab
                PRINT   "User interrupt vector "
                bsr     putdec_w
                bra     .x
.tab            cmpi.w  #32,d0
                blo    .low
                cmpi.w  #47,d0
                bhi    .res
                PRINT   "TRAP #"
                subi.w  #32,d0
                bsr     putdec_w
                bra    .x
.low            cmpi.w  #25,d0
                blo    .names
                cmpi.w  #31,d0
                bhi    .names
                PRINT   "Level "
                subi.w  #24,d0
                bsr     putdec_w
                PRINT   " interrupt autovector"
                cmpi.w  #7,d0
                bne    .x
                PRINT   " (NMI)"
                bra    .x
.names          lea     vecnames(pc),a0         ; d0 = 0..24
                move.w  d0,d1
                bra    .f2
.f1             tst.b   (a0)+
                bne    .f1
.f2             dbra    d1,.f1
                bsr     puts
                bra    .x
.res            PRINT   "Reserved vector "
                bsr     putdec_w
.x              movem.l (sp)+,d0-d1/a0
                rts

putdec_w:       move.l  d0,-(sp)
                andi.l  #$FFFF,d0
                bsr     putdec
                move.l  (sp)+,d0
                rts

vecnames:       dc.b    "Reset SSP",0                   ; 0
                dc.b    "Reset PC",0                    ; 1
                dc.b    "Bus error",0                   ; 2
                dc.b    "Address error",0               ; 3
                dc.b    "Illegal instruction",0         ; 4
                dc.b    "Zero divide",0                 ; 5
                dc.b    "CHK exception",0               ; 6
                dc.b    "TRAPV exception",0             ; 7
                dc.b    "Privilege violation",0         ; 8
                dc.b    "Trace",0                       ; 9
                dc.b    "Line 1010 emulator",0          ; 10
                dc.b    "Line 1111 emulator",0          ; 11
                dc.b    "Reserved vector 12",0          ; 12
                dc.b    "Reserved vector 13",0          ; 13
                dc.b    "Reserved vector 14",0          ; 14
                dc.b    "Uninitialized interrupt",0     ; 15
                dc.b    "Reserved vector 16",0
                dc.b    "Reserved vector 17",0
                dc.b    "Reserved vector 18",0
                dc.b    "Reserved vector 19",0
                dc.b    "Reserved vector 20",0
                dc.b    "Reserved vector 21",0
                dc.b    "Reserved vector 22",0
                dc.b    "Reserved vector 23",0
                dc.b    "Spurious interrupt",0          ; 24
                even

;------------------------------------------------------------ register display
; show_regs: full register display plus the next instruction.
show_regs:
                PRINT   "PC="
                move.l  r_pc,d0
                bsr     puthex8
                PRINT   "  SR="
                move.w  r_sr,d0
                bsr     puthex4
                bsr     put_srflags
                PRINT   "  USP="
                move.l  r_usp,d0
                bsr     puthex8
                PRINT   "  SSP="
                move.l  r_ssp,d0
                bsr     puthex8
                bsr     crlf
                lea     r_d0,a2                 ; D0-D7 then A0-A6 follow in memory
                moveq   #'D',d3
                moveq   #0,d4
                bsr    .row                    ; D0-D3
                bsr    .row                    ; D4-D7
                moveq   #'A',d3
                moveq   #0,d4
                bsr    .row                    ; A0-A3
                moveq   #3-1,d2                 ; A4-A6
.ar             bsr    .one
                dbra    d2,.ar
                PRINT   "A7="                   ; A7 = active stack pointer
                bsr     active_sp
                bsr     puthex8
                bsr     crlf
                bra     show_next_instr
.row            moveq   #4-1,d2
.rl             bsr    .one
                dbra    d2,.rl
                bra     crlf
.one            move.b  d3,d0
                bsr     putc
                move.b  d4,d0
                addi.b  #'0',d0
                bsr     putc
                moveq   #'=',d0
                bsr     putc
                move.l  (a2)+,d0
                bsr     puthex8
                bsr     putspace
                bsr     putspace
                addq.w  #1,d4
                rts

; put_srflags: print " [TS7XNZVC]" style flags for SR in D0.W
put_srflags:
                movem.l d0-d2/a0,-(sp)
                move.w  d0,d2
                PRINT   " ["
                moveq   #'T',d0
                btst    #15,d2
                bsr    .f
                moveq   #'S',d0
                btst    #13,d2
                bsr    .f
                move.w  d2,d0
                lsr.w   #8,d0
                andi.w  #7,d0
                addi.b  #'0',d0
                bsr     putc
                lea     .xnzvc(pc),a0
                moveq   #4,d1
.l              move.b  (a0)+,d0
                btst    d1,d2
                bsr    .f
                dbra    d1,.l
                moveq   #']',d0
                bsr     putc
                movem.l (sp)+,d0-d2/a0
                rts
.f              bne    .on
                moveq   #'-',d0
.on             bra     putc
.xnzvc          dc.b    "XNZVC"
                even

; show_next_instr: disassemble the instruction at r_pc (if readable).
show_next_instr:
                move.l  r_pc,d0
                bsr     dis_line_safe
                rts

; show_step_line: one line "PC  instruction" for multi-step traces.
show_step_line:
                bra    show_next_instr

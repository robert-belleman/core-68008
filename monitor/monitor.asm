;=============================================================================
; MON68K - ROM monitor for the core68008 board
;
; Target : MC68008P8 (48-pin DIP, 20-bit address bus, 8-bit data bus), 8 MHz
; Board  : core68008 rev 0.2 (GAL1 decode.pld, GAL2 bridge.pld, GAL3 busdbg.pld)
; Syntax : vasm, Motorola syntax (vasmm68k_mot -m68000 -Fbin)
;
; Files  : monitor.asm   main file: equates, RAM layout, vectors, reset
;          util.asm      output and number formatting helpers
;          serial.asm    68681 driver, interrupt-driven receive ring buffer
;          except.asm    exception entry/exit, trace, breakpoints, NMI
;          cmds.asm      command line parser and commands
;          srec.asm      Motorola S-record loader and dumper
;          api.asm       TRAP #15 service interface for user programs
;          disasm.asm    MC68000 disassembler
;          flash.asm     FL command: program the flash from RAM
;
; The hardware facts this code depends on are listed under HARDWARE
; ASSUMPTIONS below and in MONITOR.md. They come from the board's netlist
; and GAL equations.
;=============================================================================

;-----------------------------------------------------------------------------
; HARDWARE ASSUMPTIONS (core68008 rev 0.2)
;
; H1  Memory map (GAL1 decode.pld):
;       $00000-$7FFFF  512K SRAM AS6C4008, no wait states
;       $80000-$BFFFF  256K flash SST39SF020A, no wait states. Writes reach the
;                      flash /WE but only an SST command sequence changes it
;                      (the FL command, flash.asm).
;       $C0000-$CFFFF  Junior/Elektor bus window (1 MHz PHI2 bridge, GAL2).
;                      Always acknowledged (JDTACK), even if no card answers.
;       $D0000-$EFFFF  unmapped: GAL1 asserts BERR -> bus error exception.
;       $F0000-$FFFFF  MC68681 DUART. RS1-RS4 = A0-A3, so the 16 registers sit
;                      at consecutive byte addresses $F0000-$F000F and repeat
;                      every 16 bytes up to $FFFFF.
; H2  Boot overlay (GAL1 OVL): set by power-on reset (~PORST, DS1233) only.
;     While set, reads of $00000-$7FFFF come from the flash, so the reset
;     SSP/PC are fetched from flash offsets 0 and 4. The first bus cycle to
;     $80000-$BFFFF clears it. Writes always go to SRAM. The RESET
;     instruction does NOT re-enable the overlay (GAL1 uses ~PORST, not the
;     CPU's ~RESET line).
; H3  The CPU's ~RESET line (RESET instruction) resets the 68681 (pin 34) and
;     the Junior bus (BRES), so the monitor re-initialises the DUART when it
;     finds it was reset (IVR reads back $0F instead of VEC_DUART).
; H4  Interrupts (48-pin 68008 has IPL0/2 and IPL1 only: levels 2, 5, 7):
;       level 5  68681 INTRN on ~IPL02; IACK5 (GAL2) -> 68681 IACKN, so the
;                68681 supplies its IVR as the vector number (vectored).
;       level 2  Junior bus IRQ on ~IPL1, autovectored (VPA) -> vector 26.
;       level 7  Junior bus NMI via 7407 on both lines, autovectored -> 31.
;     Level 7 is edge-triggered by the CPU and cannot be masked.
; H5  68681 clock: 3.6864 MHz crystal (Y1). Baud rate set 1 (ACR[7]=0) has
;     38.4K at CSR code $C. Channel A: TxDA->FTDI RXD, RxDA<-FTDI TXD,
;     OP0 = RTSN -> FTDI CTS#, IP0 = CTSN <- FTDI RTS#. The monitor drives
;     OP0 through the OPR (serial.asm); the 68681's RxRTS mode is off, because
;     it negates RTSN only when the 3-character FIFO is full, and an FTDI
;     still sends up to 3 characters after that, which then overrun.
; H6  OP6 and OP7 drive green LEDs D5/D6 to +5V through 2k2: an OPR bit set
;     to 1 drives the pin low and lights the LED. OP7 = "monitor active",
;     OP6 is left to user programs (API function LED).
; H7  No other bus master (BR pulled up, BG unconnected), no cache, no MMU.
;     The 68008 performs every word as two byte cycles (even address first,
;     most significant byte first), but word/long accesses to odd addresses
;     still cause an address error, exactly as on the MC68000.
;-----------------------------------------------------------------------------

;------------------------------------------------------------------ macros
; PRINT <"text",13,10> : print an inline string (all registers preserved)
PRINT           macro
                bsr     puts_inline
                dc.b    \1,0
                even
                endm

; bsr_ns routine,An : call a routine that returns with JMP (An) (no stack)
bsr_ns          macro
                lea     .r\@(pc),\2
                bra     \1
.r\@
                endm

;----------------------------------------------------------------- memory map
RAM_BASE        equ     $00000
RAM_TOP         equ     $80000          ; first address above the SRAM
ROM_BASE        equ     $80000
ROM_SIZE        equ     $40000          ; 256K
ROM_TOP         equ     $C0000
BASIC_ROM       equ     $A0000          ; EhBASIC image (basic/ehbasic.bin), see BA/BW
BASIC_COLD      equ     BASIC_ROM       ; A0 = RAM start, D0 = RAM size
BASIC_WARM      equ     BASIC_ROM+4     ; A0 = RAM start
WIN_BASE        equ     $C0000          ; Junior bus window
WIN_TOP         equ     $D0000
NONE_BASE       equ     $D0000          ; bus error range
NONE_TOP        equ     $F0000
DUART           equ     $F0000
ADDR_MAX        equ     $FFFFF          ; highest address on a 20-bit bus

VEC_TABLE       equ     $00000          ; RAM copy of the exception vectors
MON_DATA        equ     $00400          ; monitor workspace $00400-$00FFF
MON_STACK_TOP   equ     $01000          ; monitor stack grows down from here
USER_RAM        equ     $01000          ; first byte free for user programs
USER_SSP_INIT   equ     $80000          ; default user supervisor stack (top of RAM)
USER_USP_INIT   equ     $7F000          ; default user stack (4K below SSP)
USER_SR_INIT    equ     $2000           ; supervisor, interrupt mask 0

;------------------------------------------------------- 68681 register map
; offsets from DUART; read / write meaning
D_MRA           equ     0               ; MR1A/MR2A        MR1A/MR2A
D_SRA           equ     1               ; SRA              CSRA
D_CSRA          equ     1
D_CRA           equ     2               ; (do not read)    CRA
D_RHRA          equ     3               ; RHRA             THRA
D_THRA          equ     3
D_IPCR          equ     4               ; IPCR             ACR
D_ACR           equ     4
D_ISR           equ     5               ; ISR              IMR
D_IMR           equ     5
D_MRB           equ     8
D_SRB           equ     9
D_CSRB          equ     9
D_CRB           equ     10
D_IVR           equ     12              ; IVR              IVR
D_IP            equ     13              ; input port       OPCR
D_OPCR          equ     13
D_SOPR          equ     14              ; start counter    set OP bits
D_ROPR          equ     15              ; stop counter     reset OP bits

; command register values (CRA/CRB)
CR_RXEN         equ     $01
CR_RXDIS        equ     $02
CR_TXEN         equ     $04
CR_TXDIS        equ     $08
CR_RSTMR        equ     $10
CR_RSTRX        equ     $20
CR_RSTTX        equ     $30
CR_RSTERR       equ     $40
CR_RSTBRK       equ     $50

; status register bits (SRA)
SR_RXRDY        equ     0
SR_FFULL        equ     1
SR_TXRDY        equ     2
SR_TXEMT        equ     3
SR_OE           equ     4
SR_PE           equ     5
SR_FE           equ     6
SR_RB           equ     7

; interrupt mask/status bits
IM_TXRDYA       equ     0
IM_RXRDYA       equ     1

; serial configuration (see H5)
BAUD_ACR        equ     $00             ; set 1, C/T in counter mode (unused)
BAUD_CSR        equ     $CC             ; 38400 Rx and Tx with ACR[7]=0
MR1A_VAL        equ     $13             ; no RxRTS (the monitor drives OP0), RxRDY irq, char errors, no parity, 8 bits
MR2A_VAL        equ     $07             ; normal mode, no TxRTS, no CTS gating, 1 stop bit
                                        ; ($17 enables CTS gating of the transmitter)
VEC_DUART       equ     64              ; IVR value: first user interrupt vector

OP_RTS          equ     $01             ; OP0
OP_LED_USER     equ     $40             ; OP6 -> D5
OP_LED_MON      equ     $80             ; OP7 -> D6

;-------------------------------------------------------- exception numbers
V_BUSERR        equ     2
V_ADDRERR       equ     3
V_ILLEGAL       equ     4
V_ZERODIV       equ     5
V_CHK           equ     6
V_TRAPV         equ     7
V_TRACE         equ     9
V_SPURIOUS      equ     24
V_AUTO2         equ     26
V_NMI           equ     31              ; level 7 autovector
V_TRAP15        equ     47
; pseudo vectors used only inside the monitor
V_BREAK         equ     256             ; Ctrl-C or BREAK from the console
V_EXIT          equ     257             ; TRAP #15 EXIT

ILLEGAL_OP      equ     $4AFC           ; breakpoint opcode (MC68000 ILLEGAL)

NBP             equ     8               ; user breakpoints
BP_TEMP         equ     NBP             ; index of the temporary breakpoint
NBPALL          equ     NBP+1

LINEMAX         equ     80              ; command line length (with NUL)
RX_HIWATER      equ     128             ; negate RTS at this ring fill (127 slots of slack)
RX_LOWATER      equ     64              ; assert it again below this
TX_TIMEOUT      equ     150000          ; about 1 s of TxRDY polling

;-------------------------------------------------------------- RAM layout
; All monitor variables live in $00400-$00FFF and are reached with
; absolute short addressing. The area is cleared at reset; the variables
; between IDATA_START and IDATA_END are then copied from ROM (IDATA_ROM).
                rsset   MON_DATA
v_rxbuf         rs.b    256             ; receive ring buffer (index wraps at 256)
v_linebuf       rs.b    LINEMAX         ; command line
v_lastline      rs.b    LINEMAX         ; previous command line (up-arrow)
v_recbuf        rs.b    260             ; one S-record's data bytes
v_scratch       rs.b    80              ; formatting scratch (disassembler output)
                rs.w    0
; ---- initialised variables (copied from IDATA_ROM at reset)
IDATA_START     rs.b    0
v_abort_en      rs.b    1               ; Ctrl-C breaks into the monitor
v_echo          rs.b    1               ; echo while reading a command line
v_imr           rs.b    1               ; shadow of the write-only IMR
v_rtsoff        rs.b    1               ; $FF while the monitor holds RTS negated
v_mdlen         rs.l    1               ; default MD length
v_dilen         rs.l    1               ; default DI count
IDATA_END       rs.b    0
; ---- cleared variables
v_rxhead        rs.b    1               ; written only by the receive service
v_rxtail        rs.b    1               ; written only by the consumer
v_rxflags       rs.b    1               ; bit 0 ring overflow, 1 hw overrun, 2 framing/parity
v_abort         rs.b    1               ; abort request (Ctrl-C, BREAK, NMI)
v_inmon         rs.b    1               ; $FF while the monitor (not the user) runs
v_stepmode      rs.b    1               ; 0, SM_STEP, SM_RESUME or SM_OVER
v_usert         rs.b    1               ; user's own T bit (bit 7)
v_hitbp         rs.b    1               ; 1+index of breakpoint at PC on entry, else 0
v_lastcr        rs.b    1
v_repeat        rs.b    1               ; command that an empty line repeats
v_size          rs.b    1               ; size suffix: 1, 2 or 4
v_incall        rs.b    1               ; a CALL is outstanding
                rs.w    0
v_stepcnt       rs.l    1               ; remaining steps
v_callpc        rs.l    1               ; PC to restore after CALL returns
v_callsp        rs.l    1               ; stack pointer expected after CALL returns
v_mdaddr        rs.l    1               ; next MD address
v_diaddr        rs.l    1               ; next DI address
v_recsp         rs.l    1               ; monitor fault recovery (0 = none)
v_recpc         rs.l    1
v_tmp           rs.l    4
v_decbuf        rs.b    12              ; putdec/s_dec digits (built backwards)
v_dis_sp        rs.l    1               ; dis_one stack pointer for d_invalid
v_basbase       rs.l    1               ; RAM start of the last BA (0: none since reset)
; ---- user context (saved on every entry, loaded on every resume)
r_d0            rs.l    8               ; D0-D7
r_a0            rs.l    7               ; A0-A6
r_usp           rs.l    1
r_ssp           rs.l    1
r_pc            rs.l    1
r_sr            rs.w    1
r_vec           rs.w    1               ; vector of the last entry
r_ssw           rs.w    1               ; group 0: special status word
r_fa            rs.l    1               ; group 0: access address
r_ir            rs.w    1               ; group 0: instruction register
; ---- breakpoints
bp_addr         rs.l    NBPALL
bp_save         rs.w    NBPALL
bp_count        rs.w    NBPALL          ; pass count (stop when it reaches 1)
bp_flags        rs.b    NBPALL          ; BPF_xxx bits
                rs.w    0
MON_DATA_END    rs.b    0

BPF_USED        equ     0
BPF_IN          equ     1               ; ILLEGAL opcode currently in memory

SM_STEP         equ     1               ; single step (T bit)
SM_RESUME       equ     2               ; step off a breakpoint, then continue
SM_OVER         equ     3               ; running to a temporary breakpoint

                if      MON_DATA_END>(MON_STACK_TOP-1024)
                fail    "monitor workspace leaves less than 1K for the monitor stack"
                endif

;=============================================================================
; ROM image
;=============================================================================
                org     ROM_BASE

;------------------------------------------------- exception vector table
; Offsets 0 and 4 are read through the boot overlay at reset (H2): the reset
; SSP and the reset PC. The PC must be an address in $80000-$BFFFF so that
; the first instruction fetch switches the overlay off.
; The table is copied to RAM $00000-$003FF at reset; the CPU uses the RAM
; copy for every exception after reset, so user programs can change vectors.
rom_vectors:
                dc.l    MON_STACK_TOP           ; 0 reset: initial SSP
                dc.l    cold_start              ; 1 reset: initial PC
vn              set     2
                rept    254
vh              set     exc_stubs+(vn-2)*8      ; default: the vector's stub
                if      vn=V_TRACE
vh              set     trace_handler
                endif
                if      vn=V_NMI
vh              set     nmi_handler
                endif
                if      vn=V_TRAP15
vh              set     api_entry
                endif
                if      vn=VEC_DUART
vh              set     duart_isr
                endif
                dc.l    vh
vn              set     vn+1
                endr

;----------------------------------------------------------- ROM header
                dc.b    "MON68K"                ; $80400: signature
                dc.w    $0100                   ; version 1.00
                dc.l    api_entry               ; for reference only: use TRAP #15
                dc.l    duart_isr               ; monitor's 68681 service routine
                dc.l    cold_start

;=============================================================================
; Cold start
;=============================================================================
; Entered from the reset vector with SR = $2700 (S=1, T=0, mask 7) and
; SSP = MON_STACK_TOP. The overlay is now off (this fetch is in $8xxxx).
; Nothing in RAM can be trusted: the workspace is tested without using the
; stack, then cleared, initialised from ROM and only then used.
cold_start:
                move.w  #$2700,sr
                lea     MON_STACK_TOP,sp

; --- 1. quick test of the vector and workspace RAM ($00000-$00FFF) without
;        a stack: address-in-address, then its complement.
                lea     RAM_BASE,a0
.wt1            move.l  a0,d0
                move.l  d0,(a0)+
                cmpa.l  #MON_STACK_TOP,a0
                blo    .wt1
                lea     RAM_BASE,a0
.wt2            move.l  a0,d0
                cmp.l   (a0),d0
                bne    .wfail0
                not.l   d0
                move.l  d0,(a0)+
                cmpa.l  #MON_STACK_TOP,a0
                blo    .wt2
                lea     RAM_BASE,a0
.wt3            move.l  a0,d0
                not.l   d0
                cmp.l   (a0)+,d0
                bne    .wfail
                cmpa.l  #MON_STACK_TOP,a0
                blo    .wt3
                bra    .wok
.wfail:         subq.l  #4,a0                   ; (a0)+ already advanced
.wfail0:        ; RAM below $1000 is unusable: light both LEDs, report on the
                ; serial port without using a stack, and stop.
                movea.l a0,a5                   ; failing address
                lea     DUART,a6
                bsr_ns  duart_hwinit_ns,a4
                move.b  #OP_LED_USER|OP_LED_MON,D_SOPR(a6)
                lea     msg_ramfail(pc),a3
                bsr_ns  ns_puts,a4
                move.l  a5,d6
                bsr_ns  ns_puthex5,a4
.halt           bra    .halt

; --- 2. clear the workspace, then copy the initialised variables
.wok            lea     MON_DATA,a0
.clr            clr.l   (a0)+
                cmpa.l  #MON_STACK_TOP,a0
                blo    .clr
                lea     IDATA_ROM(pc),a0
                lea     IDATA_START,a1
                move.w  #(IDATA_END-IDATA_START)-1,d0
.cpd            move.b  (a0)+,(a1)+
                dbra    d0,.cpd

; --- 3. copy the vector table to RAM and read it back (this also shows the
;        overlay is off: with the overlay on, reads would return flash)
                lea     rom_vectors(pc),a0
                lea     VEC_TABLE,a1
                move.w  #256-1,d0
.cpv            move.l  (a0)+,(a1)+
                dbra    d0,.cpv
                lea     rom_vectors+8(pc),a0    ; entries 0/1 are the same in both
                lea     VEC_TABLE+8,a1
                move.w  #254-1,d0
                moveq   #0,d7                   ; d7 = vector check result
.vfy            cmpm.l  (a0)+,(a1)+
                dbne    d0,.vfy
                beq    .vok
                moveq   #-1,d7
.vok
; --- 4. user context defaults
                bsr     user_ctx_init

; --- 5. serial port, LEDs, banner
                bsr     duart_init
                st      v_inmon
                move.w  #$2400,sr               ; 68681 (level 5) and NMI (7) enabled
                bsr     led_mon_on
                PRINT   <13,10,13,10>
                PRINT   <"MON68K 1.0 for core68008 (MC68008, 8 MHz). Type HE for help.",13,10>
                PRINT   <"RAM $00000-$7FFFF  ROM $80000-$BFFFF  Junior bus $C0000-$CFFFF  68681 $F0000",13,10>
                tst.l   d7
                beq    .ok
                PRINT   <"WARNING: vector table in RAM does not read back (RAM or boot overlay fault)",13,10>
.ok             bra     cmd_loop

; user_ctx_init: default registers for user programs.
user_ctx_init:
                lea     r_d0,a0
                moveq   #15-1,d0
.c              clr.l   (a0)+
                dbra    d0,.c
                move.l  #USER_USP_INIT,r_usp
                move.l  #USER_SSP_INIT,r_ssp
                move.l  #USER_RAM,r_pc
                move.w  #USER_SR_INIT,r_sr
                clr.w   r_vec
                rts

;----------------------------------------------- no-stack helpers (cold start)
; duart_hwinit_ns: minimal 68681 channel A setup, A6 = DUART, link A4.
duart_hwinit_ns:
                move.b  #0,D_IMR(a6)
                move.b  #CR_RSTRX,D_CRA(a6)
                move.b  #CR_RSTTX,D_CRA(a6)
                move.b  #CR_RSTERR,D_CRA(a6)
                move.b  #CR_RSTMR,D_CRA(a6)
                move.b  #MR1A_VAL,D_MRA(a6)
                move.b  #MR2A_VAL,D_MRA(a6)
                move.b  #BAUD_ACR,D_ACR(a6)
                move.b  #BAUD_CSR,D_CSRA(a6)
                move.b  #0,D_OPCR(a6)
                move.b  #OP_RTS,D_SOPR(a6)
                move.b  #CR_RXEN|CR_TXEN,D_CRA(a6)
                jmp     (a4)

; ns_puts: print the string at A3 (polled), A6 = DUART, link A4. Uses D5.
ns_puts:
.l              move.b  (a3)+,d5
                beq    .e
.w              btst    #SR_TXRDY,D_SRA(a6)
                beq    .w
                move.b  d5,D_THRA(a6)
                bra    .l
.e              jmp     (a4)

; ns_puthex5: print D6 as 5 hex digits, A6 = DUART, link A4. Uses D4/D5.
ns_puthex5:
                lsl.l   #8,d6
                lsl.l   #4,d6                   ; bits 19-16 to the top nibble
                moveq   #5-1,d4
.l              rol.l   #4,d6
                move.b  d6,d5
                andi.b  #$0F,d5
                addi.b  #'0',d5
                cmpi.b  #'9',d5
                bls    .w
                addq.b  #7,d5
.w              btst    #SR_TXRDY,D_SRA(a6)
                beq    .w
                move.b  d5,D_THRA(a6)
                dbra    d4,.l
                jmp     (a4)

msg_ramfail     dc.b    13,10,"MON68K: RAM FAILURE in $00000-$00FFF at $",0
                even

;------------------------------------------------ initialised data (ROM copy)
IDATA_ROM:
                dc.b    1                       ; v_abort_en
                dc.b    1                       ; v_echo
                dc.b    0                       ; v_imr
                dc.b    0                       ; v_rtsoff
                dc.l    $80                     ; v_mdlen
                dc.l    16                      ; v_dilen
IDATA_ROM_END:
                if      (IDATA_ROM_END-IDATA_ROM)!=(IDATA_END-IDATA_START)
                fail    "IDATA_ROM does not match the IDATA layout"
                endif

;=============================================================================
                include "util.asm"
                include "serial.asm"
                include "except.asm"
                include "cmds.asm"
                include "srec.asm"
                include "api.asm"
                include "disasm.asm"
                include "flash.asm"
;=============================================================================

mon_code_end:                                   ; end of the monitor (FL protects up to here)

;------------------------------------------------ EhBASIC (assembled separately)
                if      *>BASIC_ROM
                fail    "the monitor has grown into the BASIC area at BASIC_ROM"
                endif
                dcb.b   BASIC_ROM-*,$FF
basic_image:    incbin  "basic/ehbasic.bin"

rom_end:
                if      rom_end>(ROM_BASE+ROM_SIZE)
                fail    "monitor does not fit in the 256K flash"
                endif
                dcb.b   ROM_BASE+ROM_SIZE-rom_end,$FF   ; pad image to 256K

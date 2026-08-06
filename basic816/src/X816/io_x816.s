;;;
;;; I/O routines specific to the X816
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; Everything goes through the kernel jump table at $00:FE00; there is
;;; no direct hardware access except the VERA text-matrix read in
;;; SCRCOPYLINE (the kernel has no read-at-xy call).
;;;

.include "X816/kernel_x816.s"
.include "X816/screen_x816.s"
.include "X816/keyboard_x816.s"
; (ints_x816.s / floats_x816.s are included from integers.s / floats.s:
;  they use the THROW macro, which interpreter.s must define first)

TEXT_COLS = 80                  ; The kernel console is 80x60
TEXT_ROWS = 60

.section variables
LINES_VISIBLE   .byte ?         ; Rows for pagination (bios.s PAGINATE)
RNDSEED         .word ?         ; Software PRNG state (no RNG hardware)
.send

; On the C256 KEYFLAG is a kernel bank-0 byte ($000F8A) raised by the
; Ctrl-C interrupt; that address is inside the X816's CPU stack. The
; interpreter only ever clears it, and break detection goes through
; FK_TESTBREAK here, so a direct-page byte of our own satisfies it.
.section globals
KEYFLAG         .byte ?
.send

;
; Initialize the I/O system.
;
; NOTE: interrupts are NOT unmasked here, though it is the obvious place
; and a CLI did live here. It could not work: this routine brackets
; itself in PHP/PLP, and so does its caller INITBASIC, so both PLPs
; restore the masked I flag that K_EXEC handed over and the CLI is
; undone before anything can observe it. The result was a console with
; no cursor — the blink is a VSYNC handler (X816_Calypsi ccursor.s in
; KIRQ_VSYNC), so a masked I flag switches it off permanently. Typing
; still worked throughout, because con_getkey polls the SMC over I2C
; rather than being fed by an interrupt, which is what made the symptom
; look like a cursor problem rather than an interrupt one.
;
; The CLI is in START (basic816.s) instead, outside every PHP/PLP pair,
; which is where PORT.md §3's entry sequence always said it belonged.
;
INITIO      .proc
            PHP

            setas
            LDA #DEV_SCREEN         ; Console = kernel screen/keyboard
            STA @lBCONSOLE

            LDA #TEXT_ROWS          ; Pagination limit for the 80x60 console
            STA @lLINES_VISIBLE

            LDA #0                  ; No Ctrl seen yet: FK_TESTBREAK would
            STA @lCTRL_DOWN         ;  otherwise read uninitialised RAM as a
                                    ;  held Ctrl and break on the first key

            setal
            LDA #$2A55              ; Seed the software PRNG (any nonzero)
            STA @lRNDSEED

            PLP
            RETURN
            .pend

;
; Sets ARGUMENT1 to the current time. The X816 has no RTC; phase 3 may
; map this to KERN_TIME_GET. For now: 0.
;
GETTIME     .proc
            PHP
            setal
            STZ ARGUMENT1
            STZ ARGUMENT1+2
            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1
            PLP
            RETURN
            .pend

;
; Sets ARGUMENT1 to the current date. No RTC: 0.
;
GETDATE     .proc
            PHP
            setal
            STZ ARGUMENT1
            STZ ARGUMENT1+2
            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1
            PLP
            RETURN
            .pend

; Print a new line
PRINTCR     .proc
            PHP
            setal
            PHA

            setas
            LDA #CHAR_CR
            CALL PRINTC

            setal
            PLA
            PLP
            RETURN
            .pend

; Print the accumulator as hex (monitor helper)
PRINTH      .proc
            PHP
            CALL PRHEXW
            PLP
            RETURN
            .pend

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
; K_EXEC hands over in native mode with M=0/X=0 but with interrupts
; masked (the shell never re-enables them) — the CLI here is what makes
; the kernel's keyboard queue and cursor blink run at all.
;
INITIO      .proc
            PHP

            setas
            LDA #DEV_SCREEN         ; Console = kernel screen/keyboard
            STA @lBCONSOLE

            LDA #TEXT_ROWS          ; Pagination limit for the 80x60 console
            STA @lLINES_VISIBLE

            setal
            LDA #$2A55              ; Seed the software PRNG (any nonzero)
            STA @lRNDSEED

            CLI                     ; Interrupts on (masked at handover)

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

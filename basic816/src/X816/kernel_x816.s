;;;
;;; X816 kernel crossing glue
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; Width discipline (from X816_Library system/x816kernel.asm): the
;;; kernel is entered with M=0/X=0 via JSL and clobbers A/X/Y and flags;
;;; it preserves only D and DBR. Every wrapper here saves the caller's
;;; state, crosses once, and restores on every path. Arguments are
;;; masked so the hidden high byte of A never leaks into a call.
;;;

;
; Check whether the user has pressed Ctrl-C.
; Drop-in replacement for the Foenix kernel's FK_TESTBREAK:
; called with JSL from interpreter.s / listing.s / repl.s.
;
; There is no $03 to look for. The kernel folds Shift into the character
; it returns but reports Ctrl as a key event in its own right, leaving
; the meaning to the caller (see KEY_LCTRL in x816_kernel.inc). Holding
; Ctrl and pressing C therefore arrives as two polls: $013A, then 'c'.
;
; So Ctrl sets a latch and the next key decides. con_getkey discards
; every key-up except Shift's, so the release of Ctrl is never seen and
; the latch cannot be cleared by it — instead the next key spends it,
; whatever that key is. The window in which a stray 'c' could be read as
; a break is thus exactly one keystroke after Ctrl was pressed.
;
; Note this consumes the key it polls, which is the same bargain the
; C256 build makes with its interrupt-set flag: keystrokes typed at a
; running program are swallowed by the break check.
;
; Outputs:
;   C set if BREAK (Ctrl-C) was pressed, clear otherwise
;
FK_TESTBREAK    PHX
                PHY
                PHP
                setaxl
                JSL KERN_CON_GETKEY     ; Non-blocking key poll
                BCS no_break            ; Kernel error: treat as no key
                CMP #0
                BEQ no_break            ; Nothing waiting: the latch survives

                CMP #KEY_LCTRL          ; Ctrl itself: arm the latch
                BEQ arm_latch
                CMP #KEY_RCTRL
                BEQ arm_latch

                TAX                     ; Any other key spends the latch
                setas
                LDA @l CTRL_DOWN
                BEQ not_armed           ; Ctrl was not held: ordinary keystroke

                LDA #0
                STA @l CTRL_DOWN
                setal
                TXA                     ; Is this the C of Ctrl-C?
                CMP #'c'
                BEQ break_hit
                CMP #'C'
                BEQ break_hit
                CMP #CHAR_CTRL_C        ; Should a later kernel map it after all
                BEQ break_hit
                BRA no_break

not_armed       setal
                BRA no_break

arm_latch       setas
                LDA #1
                STA @l CTRL_DOWN
                setal

no_break        PLP
                PLY
                PLX
                CLC
                RTL
break_hit       PLP
                PLY
                PLX
                SEC
                RTL

;
; Stub for Foenix kernel file/dir entry points not yet mapped to
; KERN_FS_* (phase 3). Refuses with carry set.
;
FK_STUB         SEC
                RTL

FK_LOAD = FK_STUB
FK_SAVE = FK_STUB
FK_RUN = FK_STUB
FK_DELETE = FK_STUB
FK_COPY = FK_STUB
FK_DIROPEN = FK_STUB
FK_DIRNEXT = FK_STUB
FK_DIRREAD = FK_STUB
FK_DIRWRITE = FK_STUB

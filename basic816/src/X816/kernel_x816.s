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
; Outputs:
;   C set if BREAK (Ctrl-C) was pressed, clear otherwise
;
FK_TESTBREAK    PHX
                PHY
                PHP
                setaxl
                JSL KERN_CON_GETKEY     ; Non-blocking key poll
                BCS no_break            ; Kernel error: treat as no key
                CMP #CHAR_CTRL_C        ; Was it Ctrl-C?
                BEQ break_hit
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

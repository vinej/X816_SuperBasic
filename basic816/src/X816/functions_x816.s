;;;
;;; X816-specific functions
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;

;
; INKEY(x) -- non-blocking key poll. Returns the ASCII code of the
; waiting key, or 0 if none (or if the key has no character, e.g. an
; arrow key). The argument is evaluated and ignored, as on the C256.
;
FN_INKEY    .proc
            FN_START "FN_INKEY"
            PHP

            CALL EVALEXPR               ; Evaluate (and ignore) the argument

            setaxl
            JSL KERN_CON_GETKEY         ; Non-blocking key poll
            BCC got_key
            LDA #0                      ; Kernel error: report no key
got_key     CMP #KEY_SPECIAL            ; Keys with no character read as 0
            BLT store
            LDA #0

store       STA ARGUMENT1
            STZ ARGUMENT1+2

            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1

            FN_END
            PLP
            RETURN
            .pend

;
; RND(x) -- random number. The C256 returns a float in [0,1) from the
; GABE hardware RNG; the X816 has neither, and floats arrive in phase 2.
; Until then RND throws rather than lie with a constant.
;
FN_RND      .proc
            FN_START "FN_RND"
            THROW ERR_TYPE
            .pend

;
; GETTIME(x) / GETDATE(x) -- no RTC on the X816: return 0 (phase 3 may
; map GETTIME to the kernel millisecond clock).
;
F_GETTIME   .proc
            FN_START "F_GETTIME"
            PHP

            CALL EVALEXPR               ; Evaluate (and ignore) the argument
            CALL GETTIME

            FN_END
            PLP
            RETURN
            .pend

F_GETDATE   .proc
            FN_START "F_GETDATE"
            PHP

            CALL EVALEXPR               ; Evaluate (and ignore) the argument
            CALL GETDATE

            FN_END
            PLP
            RETURN
            .pend

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
; RND(x) -- random float in [0,1). No RNG hardware on the X816: a
; 16-bit xorshift PRNG (seeded in INITIO) supplies 24 bits, converted
; through ITOF, then the exponent field is dropped by 24 so the result
; is r / 2^24 -- uniform on the 2^-24 grid. The argument is evaluated
; and ignored, as on the C256.
;
FN_RND      .proc
            FN_START "FN_RND"
            PHP

            CALL EVALEXPR               ; Evaluate (and ignore) the argument

            setaxl
            CALL RNDSTEP                ; Low 16 bits
            STA ARGUMENT1
            CALL RNDSTEP                ; High 8 bits
            AND #$00FF
            STA ARGUMENT1+2
            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1
            setal

            CALL ITOF                   ; Float in [0, 2^24)

            LDA ARGUMENT1+2             ; Zero stays zero
            AND #$7F80
            BEQ rnd_done

            SEC                         ; Exponent -= 24: divide by 2^24.
            LDA ARGUMENT1+2             ; (Safe field arithmetic: the
            SBC #24 << 7                ;  exponent here is >= 127, so it
            STA ARGUMENT1+2             ;  cannot borrow into the sign)

rnd_done    FN_END
            PLP
            RETURN
            .pend

;
; Advance the xorshift16 PRNG one step
;
; Outputs:
;   A = the new 16-bit state (assumes 16-bit A)
;
RNDSTEP     .proc
            .al                     ; (contract: caller runs 16-bit A/X)
            LDA @lRNDSEED
            BNE step                    ; Never let the state stick at 0
            LDA #$2A55
step        PHA                         ; x ^= x << 7
            ASL A
            ASL A
            ASL A
            ASL A
            ASL A
            ASL A
            ASL A
            EOR 1,S
            PLX                         ; (discard the saved copy)
            PHA                         ; x ^= x >> 9
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            EOR 1,S
            PLX
            PHA                         ; x ^= x << 8
            ASL A
            ASL A
            ASL A
            ASL A
            ASL A
            ASL A
            ASL A
            ASL A
            EOR 1,S
            PLX
            STA @lRNDSEED
            RETURN
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

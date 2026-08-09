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
; GETTIME$ and GETDATE$ live in X816/clock_x816.s now. They took a
; parenthesised argument and threw it away, and returned the INTEGER 0
; from something named with a dollar sign; they take no parentheses
; now, like TIMER and FRAMES beside them, and answer strings.
;

;
; TIMER -- milliseconds since the machine booted, as a 32-bit integer.
;
; Takes no argument, unlike INKEY and RND, which require a parenthesised
; one and throw it away because the C256 versions did. That is what
; FN_START/FN_END are for -- they consume the parentheses -- so a
; function that wants none simply does not use them. EVAL_FUNC brackets
; the call with OPENPARAMS/CLOSEPARAMS either way.
;
; The counter is hardware (a free-running 1 kHz timer at $9F90, exact at
; either CPU speed), not a jiffy count derived from the display, so it
; does not drift with TURBO and does not stop when interrupts are
; masked. It wraps after about 49 days.
;
FN_TIMER    .proc
            TRACE "FN_TIMER"
            PHP
            setaxl

            JSL KERN_TIME_GET           ; C = ms low, X = ms high
            BCC timer_ok
            LDA #0
            TAX
timer_ok    STA ARGUMENT1
            TXA
            STA ARGUMENT1+2

            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1

            PLP
            RETURN
            .pend

;
; FRAMES -- the VSYNC frame counter, 16-bit and wrapping.
;
; The right clock for animation: it advances 60 times a second whatever
; the CPU is doing. Unlike TIMER it IS maintained by the interrupt
; handler, so it only moves while interrupts are enabled.
;
FN_FRAMES   .proc
            TRACE "FN_FRAMES"
            PHP
            setaxl

            JSL KERN_IRQ_FRAMES
            BCC frames_ok
            LDA #0
frames_ok   STA ARGUMENT1
            STZ ARGUMENT1+2

            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1

            PLP
            RETURN
            .pend

;
; VER -- the kernel's version, (major << 8) | minor.
;
; Takes no parentheses, like TIMER and FRAMES beside it, which is not a
; detail here: a no-argument function is the one thing that exercises
; the minus rule, and the minus rule is the one place that has to know
; which TABLE a token came from. VER is the first keyword to live in
; TOKENS3, so "PRINT VER-1" is the check that the third table is
; understood everywhere and not merely reached -- the same job VSYNC did
; for TOKENS2 (PORT.md 12).
;
; K_SYS_VERSION cannot fail and has no error return; the kernel this was
; written against answers $0001.
;
FN_VER      .proc
            TRACE "FN_VER"
            PHP
            setaxl

            JSL KERN_SYS_VERSION
            STA ARGUMENT1
            STZ ARGUMENT1+2

            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1

            PLP
            RETURN
            .pend

;
; FRE -- bytes still free for the program, its variables and the heap.
;
; Takes no parentheses. Classic BASICs want a dummy argument here and
; throw it away; there is nothing to throw away on this machine and
; TIMER, FRAMES and VER beside it already set the precedent.
;
; ONE number, because there is one space. Variables grow UP from the end
; of the program at NEXTVAR and strings grow DOWN from the top of BRAM
; at HEAP, and they meet in the middle -- VAR_ALLOC's collision check is
; exactly this subtraction, which is why this is the honest number and
; not a sum of two pools.
;
; It does NOT count anything the garbage collector could reclaim, so it
; is a floor and not a promise.
;
FN_FRE      .proc
            TRACE "FN_FRE"
            PHP
            setaxl

            SEC                         ; HEAP - NEXTVAR, 32-bit
            LDA HEAP
            SBC NEXTVAR
            STA ARGUMENT1
            LDA HEAP+2
            SBC NEXTVAR+2
            AND #$00FF                  ; both are 24-bit pointers held in
                                        ;  four bytes; the top byte of each
                                        ;  is not part of the address
            STA ARGUMENT1+2
            BPL fre_ok                  ; a negative answer would mean they
            LDA #0                      ;  had already collided, which
            STA ARGUMENT1               ;  VAR_ALLOC does not allow -- report
            STA ARGUMENT1+2             ;  nothing left rather than nonsense
fre_ok
            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1

            PLP
            RETURN
            .pend

;
; VPEEK(addr) -- read a byte of VRAM. The inverse of VPOKE.
;
FN_VPEEK    .proc
            FN_START "FN_VPEEK"
            PHP
            setaxl

            CALL EVALEXPR
            CALL ASS_ARG1_INT

            setas
            LDA #0                      ; Data port 0, DCSEL 0
            STA @l VERA_CTRL
            LDA ARGUMENT1
            STA @l VERA_ADDR_L
            LDA ARGUMENT1+1
            STA @l VERA_ADDR_M
            LDA ARGUMENT1+2
            AND #$01
            STA @l VERA_ADDR_H
            LDA @l VERA_DATA0

            setal
            AND #$00FF
            STA ARGUMENT1
            STZ ARGUMENT1+2
            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1

            FN_END
            PLP
            RETURN
            .pend

;
; CURSORX / CURSORY -- where the console cursor is.
;
; WRITTEN BUT NOT REACHABLE: they have no token. See the note in
; tokens.s beside PAL -- a no-argument function needs a base id for the
; minus-sign exception to be safe, and there are none left. Kept here
; because the code is right and the day the minus rule asks for a token
; TYPE instead of a number, they are two DEFTOKs away.
;
FN_CURSORX  .proc
            TRACE "FN_CURSORX"
            PHP
            setaxl

            JSL KERN_CON_GETXY          ; C = column, X = row
            BCC curx_ok
            LDA #0
curx_ok     AND #$00FF
            STA ARGUMENT1
            STZ ARGUMENT1+2
            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1

            PLP
            RETURN
            .pend

FN_CURSORY  .proc
            TRACE "FN_CURSORY"
            PHP
            setaxl

            JSL KERN_CON_GETXY          ; the row comes back in X
            BCC cury_ok
            LDX #0
cury_ok     TXA
            AND #$00FF
            STA ARGUMENT1
            STZ ARGUMENT1+2
            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1

            PLP
            RETURN
            .pend

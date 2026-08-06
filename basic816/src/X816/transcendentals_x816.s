;;;
;;; Transcendental function stubs for the X816 (phase 2)
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The C256 transcendentals.s drives the FP coprocessor inline (90
;;; register accesses); on the X816 those registers are plain SDRAM, so
;;; running it would produce silent garbage. Until the software port of
;;; the polynomial evaluators lands, every function throws rather than
;;; lie. (Q_FP_POW_INT, used by ^, already has a software version in
;;; floats_x816.s.)
;;;

FP_SIN      .proc
            THROW ERR_TYPE
            .pend

FP_COS      .proc
            THROW ERR_TYPE
            .pend

FP_TAN      .proc
            THROW ERR_TYPE
            .pend

FP_LN       .proc
            THROW ERR_TYPE
            .pend

FP_EXP      .proc
            THROW ERR_TYPE
            .pend

FP_ASIN     .proc
            THROW ERR_TYPE
            .pend

FP_ACOS     .proc
            THROW ERR_TYPE
            .pend

FP_ATAN     .proc
            THROW ERR_TYPE
            .pend

;
; SQR(x) -- square root, by Newton-Raphson on the software float ops.
;
; The other functions on this page need polynomial evaluators; this one
; does not, which is why it is the first of them to be real. It is also
; the one most missed: a BASIC without SQR cannot do Pythagoras.
;
;   y <- (y + x/y) / 2
;
; The seed comes from the exponent field itself. Halving a float's bit
; pattern halves its exponent, which is very nearly a square root, and
; adding back the bias correction leaves under 3% error:
;
;   y0 = (bits(x) >> 1) + $1FC00000
;
; 4.0 seeds exactly 2.0 and 1.0 seeds exactly 1.0. Newton doubles the
; correct digits each pass, so 3%  ->  3e-4  ->  5e-8, and four passes
; are comfortably inside single precision even with this engine
; truncating rather than rounding.
;
FP_SQR      .proc
            PHP
            setaxl

            LDA ARGUMENT1+2         ; SQR(0) = 0, and a zero exponent field
            AND #$7F80              ;  is the only thing that reaches the
            BNE sqr_signed          ;  divide below as a zero divisor
            CALL FPZERO1
            PLP
            RETURN

sqr_signed  .al
            LDA ARGUMENT1+2         ; A negative operand has no real root
            BPL sqr_start
            BRL sqr_domain

sqr_start   LDA ARGUMENT1           ; Keep x; ARGUMENT1 is about to be reused
            STA @l FP_SX
            LDA ARGUMENT1+2
            STA @l FP_SX+2

            LSR A                   ; y0 = (bits >> 1) + $1FC00000, a 32-bit
            STA @l FP_SY+2          ;  shift of the pattern: high word first,
            LDA ARGUMENT1           ;  then the low word takes the carry
            ROR A
            STA @l FP_SY
            CLC
            LDA @l FP_SY+2
            ADC #$1FC0
            STA @l FP_SY+2

            LDX #4
sqr_iter    PHX

            LDA @l FP_SX            ; ARGUMENT1 = x, ARGUMENT2 = y
            STA ARGUMENT1
            LDA @l FP_SX+2
            STA ARGUMENT1+2
            LDA @l FP_SY
            STA ARGUMENT2
            LDA @l FP_SY+2
            STA ARGUMENT2+2
            setas
            LDA #TYPE_FLOAT
            STA ARGTYPE1
            STA ARGTYPE2
            setal
            CALL OP_FP_DIV          ; x/y

            LDA @l FP_SY            ; + y
            STA ARGUMENT2
            LDA @l FP_SY+2
            STA ARGUMENT2+2
            CALL OP_FP_ADD

            LDA #$0000              ; * 0.5
            STA ARGUMENT2
            LDA #$3F00
            STA ARGUMENT2+2
            CALL OP_FP_MUL

            LDA ARGUMENT1           ; y <- the new estimate
            STA @l FP_SY
            LDA ARGUMENT1+2
            STA @l FP_SY+2

            PLX
            DEX
            BNE sqr_iter

            setas                   ; ARGUMENT1 already holds the answer
            LDA #TYPE_FLOAT
            STA ARGTYPE1
            setal

            PLP
            RETURN

sqr_domain  THROW ERR_DOMAIN
            .pend

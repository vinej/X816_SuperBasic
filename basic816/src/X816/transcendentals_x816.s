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

; Float constants, as IEEE-754 single bit patterns.
FC_TWO_OVER_PI = $3F22F983
FC_PI_OVER_2   = $3FC90FDB
FC_HALF        = $3F000000
FC_NEG_HALF    = $BF000000

; sin(r) = r * P(u) and cos(r) = Q(u), both in u = r*r, on [-pi/4, pi/4].
; Measured against double precision across that interval, the worst error
; is 6.8e-8 for sin and 8.6e-8 for cos: inside a single-precision ulp at
; 1.0, and far inside the six digits PRINT shows.
FC_SC0 = $3638EF1D          ;  1/362880
FC_SC1 = $B9500D01          ; -1/5040
FC_SC2 = $3C088889          ;  1/120
FC_SC3 = $BE2AAAAB          ; -1/6
FC_SC4 = $3F800000          ;  1

FC_CC0 = $37D00D01          ;  1/40320
FC_CC1 = $BAB60B61          ; -1/720
FC_CC2 = $3D2AAAAB          ;  1/24
FC_CC3 = $BF000000          ; -1/2
FC_CC4 = $3F800000          ;  1

TFSET1      .macro const                ; ARGUMENT1 = an immediate float
            LDA #<>(\const)
            STA ARGUMENT1
            LDA #(\const) >> 16
            STA ARGUMENT1+2
            setas
            LDA #TYPE_FLOAT
            STA ARGTYPE1
            setal
            .endm

TFSET2      .macro const                ; ARGUMENT2 = an immediate float
            LDA #<>(\const)
            STA ARGUMENT2
            LDA #(\const) >> 16
            STA ARGUMENT2+2
            setas
            LDA #TYPE_FLOAT
            STA ARGTYPE2
            setal
            .endm

TFGET1      .macro addr                 ; ARGUMENT1 = a saved float
            LDA @l \addr
            STA ARGUMENT1
            LDA @l \addr+2
            STA ARGUMENT1+2
            setas
            LDA #TYPE_FLOAT
            STA ARGTYPE1
            setal
            .endm

TFGET2      .macro addr                 ; ARGUMENT2 = a saved float
            LDA @l \addr
            STA ARGUMENT2
            LDA @l \addr+2
            STA ARGUMENT2+2
            setas
            LDA #TYPE_FLOAT
            STA ARGTYPE2
            setal
            .endm

TFPUT1      .macro addr                 ; save ARGUMENT1
            LDA ARGUMENT1
            STA @l \addr
            LDA ARGUMENT1+2
            STA @l \addr+2
            .endm

TFMAC       .macro const                ; one Horner step: acc = acc*u + c
            TFGET2 FP_TU
            CALL OP_FP_MUL
            TFSET2 \const
            CALL OP_FP_ADD
            .endm

;
; Range reduction, shared by SIN, COS and TAN.
;
; The polynomials are only good on [-pi/4, pi/4]; the whole circle is
; brought into that range by subtracting whole multiples of pi/2 and
; remembering how many were taken.
;
;   n = round(x * 2/pi)     r = x - n*(pi/2)     q = n & 3
;
; Rounding is trunc(t +/- 0.5) because FTOI truncates toward zero, and
; the quadrant comes from the low word of n, where two's complement
; makes AND #3 the right residue for negative angles as well.
;
; Inputs:  ARGUMENT1 = x
; Outputs: FP_TR = r, FP_TU = r*r, FP_TQ = quadrant
;
FP_REDUCE   .proc
            PHP
            setaxl

            TFPUT1 FP_TX                ; keep x: ARGUMENT1 is about to go

            TFSET2 FC_TWO_OVER_PI
            CALL OP_FP_MUL              ; t = x * 2/pi

            LDA ARGUMENT1+2             ; round away from zero
            BMI red_neg
            TFSET2 FC_HALF
            BRA red_round
red_neg     TFSET2 FC_NEG_HALF
red_round   CALL OP_FP_ADD

            CALL FTOI                   ; n
            LDA ARGUMENT1
            AND #$0003
            STA @l FP_TQ

            CALL ITOF                   ; and back to a float
            TFSET2 FC_PI_OVER_2
            CALL OP_FP_MUL              ; n * pi/2
            TFPUT1 FP_TR

            TFGET1 FP_TX                ; r = x - n*(pi/2)
            TFGET2 FP_TR
            CALL OP_FP_SUB
            TFPUT1 FP_TR

            TFGET2 FP_TR                ; u = r*r
            CALL OP_FP_MUL
            TFPUT1 FP_TU

            PLP
            RETURN
            .pend

;
; The two polynomials, and a sign flip. Plain subroutines rather than
; .proc so the quadrant dispatch can choose between them.
;
TSINPOLY    TFSET1 FC_SC0
            TFMAC FC_SC1
            TFMAC FC_SC2
            TFMAC FC_SC3
            TFMAC FC_SC4
            TFGET2 FP_TR                ; sin(r) = r * P(u)
            CALL OP_FP_MUL
            RTS

TCOSPOLY    TFSET1 FC_CC0
            TFMAC FC_CC1
            TFMAC FC_CC2
            TFMAC FC_CC3
            TFMAC FC_CC4
            RTS

; Negating a zero would leave a negative zero, which prints as "-0".
TFNEGATE    LDA ARGUMENT1+2
            AND #$7F80
            BEQ tneg_done
            LDA ARGUMENT1+2
            EOR #$8000
            STA ARGUMENT1+2
tneg_done   RTS

;
; Pick the polynomial and the sign from the quadrant. Y carries an
; offset: 0 for SIN, 1 for COS. cos(x) is sin(x + pi/2) -- one quadrant
; along -- so the two functions differ by that single number.
;
TQUAD       TYA
            CLC
            ADC @l FP_TQ
            AND #$0003
            CMP #1
            BEQ tq_cos
            CMP #2
            BEQ tq_nsin
            CMP #3
            BEQ tq_ncos
            JSR TSINPOLY
            RTS
tq_cos      JSR TCOSPOLY
            RTS
tq_nsin     JSR TSINPOLY
            JSR TFNEGATE
            RTS
tq_ncos     JSR TCOSPOLY
            JSR TFNEGATE
            RTS

FP_SIN      .proc
            PHP
            setaxl
            CALL FP_REDUCE
            LDY #0
            JSR TQUAD
            PLP
            RETURN
            .pend

FP_COS      .proc
            PHP
            setaxl
            CALL FP_REDUCE
            LDY #1                      ; cos(x) = sin(x + pi/2)
            JSR TQUAD
            PLP
            RETURN
            .pend

;
; tan(x) = sin(x) / cos(x). One reduction serves both, so the quadrant
; work happens once and each polynomial is picked straight off it. A
; zero cosine reaches OP_FP_DIV and throws division by zero, which is
; the honest answer for tan(pi/2).
;
FP_TAN      .proc
            PHP
            setaxl
            CALL FP_REDUCE

            LDY #0                      ; sin(x)
            JSR TQUAD
            TFPUT1 FP_TS

            LDY #1                      ; cos(x)
            JSR TQUAD
            TFPUT1 FP_TC

            TFGET1 FP_TS
            TFGET2 FP_TC
            CALL OP_FP_DIV

            PLP
            RETURN
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

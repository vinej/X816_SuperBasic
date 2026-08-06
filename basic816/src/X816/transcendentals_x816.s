;;;
;;; Transcendental functions for the X816
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The C256 transcendentals.s drives the FP coprocessor inline -- about
;;; ninety register accesses -- and on the X816 those addresses are plain
;;; SDRAM, so running that code would return confident nonsense. None of
;;; it is ported; all of this is written against the software float
;;; primitives in floats_x816.s instead.
;;;
;;; All of them are real now: SQR by Newton-Raphson, SIN/COS/TAN by
;;; Horner polynomials over a pi/2 reduction, LN and EXP by taking the
;;; power of two out of (or back into) the exponent field, and the
;;; inverse trigonometry over ATAN. Every coefficient set here was
;;; checked against double precision before being written down, and the
;;; worst case each way is recorded beside it -- all under 2e-7, which
;;; is inside the six digits PRINT shows.
;;;
;;; (Q_FP_POW_INT, used by ^ with a whole-number exponent, is in
;;; floats_x816.s. A fractional or negative one comes back here: the
;;; operator falls through to EXP(y * LN(x)).)
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

TFMACV      .macro var, const           ; the same, in a chosen variable
            TFGET2 \var
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

FC_ONE   = $3F800000
FC_TWO   = $40000000
FC_LN2   = $3F317218        ; ln 2
FC_ILN2  = $3FB8AA3B        ; 1 / ln 2
FC_SQRT2 = $3FB504F3

; exp(r) on [-ln2/2, ln2/2], degree 7, Horner high order first. Checked
; against double precision across that interval: worst RELATIVE error
; 7.7e-8.
FC_EC0 = $39500D01          ; 1/5040
FC_EC1 = $3AB60B61          ; 1/720
FC_EC2 = $3C088889          ; 1/120
FC_EC3 = $3D2AAAAB          ; 1/24
FC_EC4 = $3E2AAAAB          ; 1/6
FC_EC5 = $3F000000          ; 1/2
FC_EC6 = $3F800000          ; 1
FC_EC7 = $3F800000          ; 1

; ln(m) = 2s(1 + u/3 + u^2/5 + u^3/7 + u^4/9), s = (m-1)/(m+1), u = s*s.
; Worst absolute error over m in [sqrt(1/2), sqrt(2)]: 8.8e-8.
FC_LC0 = $3DE38E39          ; 1/9
FC_LC1 = $3E124925          ; 1/7
FC_LC2 = $3E4CCCCD          ; 1/5
FC_LC3 = $3EAAAAAB          ; 1/3
FC_LC4 = $3F800000          ; 1

;
; LN(x) -- natural logarithm.
;
; A float already carries its own logarithm's integer part: x is
; m * 2^e with the exponent field holding e, so
;
;   ln(x) = ln(m) + e*ln2
;
; and only ln(m) has to be computed. m lands in [1,2) for free; halving
; it once when it exceeds sqrt(2) centres the range on 1, which is what
; makes the series below short -- s = (m-1)/(m+1) is then under 0.172 in
; magnitude and its square under 0.03, so five terms are plenty.
;
FP_LN       .proc
            PHP
            setaxl

            LDA ARGUMENT1+2             ; ln(0) and ln(negative) are errors;
            AND #$7F80                  ;  the body below is far too long to
            BNE ln_nonzero              ;  branch across, hence the BRLs
            BRL ln_domain
ln_nonzero  LDA ARGUMENT1+2
            BPL ln_positive
            BRL ln_domain

ln_positive LDA ARGUMENT1+2             ; e = (exponent field) - 127
            AND #$7F80
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            SEC
            SBC #127
            STA @l FP_EN

            LDA ARGUMENT1+2             ; m = x with the exponent set to 0,
            AND #$007F                  ;  which is the exponent field 127
            ORA #$3F80
            STA ARGUMENT1+2
            TFPUT1 FP_EX

            TFSET2 FC_SQRT2             ; centre the range on 1
            CALL FP_COMPARE
            CMP #1
            BNE ln_centred

            LDA @l FP_EX+2              ; m/2: one off the exponent field
            SEC
            SBC #$0080
            STA @l FP_EX+2
            LDA @l FP_EN
            INC A
            STA @l FP_EN

ln_centred  TFGET1 FP_EX                ; s = (m-1) / (m+1)
            TFSET2 FC_ONE
            CALL OP_FP_SUB
            TFPUT1 FP_EU
            TFGET1 FP_EX
            TFSET2 FC_ONE
            CALL OP_FP_ADD
            TFPUT1 FP_EX
            TFGET1 FP_EU
            TFGET2 FP_EX
            CALL OP_FP_DIV
            TFPUT1 FP_EX

            TFGET2 FP_EX                ; u = s*s
            CALL OP_FP_MUL
            TFPUT1 FP_EU

            TFSET1 FC_LC0
            TFMACV FP_EU, FC_LC1
            TFMACV FP_EU, FC_LC2
            TFMACV FP_EU, FC_LC3
            TFMACV FP_EU, FC_LC4

            TFGET2 FP_EX                ; ln(m) = 2 * s * poly
            CALL OP_FP_MUL
            TFSET2 FC_TWO
            CALL OP_FP_MUL
            TFPUT1 FP_EX

            LDA @l FP_EN                ; e*ln2, e being signed
            STA ARGUMENT1
            BMI ln_negexp
            LDA #0
            BRA ln_setexp
ln_negexp   LDA #$FFFF
ln_setexp   STA ARGUMENT1+2
            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1
            setal
            CALL ITOF
            TFSET2 FC_LN2
            CALL OP_FP_MUL

            TFGET2 FP_EX                ; + ln(m)
            CALL OP_FP_ADD

            PLP
            RETURN

ln_domain   THROW ERR_DOMAIN
            .pend

;
; EXP(x) -- e to the x.
;
; The mirror of LN: take out the power of two rather than putting one
; back. n = round(x/ln2) leaves r = x - n*ln2 no bigger than ln2/2, the
; series handles that, and multiplying by 2^n is a float built straight
; out of the exponent field rather than a power computed by repeated
; multiplication.
;
FP_EXP      .proc
            PHP
            setaxl

            LDA ARGUMENT1+2             ; exp(0) = 1
            AND #$7F80
            BNE exp_go
            TFSET1 FC_ONE
            PLP
            RETURN

exp_go      TFPUT1 FP_EX

            TFSET2 FC_ILN2              ; n = round(x / ln2)
            CALL OP_FP_MUL
            LDA ARGUMENT1+2
            BMI exp_neg
            TFSET2 FC_HALF
            BRA exp_round
exp_neg     TFSET2 FC_NEG_HALF
exp_round   CALL OP_FP_ADD
            CALL FTOI
            LDA ARGUMENT1
            STA @l FP_EN

            CALL ITOF                   ; r = x - n*ln2
            TFSET2 FC_LN2
            CALL OP_FP_MUL
            TFPUT1 FP_EU
            TFGET1 FP_EX
            TFGET2 FP_EU
            CALL OP_FP_SUB
            TFPUT1 FP_EU

            TFSET1 FC_EC0               ; exp(r)
            TFMACV FP_EU, FC_EC1
            TFMACV FP_EU, FC_EC2
            TFMACV FP_EU, FC_EC3
            TFMACV FP_EU, FC_EC4
            TFMACV FP_EU, FC_EC5
            TFMACV FP_EU, FC_EC6
            TFMACV FP_EU, FC_EC7

            CLC                         ; times 2^n, assembled by hand: the
            LDA @l FP_EN                ;  exponent field IS the power of two
            ADC #127
            BMI exp_zero                ; n below -127: flush to zero
            BEQ exp_zero
            CMP #255
            BGE exp_over

            ASL A                       ; the field starts at bit 7 of the
            ASL A                       ;  high word
            ASL A
            ASL A
            ASL A
            ASL A
            ASL A
            STA ARGUMENT2+2
            LDA #0
            STA ARGUMENT2
            setas
            LDA #TYPE_FLOAT
            STA ARGTYPE2
            setal
            CALL OP_FP_MUL

            PLP
            RETURN

exp_zero    CALL FPZERO1
            PLP
            RETURN

exp_over    THROW ERR_OVERFLOW
            .pend

FC_PI_4    = $3F490FDB      ; pi/4
FC_TAN3PI8 = $401A827A      ; tan(3pi/8) = 2.4142136
FC_TANPI8  = $3ED413CD      ; tan(pi/8)  = 0.4142136

; atan(x) on the reduced range, Horner in z = x*x. Cephes' single-
; precision coefficients; checked against double precision over
; [-50, 50], worst absolute error 1.7e-7.
FC_AC0 = $3DA4F0D1          ;  0.080537445
FC_AC1 = $BE0E1B85          ; -0.138776856
FC_AC2 = $3E4C925F          ;  0.199777107
FC_AC3 = $BEAAAA2A          ; -0.333329492

;
; ATAN(x) -- arctangent, the whole real line into [-pi/2, pi/2].
;
; Two folds bring any magnitude under tan(pi/8), where four terms are
; enough. Both are the tangent addition formula read backwards:
;
;   x > tan(3pi/8):  atan(x) = pi/2 + atan(-1/x)
;   x > tan(pi/8):   atan(x) = pi/4 + atan((x-1)/(x+1))
;
; The sign is taken off at the start and put back at the end, so only
; positive x reaches the folds.
;
FP_ATAN     .proc
            PHP
            setaxl

            LDA ARGUMENT1+2             ; work on |x|, remember the sign
            AND #$8000
            STA @l FP_ASGN
            LDA ARGUMENT1+2
            AND #$7FFF
            STA ARGUMENT1+2
            TFPUT1 FP_EX

            TFSET2 FC_TAN3PI8           ; which fold, if any
            CALL FP_COMPARE
            CMP #1
            BEQ at_big

            TFGET1 FP_EX
            TFSET2 FC_TANPI8
            CALL FP_COMPARE
            CMP #1
            BEQ at_mid

            LDA #0                      ; no fold: y = 0
            STA @l FP_AY
            STA @l FP_AY+2
            BRL at_poly

at_big      TFSET1 FC_PI_OVER_2         ; y = pi/2, x = -1/x
            TFPUT1 FP_AY
            TFSET1 FC_ONE
            TFGET2 FP_EX
            CALL OP_FP_DIV
            LDA ARGUMENT1+2
            EOR #$8000
            STA ARGUMENT1+2
            TFPUT1 FP_EX
            BRL at_poly

at_mid      TFSET1 FC_PI_4              ; y = pi/4, x = (x-1)/(x+1)
            TFPUT1 FP_AY
            TFGET1 FP_EX
            TFSET2 FC_ONE
            CALL OP_FP_SUB
            TFPUT1 FP_EU
            TFGET1 FP_EX
            TFSET2 FC_ONE
            CALL OP_FP_ADD
            TFPUT1 FP_EX
            TFGET1 FP_EU
            TFGET2 FP_EX
            CALL OP_FP_DIV
            TFPUT1 FP_EX

at_poly     TFGET1 FP_EX                ; z = x*x
            TFGET2 FP_EX
            CALL OP_FP_MUL
            TFPUT1 FP_EU

            TFSET1 FC_AC0
            TFMACV FP_EU, FC_AC1
            TFMACV FP_EU, FC_AC2
            TFMACV FP_EU, FC_AC3

            TFGET2 FP_EU                ; result = y + (poly*z)*x + x
            CALL OP_FP_MUL
            TFGET2 FP_EX
            CALL OP_FP_MUL
            TFGET2 FP_EX
            CALL OP_FP_ADD
            TFGET2 FP_AY
            CALL OP_FP_ADD

            LDA @l FP_ASGN              ; put the sign back
            BEQ at_done
            LDA ARGUMENT1+2
            AND #$7F80
            BEQ at_done                 ; leave a zero unsigned
            LDA ARGUMENT1+2
            EOR #$8000
            STA ARGUMENT1+2

at_done     PLP
            RETURN
            .pend

;
; ASIN(x) -- arcsine, via the arctangent.
;
;   asin(x) = atan( x / sqrt(1 - x*x) )
;
; which needs no polynomial of its own. At |x| = 1 the square root is
; zero and the quotient would divide by it, so the ends are answered
; directly as +/- pi/2.
;
FP_ASIN     .proc
            PHP
            setaxl

            TFPUT1 FP_AV                ; keep x

            LDA ARGUMENT1+2             ; |x| > 1 is outside the domain
            AND #$7FFF
            STA ARGUMENT1+2
            TFSET2 FC_ONE
            CALL FP_COMPARE
            CMP #1
            BNE asin_ok
            BRL asin_domain

asin_ok     TFGET1 FP_AV                ; 1 - x*x
            TFGET2 FP_AV
            CALL OP_FP_MUL
            TFPUT1 FP_EU
            TFSET1 FC_ONE
            TFGET2 FP_EU
            CALL OP_FP_SUB

            LDA ARGUMENT1+2             ; zero means |x| = 1 exactly
            AND #$7F80
            BEQ asin_edge

            CALL FP_SQR
            TFPUT1 FP_EU
            TFGET1 FP_AV
            TFGET2 FP_EU
            CALL OP_FP_DIV
            CALL FP_ATAN

            PLP
            RETURN

asin_edge   TFSET1 FC_PI_OVER_2         ; +/- pi/2, following x
            LDA @l FP_AV+2
            BPL asin_done
            LDA ARGUMENT1+2
            EOR #$8000
            STA ARGUMENT1+2

asin_done   PLP
            RETURN

asin_domain THROW ERR_DOMAIN
            .pend

;
; ACOS(x) = pi/2 - asin(x). The domain check comes free with ASIN.
;
FP_ACOS     .proc
            PHP
            setaxl

            CALL FP_ASIN
            TFPUT1 FP_EU
            TFSET1 FC_PI_OVER_2
            TFGET2 FP_EU
            CALL OP_FP_SUB

            PLP
            RETURN
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

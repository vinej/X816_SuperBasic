;;;
;;; Software integer math for the X816
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The C256 build drives the GABE hardware multiplier (M0_OPERAND_*)
;;; and divider (D1_OPERAND_*). On the X816 those addresses are the CPU
;;; stack ($00:0100+), so the hardware paths are replaced wholesale by
;;; classic shift-add / restoring-division routines. Scratch lives in
;;; the direct page (MATHR) because ROL/ROR have no long or
;;; stack-relative addressing modes.
;;;

.section globals
MATHR       .fill 8     ; 64-bit accumulator: product high / remainder
.send

;
; Multiply two 32-bit integers (software shift-add, 32x32 -> 64)
;
; INPUTS:
;   ARGUMENT1 = 32-bit integer
;   ARGUMENT2 = 32-bit integer
;
; Outputs:
;   ARGUMENT1 := ARGUMENT1 * ARGUMENT2
;   Throws ERR_OVERFLOW if the product does not fit in 32 bits.
;
OP_INT_MUL  .proc
            PHP
            TRACE "OP_INT_MUL"

locals      .virtual 1,S
L_SIGN      .word ?
            .endv
            SALLOC SIZE(locals)

            setaxl

            LDA #0                  ; Start by assuming positive numbers
            STA L_SIGN

            LDA ARGUMENT1+2         ; Ensure ARGUMENT1 is positive
            BPL chk_sign2

            LDA #$8000              ; Record that ARGUMENT1 is negative
            STA L_SIGN

            LDA ARGUMENT1+2         ; Take the two's complement of ARGUMENT1
            EOR #$FFFF
            STA ARGUMENT1+2
            LDA ARGUMENT1
            EOR #$FFFF
            INC A
            STA ARGUMENT1
            BNE chk_sign2
            INC ARGUMENT1+2

chk_sign2   LDA ARGUMENT2+2         ; Ensure ARGUMENT2 is positive
            BPL do_mult

            LDA L_SIGN              ; Flip the sign
            EOR #$8000
            STA L_SIGN

            LDA ARGUMENT2+2         ; Take the two's complement of ARGUMENT2
            EOR #$FFFF
            STA ARGUMENT2+2
            LDA ARGUMENT2
            EOR #$FFFF
            INC A
            STA ARGUMENT2
            BNE do_mult
            INC ARGUMENT2+2

do_mult     ; MATHR+4 (high 32) : ARGUMENT1 (low 32, after the loop)
            ; Classic shift-add: consume multiplier bits from the bottom
            ; of ARGUMENT1 while the product rotates in from the top.

            LDA #0
            STA MATHR+4
            STA MATHR+6

            LDY #32
mul_loop    LSR ARGUMENT1+2         ; Multiplier bit -> C
            ROR ARGUMENT1
            BCC mul_shift           ; Bit clear: no add (C = 0 for the ROR chain)

            CLC                     ; Bit set: add the multiplicand to the high half
            LDA MATHR+4
            ADC ARGUMENT2
            STA MATHR+4
            LDA MATHR+6
            ADC ARGUMENT2+2
            STA MATHR+6             ; Carry out feeds the ROR chain (bit 64)

mul_shift   ROR MATHR+6             ; Rotate the 64-bit product right one bit
            ROR MATHR+4
            ROR MATHR+2
            ROR MATHR
            DEY
            BNE mul_loop

            LDA MATHR+4             ; Product high 32 bits must be zero
            ORA MATHR+6
            BEQ no_overflow

            THROW ERR_OVERFLOW

no_overflow setaxl
            LDA L_SIGN              ; Check the sign
            BPL ret_result          ; If positive: just return the result

            LDA MATHR+2             ; Compute the two's complement of the result
            EOR #$FFFF
            STA MATHR+2
            LDA MATHR
            EOR #$FFFF
            INC A
            STA MATHR
            BNE ret_result
            INC MATHR+2

ret_result  LDA MATHR               ; Return the product
            STA ARGUMENT1
            LDA MATHR+2
            STA ARGUMENT1+2

            SFREE SIZE(locals)
            PLP
            RETURN
            .pend

;
; Unsigned 32-bit division (restoring long division)
;
; INPUTS:
;   ARGUMENT1 = 32-bit dividend
;   ARGUMENT2 = 32-bit divisor (must be nonzero)
;
; Outputs:
;   ARGUMENT1 := quotient
;   ARGUMENT2 := remainder
;
UDIV32      .proc
            PHP
            setaxl

            LDA #0                  ; Clear the remainder
            STA MATHR
            STA MATHR+2

            LDY #32
div_loop    ASL ARGUMENT1           ; Shift the dividend left into the remainder;
            ROL ARGUMENT1+2         ; the vacated bit 0 receives the quotient bit
            ROL MATHR
            ROL MATHR+2
            BCS div_sub             ; 33rd bit set: definitely >= divisor

            LDA MATHR+2             ; Compare remainder to divisor
            CMP ARGUMENT2+2
            BCC div_next            ; Remainder < divisor: quotient bit stays 0
            BNE div_sub
            LDA MATHR
            CMP ARGUMENT2
            BCC div_next

div_sub     SEC                     ; Remainder -= divisor
            LDA MATHR
            SBC ARGUMENT2
            STA MATHR
            LDA MATHR+2
            SBC ARGUMENT2+2
            STA MATHR+2

            LDA ARGUMENT1           ; Set the quotient bit
            ORA #1
            STA ARGUMENT1

div_next    DEY
            BNE div_loop

            LDA MATHR               ; Return the remainder in ARGUMENT2
            STA ARGUMENT2
            LDA MATHR+2
            STA ARGUMENT2+2

            PLP
            RETURN
            .pend

;
; Divide the unsigned 16-bit integer in A by the value in X
; (drop-in for the C256 math-coprocessor version in math_cop.s)
;
; Inputs:
;   A = the numerator
;   X = the divisor
;
; Outputs:
;   A = the quotient
;   X = the remainder
;
UINT_DIV_A_X .proc
            PHP
            setal
            PHY

            STA MATHR               ; Dividend (becomes the quotient)
            TXA
            STA MATHR+2             ; Divisor
            LDA #0
            STA MATHR+4             ; Remainder

            LDY #16
loop        ASL MATHR               ; Shift dividend into the remainder
            ROL MATHR+4
            BCS sub                 ; 17th bit set: definitely >= divisor

            LDA MATHR+4
            CMP MATHR+2
            BCC next

sub         SEC
            LDA MATHR+4
            SBC MATHR+2
            STA MATHR+4

            LDA MATHR               ; Set the quotient bit
            ORA #1
            STA MATHR

next        DEY
            BNE loop

            LDA MATHR+4             ; X = the remainder
            TAX
            LDA MATHR               ; A = the quotient

            PLY
            PLP
            RETURN
            .pend

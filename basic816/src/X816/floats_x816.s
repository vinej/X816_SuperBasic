;;;
;;; Software floating point for the X816 (phase 2)
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; IEEE-754 single format, matching the header of floats.s:
;;; 1 sign bit, 8 exponent bits (bias 127), 23 mantissa bits with an
;;; implicit leading 1. The C256 build drives a memory-mapped FP
;;; coprocessor for these operations; this is the all-software
;;; replacement. Results truncate (no rounding), denormals flush to
;;; zero, overflow throws ERR_OVERFLOW, division by zero ERR_DIV0.
;;;
;;; Unpacked form (direct page): sign as $8000/$0000 in FP_Sn (so the
;;; product sign is a plain EOR and packing a plain ORA), exponent as a
;;; word in FP_En, 24-bit mantissa with the implicit 1 made explicit in
;;; FP_Mn (bits 23-16 in the second word's low byte).
;;;

; Unpacked-float scratch sits next to MATHR in bank-0 application
; space (the direct page is full; absolute addressing with DBR = $00
; reaches these from anywhere, including ASL/ROL/ROR).
FP_S1 = $004B08         ; word: sign of ARGUMENT1 ($8000 = negative)
FP_S2 = $004B0A         ; word: sign of ARGUMENT2
FP_E1 = $004B0C         ; word: exponent of ARGUMENT1
FP_E2 = $004B0E         ; word: exponent of ARGUMENT2
FP_M1 = $004B10         ; dword: 24-bit mantissa of ARGUMENT1 (implicit 1 explicit)
FP_M2 = $004B14         ; dword: 24-bit mantissa of ARGUMENT2
FP_T  = $004B18         ; word: swap temporary (see SWAPW)

;
; Register discipline for the OP_FP_* primitives: X and Y must come back
; untouched, and ARGUMENT2 must survive (see OP_FP_SUB).
;
; On the C256 these are pokes at the FP coprocessor, so they clobber no
; index register and the portable core is built on that. The software
; versions here need loop counters and a swap temporary, so they have to
; put things back. PARSENUM is the routine that proves it: it counts the
; digits of a literal in Y, calls PACKFLOAT (which multiplies), and then
; advances BIP by Y -- a clobbered Y walks the interpreter off into the
; middle of the program text.
;
; SWAPW exchanges two words through memory, so that the operand swap in
; OP_FP_ADD costs no register at all.
;
SWAPW       .macro  ; addr1,addr2
            LDA \1
            STA FP_T
            LDA \2
            STA \1
            LDA FP_T
            STA \2
            .endm

;
; Unpack ARGUMENT1 and ARGUMENT2 into sign/exponent/mantissa.
; Callers have already dealt with zero operands (an exponent field of 0
; is treated as zero everywhere, flushing denormals).
;
; Assumes 16-bit A/X (setal).
;
FPUNPACK    .proc
            LDA ARGUMENT1+2         ; Sign 1
            AND #$8000
            STA FP_S1
            LDA ARGUMENT1+2         ; Exponent 1: bits 14-7
            AND #$7F80
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            STA FP_E1
            LDA ARGUMENT1+2         ; Mantissa 1 high, implicit 1 explicit
            AND #$007F
            ORA #$0080
            STA FP_M1+2
            LDA ARGUMENT1
            STA FP_M1

            LDA ARGUMENT2+2         ; Sign 2
            AND #$8000
            STA FP_S2
            LDA ARGUMENT2+2         ; Exponent 2
            AND #$7F80
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            LSR A
            STA FP_E2
            LDA ARGUMENT2+2         ; Mantissa 2
            AND #$007F
            ORA #$0080
            STA FP_M2+2
            LDA ARGUMENT2
            STA FP_M2
            RTS
            .pend

;
; Pack FP_S1/FP_E1/FP_M1 into ARGUMENT1 as a float.
; FP_M1 must be normalized (bit 23 set) unless the value is zero.
; Underflow (exponent <= 0) flushes to zero; overflow (>= 255) throws.
;
; Assumes 16-bit A/X (setal).
;
FPPACK1     .proc
            LDA FP_E1
            BMI FPZERO1             ; Exponent went negative: underflow
            BEQ FPZERO1             ; Exponent 0: flush to zero
            CMP #$00FF
            BLT pack_ok

            THROW ERR_OVERFLOW

pack_ok     .al                     ; (THROW leaves the assembler in .as)
            ASL A                   ; Exponent to bits 14-7
            ASL A
            ASL A
            ASL A
            ASL A
            ASL A
            ASL A
            PHA
            LDA FP_M1+2             ; Mantissa bits 22-16
            AND #$007F
            ORA 1,S                 ; Merge the exponent
            ORA FP_S1               ; Merge the sign
            STA ARGUMENT1+2
            PLA
            LDA FP_M1
            STA ARGUMENT1

            setas
            LDA #TYPE_FLOAT
            STA ARGTYPE1
            setal
            RTS
            .pend

;
; ARGUMENT1 := 0.0 (float)
;
FPZERO1     .proc
            setal
            STZ ARGUMENT1
            STZ ARGUMENT1+2
            setas
            LDA #TYPE_FLOAT
            STA ARGTYPE1
            setal
            RTS
            .pend

;
; Add two floating point numbers
;
; Inputs:
;   ARGUMENT1, ARGUMENT2 = floats
;
; Outputs:
;   ARGUMENT1 := ARGUMENT1 + ARGUMENT2
;
OP_FP_ADD   .proc
            PHP
            TRACE "OP_FP_ADD"
            setaxl

            LDA ARGUMENT2+2         ; ARGUMENT2 == 0: result is ARGUMENT1
            AND #$7F80
            BNE chk_arg1

            setas                   ; (make sure the type is float)
            LDA #TYPE_FLOAT
            STA ARGTYPE1
            PLP
            RETURN

chk_arg1    .al                     ; (the early-return path above is .as)
            LDA ARGUMENT1+2         ; ARGUMENT1 == 0: result is ARGUMENT2
            AND #$7F80
            BNE do_add

            LDA ARGUMENT2
            STA ARGUMENT1
            LDA ARGUMENT2+2
            STA ARGUMENT1+2
            setas
            LDA #TYPE_FLOAT
            STA ARGTYPE1
            PLP
            RETURN

do_add      .al                     ; (the early-return path above is .as)
            CALL FPUNPACK

            LDA FP_E1               ; Ensure operand 1 has the larger exponent
            CMP FP_E2
            BGE no_swap

            SWAPW       FP_S1,FP_S2 ; Swap the unpacked operands
            SWAPW       FP_E1,FP_E2
            SWAPW       FP_M1,FP_M2
            SWAPW       FP_M1+2,FP_M2+2

no_swap     SEC                     ; How far apart are the exponents?
            LDA FP_E1
            SBC FP_E2
            BEQ aligned
            CMP #25
            BLT align_loop

            CALL FPPACK1            ; Too far apart: the larger operand wins
            PLP
            RETURN

align_loop  LSR FP_M2+2             ; Shift the smaller mantissa down
            ROR FP_M2
            DEC A
            BNE align_loop

aligned     LDA FP_S1               ; Same sign: add the mantissas
            CMP FP_S2
            BNE sub_mag

            CLC
            LDA FP_M1
            ADC FP_M2
            STA FP_M1
            LDA FP_M1+2
            ADC FP_M2+2
            STA FP_M1+2

            BIT #$0100              ; Carry into bit 24?
            BEQ add_done
            LSR FP_M1+2             ; Renormalize down one
            ROR FP_M1
            INC FP_E1

add_done    CALL FPPACK1
            PLP
            RETURN

sub_mag     ; Different signs: subtract the smaller magnitude
            LDA FP_M1+2
            CMP FP_M2+2
            BNE mag_known
            LDA FP_M1
            CMP FP_M2
mag_known   BCC m2_bigger

            SEC                     ; FP_M1 >= FP_M2: M1 -= M2, sign stays
            LDA FP_M1
            SBC FP_M2
            STA FP_M1
            LDA FP_M1+2
            SBC FP_M2+2
            STA FP_M1+2
            BRA norm

m2_bigger   SEC                     ; FP_M2 > FP_M1: M1 = M2 - M1, take sign 2
            LDA FP_M2
            SBC FP_M1
            STA FP_M1
            LDA FP_M2+2
            SBC FP_M1+2
            STA FP_M1+2
            LDA FP_S2
            STA FP_S1

norm        LDA FP_M1               ; Complete cancellation: exact zero
            ORA FP_M1+2
            BNE norm_loop

            CALL FPZERO1
            PLP
            RETURN

norm_loop   LDA FP_M1+2             ; Normalize: shift up until bit 23 is set
            BIT #$0080
            BNE norm_done
            ASL FP_M1
            ROL FP_M1+2
            DEC FP_E1
            BRA norm_loop

norm_done   CALL FPPACK1
            PLP
            RETURN
            .pend

;
; Subtract two floating point numbers
;
; Outputs:
;   ARGUMENT1 := ARGUMENT1 - ARGUMENT2
;   ARGUMENT2 is preserved.
;
; Subtraction is an add with the sign of ARGUMENT2 flipped, but the flip
; has to be undone before returning: on the C256 these primitives drive
; the coprocessor and never write back to ARGUMENT2, and the portable
; core relies on that. FP_COMPARE (floats.s) saves and restores only
; ARGUMENT1 across its OP_FP_SUB, so a lingering sign flip silently
; corrupts the caller's second operand -- which is what made FTOS's
; normalize loop exit after one step and print 2.5 as "2.5E04".
;
OP_FP_SUB   .proc
            PHP
            TRACE "OP_FP_SUB"
            setaxl

            LDA ARGUMENT2+2         ; Negate ARGUMENT2 (unless it is zero)
            AND #$7F80
            BEQ no_negate
            LDA ARGUMENT2+2
            EOR #$8000
            STA ARGUMENT2+2
            CALL OP_FP_ADD
            LDA ARGUMENT2+2         ; Flip it back
            EOR #$8000
            STA ARGUMENT2+2
            PLP
            RETURN

no_negate   CALL OP_FP_ADD          ; ARGUMENT2 was zero: nothing to undo

            PLP
            RETURN
            .pend

;
; Multiply two floating point numbers
;
; Outputs:
;   ARGUMENT1 := ARGUMENT1 * ARGUMENT2
;
OP_FP_MUL   .proc
            PHP
            TRACE "OP_FP_MUL"
            setaxl
            PHX                     ; The shift-add loop below needs both
            PHY                     ;  index registers; callers keep theirs

            LDA ARGUMENT1+2         ; Either operand zero: result is zero
            AND #$7F80
            BEQ ret_zero
            LDA ARGUMENT2+2
            AND #$7F80
            BNE do_mul

ret_zero    CALL FPZERO1
            PLY
            PLX
            PLP
            RETURN

do_mul      .al                     ; (the early-return path above is .as)
            CALL FPUNPACK

            LDA FP_S1               ; Result sign and exponent
            EOR FP_S2
            STA FP_S1
            CLC
            LDA FP_E1
            ADC FP_E2
            SEC
            SBC #127
            STA FP_E1

            ; 24x24 -> 48-bit mantissa product (shift-add, as in
            ; OP_INT_MUL): high half accumulates in MATHR+4/+6 and the
            ; whole 64-bit accumulator rotates right each step.
            LDA #0
            STA MATHR+4
            STA MATHR+6

            LDY #32
mul_loop    LSR FP_M1+2
            ROR FP_M1
            BCC mul_shift

            CLC
            LDA MATHR+4
            ADC FP_M2
            STA MATHR+4
            LDA MATHR+6
            ADC FP_M2+2
            STA MATHR+6

mul_shift   ROR MATHR+6
            ROR MATHR+4
            ROR MATHR+2
            ROR MATHR
            DEY
            BNE mul_loop

            ; Product of two [1,2) mantissas is [1,4): bit 47 chooses
            ; whether the binary point shift is 24 (and E++) or 23.
            LDX #23
            LDA MATHR+4
            BIT #$8000
            BEQ shift_down
            LDX #24
            INC FP_E1

shift_down  LSR MATHR+6             ; Bring the top 24 bits down to 23-0
            ROR MATHR+4
            ROR MATHR+2
            ROR MATHR
            DEX
            BNE shift_down

            LDA MATHR
            STA FP_M1
            LDA MATHR+2
            STA FP_M1+2

            CALL FPPACK1
            PLY
            PLX
            PLP
            RETURN
            .pend

;
; Divide two floating point numbers
;
; Outputs:
;   ARGUMENT1 := ARGUMENT1 / ARGUMENT2
;   Throws ERR_DIV0 if ARGUMENT2 is zero.
;
OP_FP_DIV   .proc
            PHP
            TRACE "OP_FP_DIV"
            setaxl
            PHX                     ; The long division below needs both
            PHY                     ;  index registers; callers keep theirs

            LDA ARGUMENT2+2         ; Divisor zero: error
            AND #$7F80
            BNE chk_num

            THROW ERR_DIV0

chk_num     .al                     ; (THROW leaves the assembler in .as)
            LDA ARGUMENT1+2         ; Dividend zero: result is zero
            AND #$7F80
            BNE do_div

            CALL FPZERO1
            PLY
            PLX
            PLP
            RETURN

do_div      .al                     ; (the early-return path above is .as)
            CALL FPUNPACK

            LDA FP_S1               ; Result sign
            EOR FP_S2
            STA FP_S1

            ; q = floor(M1 * 2^24 / M2), restoring long division over
            ; the 48-bit dividend M1 << 24. M1 is left-aligned in its
            ; dword (<< 8) so 48 shifts stream its 24 bits then zeros.
            ; q < 2^25: quotient in MATHR+4/+6, remainder in MATHR.
            LDX #8
align       ASL FP_M1
            ROL FP_M1+2
            DEX
            BNE align

            LDA #0
            STA MATHR
            STA MATHR+2
            STA MATHR+4
            STA MATHR+6

            LDY #48
div_loop    ASL FP_M1               ; Next dividend bit into the remainder
            ROL FP_M1+2
            ROL MATHR
            ROL MATHR+2
            ASL MATHR+4             ; Quotient slides up
            ROL MATHR+6

            LDA MATHR+2             ; remainder >= divisor?
            CMP FP_M2+2
            BCC div_next
            BNE div_sub
            LDA MATHR
            CMP FP_M2
            BCC div_next

div_sub     SEC
            LDA MATHR
            SBC FP_M2
            STA MATHR
            LDA MATHR+2
            SBC FP_M2+2
            STA MATHR+2

            LDA MATHR+4
            ORA #1
            STA MATHR+4

div_next    DEY
            BNE div_loop

            ; Exponent: quotient is [0.5,2) * 2^24. Bit 24 set means
            ; the ratio was >= 1.
            SEC
            LDA FP_E1
            SBC FP_E2
            STA FP_E1

            LDA MATHR+6
            CMP #$0100              ; q >= 2^24?
            BLT ratio_lt1

            LSR MATHR+6             ; Keep 24 bits
            ROR MATHR+4
            CLC
            LDA FP_E1
            ADC #127
            STA FP_E1
            BRA store_m

ratio_lt1   CLC
            LDA FP_E1
            ADC #126
            STA FP_E1

store_m     LDA MATHR+4
            STA FP_M1
            LDA MATHR+6
            STA FP_M1+2

            CALL FPPACK1
            PLY
            PLX
            PLP
            RETURN
            .pend

;
; Convert the float in ARGUMENT1 to an integer.
;
; On the C256 this drives the coprocessor's fixed-point converter, but
; floats.s documents that converter as broken ("B%=A will not be equal
; to 1234") and comments the call out, so production on every platform
; goes through the portable software FTOI. There is no converter to
; drive here, so point the name at the routine BASIC816 actually
; trusts. Only tests/floattests.s calls it.
;
FP_TO_FIXINT .proc
            CALL FTOI
            RETURN
            .pend

;
; Multiply / divide ARGUMENT1 by 10.0, preserving ARGUMENT2
;
FP_MUL10    .proc
            PHP
            setaxl
            PHX
            LDA ARGUMENT2           ; Save ARGUMENT2
            PHA
            LDA ARGUMENT2+2
            PHA

            LDA #$0000              ; ARGUMENT2 = 10.0
            STA ARGUMENT2
            LDA #$4120
            STA ARGUMENT2+2
            CALL OP_FP_MUL

            PLA                     ; Restore ARGUMENT2
            STA ARGUMENT2+2
            PLA
            STA ARGUMENT2
            PLX
            PLP
            RETURN
            .pend

FP_DIV10    .proc
            PHP
            setaxl
            PHX
            LDA ARGUMENT2           ; Save ARGUMENT2
            PHA
            LDA ARGUMENT2+2
            PHA

            LDA #$0000              ; ARGUMENT2 = 10.0
            STA ARGUMENT2
            LDA #$4120
            STA ARGUMENT2+2
            CALL OP_FP_DIV

            PLA                     ; Restore ARGUMENT2
            STA ARGUMENT2+2
            PLA
            STA ARGUMENT2
            PLX
            PLP
            RETURN
            .pend

;
; Calculate the floating point 10^x (software version of the C256
; coprocessor loop in floats.s)
;
; Inputs:
;   MARG4 = the power to raise (or lower!) 10.0 [0..127]
;   MARG6 = whether or not the exponent should be negative
;
; Outputs:
;   ARGUMENT1 = 10.0 ^ MARG4
;   ARGUMENT2 is preserved.
;
; PACKFLOAT parks the parsed mantissa in ARGUMENT2 across this call and
; multiplies by it on return, so ARGUMENT2 must survive -- on the C256
; it does for free, because that FP_POW10 drives the coprocessor. The
; loop below needs ARGUMENT2 as its scratch operand, so save and restore
; it. (Without this, "1.25E+3" parsed as 1000 * 10 = 10000.)
;
FP_POW10    .proc
            PHP
            setaxl
            PHX
            LDA ARGUMENT2           ; Save ARGUMENT2
            PHA
            LDA ARGUMENT2+2
            PHA

            LDA #$0000              ; ARGUMENT1 = 1.0
            STA ARGUMENT1
            LDA #$3F80
            STA ARGUMENT1+2
            setas
            LDA #TYPE_FLOAT
            STA ARGTYPE1
            setal

            LDA MARG4
            AND #$00FF
            BEQ done                ; 10^0 = 1.0
            TAX

pow_loop    PHX
            LDA #$0000              ; ARGUMENT2 = 10.0
            STA ARGUMENT2
            LDA #$4120
            STA ARGUMENT2+2

            setas
            LDA MARG6               ; Negative power: divide, else multiply
            setal
            AND #$00FF
            BNE pow_div
            CALL OP_FP_MUL
            BRA pow_next
pow_div     CALL OP_FP_DIV

pow_next    PLX
            DEX
            BNE pow_loop

done        PLA                     ; Restore ARGUMENT2
            STA ARGUMENT2+2
            PLA
            STA ARGUMENT2
            PLX
            PLP
            RETURN
            .pend

;
; Raise the float in ARGUMENT1 to a non-negative integer power
; (replacement for the C256 Q_FP_POW_INT; used by ^)
;
; Inputs:
;   ARGUMENT1 = float base
;   X = integer exponent (>= 0)
;
; Outputs:
;   ARGUMENT1 := ARGUMENT1 ^ X
;
Q_FP_POW_INT .proc
            PHP
            setaxl

            CPX #0                  ; x^0 = 1.0
            BNE save_base

            LDA #$0000
            STA ARGUMENT1
            LDA #$3F80
            STA ARGUMENT1+2
            setas
            LDA #TYPE_FLOAT
            STA ARGTYPE1
            setal
            PLP
            RETURN

save_base   LDA ARGUMENT1           ; Keep the base on the stack
            PHA
            LDA ARGUMENT1+2
            PHA

pow_loop    DEX                     ; base^1 already in ARGUMENT1
            BEQ pow_done

            PHX
            LDA 3,S                 ; ARGUMENT2 = the saved base
            STA ARGUMENT2+2
            LDA 5,S
            STA ARGUMENT2
            CALL OP_FP_MUL
            PLX
            BRA pow_loop

pow_done    PLA                     ; Drop the saved base
            PLA
            PLP
            RETURN
            .pend

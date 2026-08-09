
;;;
;;; Fast game maths: no floats anywhere
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; SIN and COS proper exist (HELP MATH) and are the wrong tool for
;;; anything that moves on a screen: a floating-point sine per sprite
;;; per frame is not affordable at this speed. These are the integer
;;; answers -- a table lookup, a shift, a comparison -- and between them
;;; they are most of what a game does with a number.
;;;
;;; THE ANGLE IS 0-255 AND WRAPS, which is the point of it: a byte IS an
;;; angle, adding turns, and there is no range reduction to do because
;;; 256 units is one turn and the arithmetic wraps for free.
;;;
;;; The convention: 0 is EAST and the angle increases the way it does ON
;;; A SCREEN, where y grows downwards -- so 64 is south, 128 west, 192
;;; north. That is chosen so a step of (COS8(a), SIN8(a)) actually moves
;;; in direction a, and so ATAN2 answers the question SIN8 and COS8 will
;;; be asked next. A convention that disagreed with itself here would be
;;; found by a sprite chasing the player backwards.
;;;
;;; Everything here is INTEGER. A float argument is converted rather
;;; than refused, so LERP(0,100,128) and LERP(0.0,100.0,128) agree.
;;;

;
; sin(a) * 127, for a = 0-255. 256 signed bytes, because the table IS
; the algorithm: a quarter-table with reflection would cost more code
; than the 192 bytes it saved.
;
adv_sintab
                .char    0,    3,    6,    9,   12,   16,   19,   22
                .char   25,   28,   31,   34,   37,   40,   43,   46
                .char   49,   51,   54,   57,   60,   63,   65,   68
                .char   71,   73,   76,   78,   81,   83,   85,   88
                .char   90,   92,   94,   96,   98,  100,  102,  104
                .char  106,  107,  109,  111,  112,  113,  115,  116
                .char  117,  118,  120,  121,  122,  122,  123,  124
                .char  125,  125,  126,  126,  126,  127,  127,  127
                .char  127,  127,  127,  127,  126,  126,  126,  125
                .char  125,  124,  123,  122,  122,  121,  120,  118
                .char  117,  116,  115,  113,  112,  111,  109,  107
                .char  106,  104,  102,  100,   98,   96,   94,   92
                .char   90,   88,   85,   83,   81,   78,   76,   73
                .char   71,   68,   65,   63,   60,   57,   54,   51
                .char   49,   46,   43,   40,   37,   34,   31,   28
                .char   25,   22,   19,   16,   12,    9,    6,    3
                .char    0,   -3,   -6,   -9,  -12,  -16,  -19,  -22
                .char  -25,  -28,  -31,  -34,  -37,  -40,  -43,  -46
                .char  -49,  -51,  -54,  -57,  -60,  -63,  -65,  -68
                .char  -71,  -73,  -76,  -78,  -81,  -83,  -85,  -88
                .char  -90,  -92,  -94,  -96,  -98, -100, -102, -104
                .char -106, -107, -109, -111, -112, -113, -115, -116
                .char -117, -118, -120, -121, -122, -122, -123, -124
                .char -125, -125, -126, -126, -126, -127, -127, -127
                .char -127, -127, -127, -127, -126, -126, -126, -125
                .char -125, -124, -123, -122, -122, -121, -120, -118
                .char -117, -116, -115, -113, -112, -111, -109, -107
                .char -106, -104, -102, -100,  -98,  -96,  -94,  -92
                .char  -90,  -88,  -85,  -83,  -81,  -78,  -76,  -73
                .char  -71,  -68,  -65,  -63,  -60,  -57,  -54,  -51
                .char  -49,  -46,  -43,  -40,  -37,  -34,  -31,  -28
                .char  -25,  -22,  -19,  -16,  -12,   -9,   -6,   -3

;
; atan(i/32), for i = 0-32, scaled so 45 degrees is 32 -- an eighth of
; the 256-unit turn. 33 entries and not 32, because the ratio reaches 1
; exactly when |dy| equals |dx|.
;
adv_atantab
                .byte   0,   1,   3,   4,   5,   6,   8,   9,  10,  11,  12
                .byte  13,  15,  16,  17,  18,  19,  20,  21,  22,  23,  24
                .byte  25,  25,  26,  27,  28,  29,  29,  30,  31,  31,  32

;
; Sign-extend the signed byte in A (8-bit) into ARGUMENT1 as an integer.
;
ADV_PUTB        .proc
                PHP
                setal
                AND #$00FF
                CMP #$0080                  ; a signed byte widened by hand:
                BCC ap_pos                  ;  this processor has no
                                            ;  sign-extending load
                ORA #$FF00                  ; negative: set the high word too
                STA ARGUMENT1
                LDA #$FFFF
                BRA ap_hi

                ; The store comes BEFORE the sign is decided, and the
                ; sign is decided from the CARRY the CMP left -- not
                ; from the value, because STA sets no flags at all. An
                ; earlier draft tested BPL after the STA and read the
                ; CMP's N instead, which is set for every value below
                ; $80: SIN8(0) answered -65536.
ap_pos          STA ARGUMENT1
                LDA #0
ap_hi           STA ARGUMENT1+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                PLP
                RETURN
                .pend

;
; SIN8(a) -- sin(a) * 127, a = 0-255 and wrapping.
;
FN_SIN8         .proc
                FN_START "FN_SIN8"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                setaxl
                LDA ARGUMENT1
                AND #$00FF
                TAX
                setas
                LDA @l adv_sintab,X
                CALL ADV_PUTB

                FN_END
                PLP
                RETURN
                .pend

;
; COS8(a) -- the same table a quarter turn along, because cos(a) is
; sin(a + 90) and 90 degrees is 64 of these units.
;
FN_COS8         .proc
                FN_START "FN_COS8"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                setaxl
                LDA ARGUMENT1
                CLC
                ADC #64
                AND #$00FF
                TAX
                setas
                LDA @l adv_sintab,X
                CALL ADV_PUTB

                FN_END
                PLP
                RETURN
                .pend

;
; ATAN2(dx,dy) -- the direction from one point to another, 0-255.
;
; The octant decomposition every atan2 uses: the table covers the first
; 45 degrees and the seven other eighths of the circle are that answer
; reflected, which is why it is 33 entries and not 256.
;
; ATAN2(0,0) is 0. There is no direction to give and every other answer
; would be a lie; a caller that cares should test the distance first.
;
FN_ATAN2        .proc
                FN_START "FN_ATAN2"
                PHP
                setaxl

                CALL EVALEXPR               ; dx
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l ADV_DX

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; dy
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l ADV_DY

                LDA @l ADV_DX               ; |dx| and |dy|
                BPL at_axok
                EOR #$FFFF
                INC A
at_axok         STA @l ADV_AX
                LDA @l ADV_DY
                BPL at_ayok
                EOR #$FFFF
                INC A
at_ayok         STA @l ADV_AY

                LDA @l ADV_AX               ; both zero: no direction
                ORA @l ADV_AY
                BNE at_have
                LDA #0
                STA @l ADV_T
                BRL at_sign

at_have         LDA @l ADV_AX               ; ratio = smaller*32 / larger
                CMP @l ADV_AY
                BCC at_steep

                LDA @l ADV_AY               ; shallow: dy over dx
                STA @l ADV_NUM
                LDA @l ADV_AX
                STA @l ADV_DEN
                LDA #0
                STA @l ADV_FLIP
                BRA at_div

at_steep        LDA @l ADV_AX               ; steep: dx over dy, and the
                STA @l ADV_NUM              ;  answer is 64 less the table's
                LDA @l ADV_AY
                STA @l ADV_DEN
                LDA #1
                STA @l ADV_FLIP

at_div          LDA @l ADV_NUM              ; numerator * 32, in 32 bits
                STA ARGUMENT1
                LDA #0
                STA ARGUMENT1+2
                .rept 5
                ASL ARGUMENT1
                ROL ARGUMENT1+2
                .next
                LDA @l ADV_DEN
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2
                CALL UDIV32

                setaxl
                LDA ARGUMENT1
                CMP #33                     ; rounding cannot reach it, but
                BCC at_look                 ;  an index off the end of a
                LDA #32                     ;  table is not worth risking
at_look         TAX
                setas
                LDA @l adv_atantab,X
                setal
                AND #$00FF
                STA @l ADV_T

                LDA @l ADV_FLIP
                BEQ at_sign
                LDA #64                     ; the steep half, measured back
                SEC                         ;  from due south
                SBC @l ADV_T
                STA @l ADV_T

                ; The quadrant. dx < 0 reflects about the vertical and
                ; dy < 0 about the horizontal, in that order: the second
                ; reflection is of the first one's answer.
at_sign         LDA @l ADV_DX
                BPL at_dyt
                LDA #128
                SEC
                SBC @l ADV_T
                STA @l ADV_T
at_dyt          LDA @l ADV_DY
                BPL at_done
                LDA #0
                SEC
                SBC @l ADV_T
                STA @l ADV_T

at_done         LDA @l ADV_T
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
; Read an expression after a comma into ADV_B.
;
ADV_ARG2        .proc
                PHP
                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l ADV_B
                LDA ARGUMENT1+2
                STA @l ADV_B+2
                PLP
                RETURN
                .pend

;
; LERP(a,b,t) -- a fraction t/256 of the way from a to b.
;
; t = 0 is exactly a and t = 255 is one step short of b, which is what
; an eight-bit fraction means and is worth knowing before using this to
; land something exactly on b.
;
FN_LERP         .proc
                FN_START "FN_LERP"
                PHP
                setaxl

                CALL EVALEXPR               ; a
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l ADV_A
                LDA ARGUMENT1+2
                STA @l ADV_A+2

                CALL ADV_ARG2               ; b, into ADV_B

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; t
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                AND #$00FF
                STA @l ADV_T

                SEC                         ; (b - a) * t, signed, 32-bit
                LDA @l ADV_B
                SBC @l ADV_A
                STA ARGUMENT1
                LDA @l ADV_B+2
                SBC @l ADV_A+2
                STA ARGUMENT1+2
                LDA @l ADV_T
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                STA ARGTYPE2
                setal
                CALL OP_INT_MUL

                setaxl                      ; ...over 256, ARITHMETICALLY,
                LDX #8                      ;  so a downward slope stays
lp_shift        LDA ARGUMENT1+2             ;  downward
                CMP #$8000                  ; the sign bit into the carry, so
                ROR ARGUMENT1+2             ;  the shift extends it instead
                ROR ARGUMENT1               ;  of feeding in a zero
                DEX
                BNE lp_shift

                CLC
                LDA ARGUMENT1
                ADC @l ADV_A
                STA ARGUMENT1
                LDA ARGUMENT1+2
                ADC @l ADV_A+2
                STA ARGUMENT1+2

                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

;
; Compare ARGUMENT1 with ARGUMENT2 as SIGNED 32-bit values.
;
; Carry SET when ARGUMENT1 >= ARGUMENT2. The EOR after the overflow test
; is what makes it signed: without it -1 compares as greater than 1 and
; MIN quietly answers the maximum.
;
; NO PHP. The answer is in the CARRY, and a PLP would put the caller's
; carry back over it -- the mistake that cost an afternoon in
; X816/input_x816.s, where it made every I2C transfer look acknowledged,
; and that cost this file MIN and MAX answering each other's questions.
;
; Callers are all in 16-bit A, and the setal below makes sure of it.
;
ADV_CMP         .proc
                setal
                SEC
                LDA ARGUMENT1
                SBC ARGUMENT2
                LDA ARGUMENT1+2
                SBC ARGUMENT2+2
                BVC ac_novf
                EOR #$8000
ac_novf         ASL A                       ; the corrected sign bit into the
                                            ;  carry: SET means ARGUMENT1 is
                                            ;  the SMALLER of the two
                RETURN
                .pend

;
; ARGUMENT1 := ADV_A, ARGUMENT2 := ADV_B, ready for ADV_CMP.
;
ADV_LOADAB      .proc
                PHP
                setal
                LDA @l ADV_A
                STA ARGUMENT1
                LDA @l ADV_A+2
                STA ARGUMENT1+2
                LDA @l ADV_B
                STA ARGUMENT2
                LDA @l ADV_B+2
                STA ARGUMENT2+2
                PLP
                RETURN
                .pend

;
; Copy ARGUMENT2 over ARGUMENT1.
;
ADV_TAKE2       .proc
                PHP
                setal
                LDA ARGUMENT2
                STA ARGUMENT1
                LDA ARGUMENT2+2
                STA ARGUMENT1+2
                PLP
                RETURN
                .pend

;
; MIN(a,b) and MAX(a,b), signed.
;
FN_MIN          .proc
                FN_START "FN_MIN"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l ADV_A
                LDA ARGUMENT1+2
                STA @l ADV_A+2

                CALL ADV_ARG2
                CALL ADV_LOADAB
                CALL ADV_CMP
                BCS mn_done                 ; a < b: a is already the answer
                CALL ADV_TAKE2              ; otherwise b is
mn_done         setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

FN_MAX          .proc
                FN_START "FN_MAX"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l ADV_A
                LDA ARGUMENT1+2
                STA @l ADV_A+2

                CALL ADV_ARG2
                CALL ADV_LOADAB
                CALL ADV_CMP
                BCC mx_done                 ; a >= b: a is the answer
                CALL ADV_TAKE2
mx_done         setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

;
; CLAMP(v,lo,hi) -- v held inside [lo,hi].
;
; lo and hi are applied in that order and are NOT checked against each
; other, so CLAMP(v,10,0) answers 0 for every v. That is arithmetic
; rather than a decision, and cheaper than the test would be.
;
FN_CLAMP        .proc
                FN_START "FN_CLAMP"
                PHP
                setaxl

                CALL EVALEXPR               ; v
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l ADV_A
                LDA ARGUMENT1+2
                STA @l ADV_A+2

                CALL ADV_ARG2               ; lo
                CALL ADV_LOADAB
                CALL ADV_CMP
                BCC cl_hi                   ; v >= lo: leave it
                CALL ADV_TAKE2
                setal
                LDA ARGUMENT1
                STA @l ADV_A
                LDA ARGUMENT1+2
                STA @l ADV_A+2

cl_hi           CALL ADV_ARG2               ; hi
                CALL ADV_LOADAB
                CALL ADV_CMP
                BCS cl_done                 ; v < hi: leave it
                CALL ADV_TAKE2
cl_done         setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

;
; RNDSEED n -- set the generator, so a level can be regenerated.
;
; The state is a 16-bit xorshift and zero is its fixed point: it would
; stay there forever. RNDSEED 0 is therefore taken as "pick something"
; rather than refused -- a program seeding from a score or a frame count
; should not have to know that one of the numbers is poison.
;
S_RNDSEED       .proc
                PHP
                TRACE "S_RNDSEED"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT

                setal
                LDA ARGUMENT1
                BNE rs_ok
                LDA #$2A55                  ; the constant INITIO seeds with
rs_ok           STA @l RNDSEED

                PLP
                RETURN
                .pend

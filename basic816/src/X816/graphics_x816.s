;;;
;;; Bitmap graphics on VERA2
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; There are two bitmap engines on this machine and the choice matters
;;; more than anything else on this page.
;;;
;;; VERA's own 320x240 mode puts pixels in VRAM, reached a byte at a time
;;; through a port -- and 76,800 bytes from VRAM $00000 covers the
;;; console's map and its font, so the text screen is destroyed while you
;;; draw.
;;;
;;; VERA2 is 640x480 and its framebuffer is ORDINARY CPU MEMORY at
;;; $E0:0000 (X816_core/doc/VERA2.md). So PLOT is a computed address and
;;; a store -- no port, no sequencing, nothing to leave latched -- and
;;; the console is untouched, which means text and graphics coexist and
;;; a program can still print while it draws.
;;;
;;; 8bpp only. Mode 2 in the hardware is 640x480 4bpp, and everything
;;; below assumes one byte is one pixel; GRAPHICS refuses it rather than
;;; accepting it and drawing to the wrong addresses.
;;;
;;; Pixels outside the screen are DROPPED, not refused. Clipping is what
;;; a drawing statement is expected to do -- a LINE that runs off the
;;; edge should draw the part that fits, not stop the program.
;;;

VERA2_CTRL      = $9F60     ; enable 0, mode 2:1, passthru 3
VERA2_ID        = $9F61     ; $B5 when the layer exists and is switched on
VERA2_DISPL     = $9F62     ; display base, byte offset, bit 0 reads back 0
VERA2_DISPM     = $9F63
VERA2_DISPH     = $9F64
VERA2_PALADR    = $9F66     ; auto-increments after PALHI
VERA2_PALLO     = $9F67     ; {G,B}, latched
VERA2_PALHI     = $9F68     ; {-,R}, commits the entry

VFB_BASE        = $E00000   ; the framebuffer, one megabyte, always reserved
VFB_WIDTH       = 640
VFB_HEIGHT      = 480

; Not one byte of direct page is used here, and that is deliberate: the
; page is a single 256 bytes and it is already full, so [ptr] addressing
; -- the obvious way to reach a computed 24-bit address -- was not
; available at any price.
;
; The way round it is the DATA BANK. A pixel address is split into a
; bank and a 16-bit offset, the bank is pushed into DBR, and the store
; is a plain absolute-indexed one. It needs no pointer anywhere, and it
; is fewer cycles than the indirect would have been.

;
; GRAPHICS mode -- 0 off, 1 on (640x480, 256 colours).
;
; passthru is switched on with the layer. It lets VERA's opaque pixels
; through on top, which is what keeps the text console readable over the
; bitmap; without it the bitmap replaces the entire display and the
; machine appears to have no console at all.
;
S_GRAPHICS      .proc
                PHP
                TRACE "S_GRAPHICS"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                AND #$00FF
                BEQ gr_off
                CMP #1
                BNE gr_bad              ; 4bpp is a real mode and this file
                                        ;  cannot draw in it, so it is refused
                                        ;  rather than half-supported
                setas
                LDA #$0B                ; passthru, mode 1, enable
                STA @l VERA2_CTRL
                PLP
                RETURN

gr_off          setas
                LDA #$00
                STA @l VERA2_CTRL
                PLP
                RETURN

gr_bad          PLP
                THROW ERR_ARGUMENT
                .pend

;
; GRAPHICSAT -- $B5 if the bitmap layer is there, 0 if it is not.
;
; Worth having as a keyword rather than a PEEK, because the answer is
; three-valued in a way a beginner will meet: the register reads $B5 when
; the layer exists AND is switched on in the OSD, and 0 otherwise. So a
; program can say "turn the bitmap layer on" instead of drawing into
; nothing and leaving the user to wonder.
;
FN_GRAPHICSAT   .proc
                PHP
                setaxl

                setas
                LDA @l VERA2_ID
                setal
                AND #$00FF
                STA ARGUMENT1
                STZ ARGUMENT1+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                PLP
                RETURN
                .pend

;
; VFB_A := the address of pixel (GX, GY). Carry set if it is off screen.
;
; y*640 needs 19 bits, and it is done without a 32-bit shift in memory.
; 640 is 5 * 128, and y*5 cannot overflow 16 bits for y below 480 -- so
; the whole multiply is two shifts and an add in the accumulator, then
; the 19-bit result is split by shifting the SAME value both ways: the
; low word is t<<7 and the high byte is t>>9.
;
GFX_ADDR        .proc
                PHP
                setaxl

                LDA @l GX               ; 0-639 and 0-479. A negative
                CMP #VFB_WIDTH          ;  coordinate has wrapped to something
                BCS ga_off              ;  very large, so one unsigned compare
                LDA @l GY               ;  rejects both ends.
                CMP #VFB_HEIGHT
                BCS ga_off

                LDA @l GY               ; t = y*5
                ASL A
                ASL A
                CLC
                ADC @l GY
                STA @l GT

                .rept 7                 ; low 16 bits of t<<7
                ASL A
                .next
                STA @l GOFF

                LDA @l GT               ; and the bits above them
                .rept 9
                LSR A
                .next
                STA @l GBANK

                CLC                     ; + x
                LDA @l GOFF
                ADC @l GX
                STA @l GOFF
                LDA @l GBANK
                ADC #0                  ; the carry out of the low word
                CLC
                ADC #`VFB_BASE          ; and that is the bank to run in
                STA @l GBANK

                PLP
                CLC
                RETURN

ga_off          PLP
                SEC
                RETURN
                .pend

;
; Put GCOL at (GX, GY), dropping it if that is off screen.
;
GFX_PSET        .proc
                PHP
                CALL GFX_ADDR
                BCS gp_done

                PHB
                setaxl
                LDA @l GOFF             ; LDX has no long addressing mode
                TAX
                setas
                LDA @l GBANK
                PHA
                PLB                     ; the framebuffer bank is now DBR
                LDA @l GCOL
                STA @w 0,X
                PLB

gp_done         PLP
                RETURN
                .pend

;
; PLOT x, y, colour
;
S_PLOT          .proc
                PHP
                TRACE "S_PLOT"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l GX

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l GY

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                STA @l GCOL

                CALL GFX_PSET

                PLP
                RETURN
                .pend

;
; POINT(x, y) -- the colour of a pixel, or -1 if it is off screen.
;
FN_POINT        .proc
                FN_START "FN_POINT"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l GX

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l GY

                CALL GFX_ADDR
                BCS pt_off

                PHB
                setaxl
                LDA @l GOFF
                TAX
                setas
                LDA @l GBANK
                PHA
                PLB
                LDA @w 0,X
                PLB
                setal
                AND #$00FF
                STA ARGUMENT1
                STZ ARGUMENT1+2
                BRA pt_type

pt_off          setal
                LDA #$FFFF
                STA ARGUMENT1
                STA ARGUMENT1+2

pt_type         setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

;
; CLRBITMAP colour -- fill the whole frame.
;
; 307,200 stores, and no address arithmetic at all: run DBR up the four
; whole banks the frame covers, filling 65,536 bytes each as X wraps
; round, then the 45,056 that are left. 4*65536 + 45056 = 307,200.
;
S_CLRBITMAP     .proc
                PHP
                TRACE "S_CLRBITMAP"
                setaxl
                PHX
                PHY

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                STA @l GCOL

                PHB
                setas
                LDA #`VFB_BASE
                PHA
                PLB

                setaxl
                LDY #4                  ; four whole banks
cb_bank         LDX #0
cb_fill         setas
                LDA @l GCOL
                STA @w 0,X
                setal
                INX
                BNE cb_fill             ; X wraps at 65,536

                PHB                     ; step DBR to the next bank
                setas
                PLA
                INC A
                PHA
                PLB
                setal
                DEY
                BNE cb_bank

                LDX #0                  ; and the remainder of the frame
cb_last         setas
                LDA @l GCOL
                STA @w 0,X
                setal
                INX
                CPX #$B000
                BCC cb_last

                PLB
                PLY
                PLX
                PLP
                RETURN
                .pend

;
; LINE x1, y1, x2, y2, colour
;
; Bresenham, in the form that needs no quadrant cases: dy is carried
; negative and the error term is compared against both deltas each step,
; so one loop draws every direction including the vertical and the
; horizontal.
;
S_LINE          .proc
                PHP
                TRACE "S_LINE"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l GX

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l GY

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l GX1

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l GY1

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                STA @l GCOL

                setal                   ; dx = |x1-x0|, sx = sign
                SEC
                LDA @l GX1
                SBC @l GX
                BPL ln_dxpos
                EOR #$FFFF              ; negate: dx is a magnitude
                INC A
                STA @l GDX
                LDA #$FFFF              ; and step left
                STA @l GSX
                BRA ln_dy
ln_dxpos        STA @l GDX
                LDA #1
                STA @l GSX

ln_dy           setal                   ; dy = -|y1-y0|, sy = sign
                SEC
                LDA @l GY1
                SBC @l GY
                BPL ln_dypos
                STA @l GDY              ; already negative, which is what the
                LDA #$FFFF              ;  algorithm wants
                STA @l GSY
                BRA ln_err
ln_dypos        EOR #$FFFF              ; make it negative
                INC A
                STA @l GDY
                LDA #1
                STA @l GSY

ln_err          setal                   ; err = dx + dy
                CLC
                LDA @l GDX
                ADC @l GDY
                STA @l GERR

ln_step         CALL GFX_PSET           ; clipped, so a line may run off the
                                        ;  edge and come back
                setal
                LDA @l GX               ; done when both match
                CMP @l GX1
                BNE ln_more
                LDA @l GY
                CMP @l GY1
                BEQ ln_done

ln_more         setal                   ; e2 = 2*err
                LDA @l GERR
                ASL A
                STA @l GE2

                CMP @l GDY              ; signed compare: e2 >= dy
                BVC ln_nov1
                EOR #$8000
ln_nov1         BMI ln_ycheck

                CLC                     ; err += dy, x += sx
                LDA @l GERR
                ADC @l GDY
                STA @l GERR
                CLC
                LDA @l GX
                ADC @l GSX
                STA @l GX

ln_ycheck       setal                   ; e2 <= dx
                LDA @l GDX
                CMP @l GE2
                BVC ln_nov2
                EOR #$8000
ln_nov2         BMI ln_step

                CLC                     ; err += dx, y += sy
                LDA @l GERR
                ADC @l GDX
                STA @l GERR
                CLC
                LDA @l GY
                ADC @l GSY
                STA @l GY
                BRA ln_step

ln_done         PLP
                RETURN
                .pend

;
; PAL2 index, rgb -- VERA2 has a palette of its own.
;
; Nothing like VERA's, which is VRAM. Here an index register
; auto-increments and writing the HIGH half commits the entry, so the
; two halves must go out in order and the low one commits nothing.
;
S_PAL2          .proc
                PHP
                TRACE "S_PAL2"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                setas
                LDA ARGUMENT1
                STA @l VERA2_PALADR

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; $0RGB, as PAL takes
                CALL ASS_ARG1_INT

                setas
                LDA ARGUMENT1           ; low byte is {G,B}
                STA @l VERA2_PALLO
                LDA ARGUMENT1+1
                AND #$0F                ; high nibble is R, and writing it
                STA @l VERA2_PALHI      ;  commits the entry

                PLP
                RETURN
                .pend

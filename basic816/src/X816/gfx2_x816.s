
;;;
;;; GTEXT and FILL
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The last two drawing statements, and the two that need something the
;;; others did not: one reads the FONT out of VRAM, the other reads the
;;; BITMAP back.
;;;

;
; A = the pixel at (GX, GY). Carry set if it is off screen.
;
; The read half of GFX_PSET, and the reason FILL can exist at all: a
; flood fill is defined by what is already on the screen.
;
GFX_PGET        .proc
                PHP
                CALL GFX_ADDR
                BCS pg_off

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
                STA @l GFT
                PLP
                setaxl
                LDA @l GFT
                CLC
                RETURN

pg_off          PLP
                setaxl
                SEC
                RETURN
                .pend

;
; Read the eight scanlines of glyph GTC into GTROW.
;
; The console font is in VRAM, which is not in the CPU address space, so
; this goes through the data port like everything else video -- and the
; base comes from VERA's own tile-base register rather than from a
; constant, so a program that has moved the font with CHARSET draws with
; the font it is actually using.
;
GTX_GLYPH       .proc
                PHP
                setaxl
                PHX

                setas                   ; the font base: the stored value is
                LDA @l VERA_L0_TILEBASE ;  addr >> 9, and the low two bits are
                AND #$FC                ;  not part of it
                setal
                AND #$00FF
                .rept 9
                ASL A
                .next
                STA @l GTB              ; low 16
                LDA #0
                ROL A                   ; the ninth shift carried out
                STA @l GTB+2

                LDA @l GTC              ; + code * 8
                AND #$00FF
                ASL A
                ASL A
                ASL A
                CLC
                ADC @l GTB
                STA @l GTB
                LDA @l GTB+2
                ADC #0
                STA @l GTB+2

                setas
                LDA #0
                STA @l VERA_CTRL        ; data port 0, DCSEL 0
                LDA @l GTB
                STA @l VERA_ADDR_L
                LDA @l GTB+1
                STA @l VERA_ADDR_M
                LDA @l GTB+2
                AND #$01
                ORA #$10                ; auto-increment 1
                STA @l VERA_ADDR_H

                setaxl
                LDX #0
gg_loop         setas
                LDA @l VERA_DATA0
                STA @l GTROW,X
                setaxl
                INX
                CPX #8
                BCC gg_loop

                PLX
                PLP
                RETURN
                .pend

;
; Draw the glyph in GTROW at (GTX0, GTY0).
;
GTX_DRAW        .proc
                PHP
                setaxl
                PHX

                LDA #0
                STA @l GTR              ; the row, 0-7
gd_row          setaxl
                LDA @l GTR
                AND #$00FF
                TAX
                setas
                LDA @l GTROW,X
                STA @l GTBITS

                setaxl
                LDA #0
                STA @l GTCOL            ; the column, 0-7

gd_col          setas
                LDA @l GTBITS           ; bit 7 first: the leftmost pixel is
                AND #$80                ;  the high bit, which is why this
                BEQ gd_next             ;  shifts left rather than right

                setaxl                  ; that pixel, offset by the column
                LDA @l GTX0             ;  and the row
                CLC
                ADC @l GTCOL
                STA @l GX
                LDA @l GTY0
                CLC
                ADC @l GTR
                STA @l GY
                CALL GFX_PSET

gd_next         setas
                LDA @l GTBITS
                ASL A
                STA @l GTBITS

                setaxl
                LDA @l GTCOL
                INC A
                STA @l GTCOL
                CMP #8
                BCC gd_col

                setaxl
                LDA @l GTR
                INC A
                STA @l GTR
                CMP #8
                BCC gd_row

                PLX
                PLP
                RETURN
                .pend

;
; GTEXT x,y,c,s$ -- draw a string into the bitmap.
;
; The colour comes BEFORE the string because the string has to be last:
; there is nothing to peek for after it, so the optional-colour trick the
; shapes use does not apply here. help/GRAPHIC.TXT wrote the signature
; this way and it is the only way round that works.
;
; 8x8, from the CONSOLE'S OWN FONT, read out of VRAM through the port.
; So a program that redefined a glyph with GLYPH draws with the glyph it
; redefined, and one that moved the font with CHARSET draws with the font
; it moved to.
;
; Clipped like everything else here: a string that runs off the right
; edge draws the part that fits, character by character and pixel by
; pixel, because GFX_PSET drops what is outside.
;
S_GTEXT         .proc
                PHP
                TRACE "S_GTEXT"
                setaxl

                CALL EVALEXPR               ; x
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l GTX0
                CALL GFX_COMMAARG           ; y
                STA @l GTY0
                CALL GFX_COMMAARG           ; the colour
                setas
                STA @l GCOL

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; the string
                CALL ASS_ARG1_STR
                setal
                LDA ARGUMENT1               ; MTEMP is the cursor: [ptr] lives
                STA MTEMP                   ;  in the direct page and a string
                LDA ARGUMENT1+2             ;  can be in any bank
                STA MTEMP+2

gt_loop         setas
                LDA [MTEMP]
                BEQ gt_done
                setal
                AND #$00FF
                STA @l GTC

                CALL GTX_GLYPH
                CALL GTX_DRAW

                setal
                LDA @l GTX0                 ; eight pixels along
                CLC
                ADC #8
                STA @l GTX0

                setal                       ; and one character on
                INC MTEMP
                BNE gt_loop
                INC MTEMP+2
                BRA gt_loop

gt_done         PLP
                RETURN
                .pend

;;;
;;; FILL -- a scanline flood fill
;;;
;;; The pixel-at-a-time flood everybody writes first needs a stack entry
;;; per PIXEL, and a filled screen is 307,200 of them. This one pushes a
;;; SEED PER ROW instead: it fills a whole horizontal run, then looks at
;;; the rows above and below that run and pushes one seed for each
;;; unbroken stretch it finds. A rectangle costs one seed a row rather
;;; than one a pixel.
;;;
;;; THE STACK IS FIXED AND THE FILL STOPS WHEN IT IS FULL. 256 seeds,
;;; which is a screen's worth of rows twice over; a shape convoluted
;;; enough to exceed it leaves part of itself unfilled rather than
;;; running into whatever is above the stack. Silently, because there is
;;; nothing a program could usefully do about it mid-fill -- and because
;;; the alternative, an error from a statement that has already drawn
;;; half of something, is worse.
;;;
;;; FILLING WITH THE COLOUR ALREADY THERE IS REFUSED, and that is not
;;; tidiness: the fill would never change a pixel, so no run would ever
;;; terminate and the stack would fill with seeds for work already done.
;;;

;
; Push (GX, GY) if there is room.
;
FIL_PUSH        .proc
                PHP
                setaxl
                PHX

                LDA @l FIL_SP
                CMP #FIL_MAX
                BCS fp_full

                ASL A                       ; two words an entry
                ASL A
                TAX
                LDA @l GX
                STA @l FIL_STK,X
                LDA @l GY
                STA @l FIL_STK+2,X

                LDA @l FIL_SP
                INC A
                STA @l FIL_SP

fp_full         PLX
                PLP
                RETURN
                .pend

;
; Pop into (GX, GY). Carry set when the stack was empty.
;
FIL_POP         .proc
                setaxl
                PHX

                LDA @l FIL_SP
                BEQ fo_empty
                DEC A
                STA @l FIL_SP

                ASL A
                ASL A
                TAX
                LDA @l FIL_STK,X
                STA @l GX
                LDA @l FIL_STK+2,X
                STA @l GY

                PLX
                CLC
                RETURN

fo_empty        PLX
                SEC
                RETURN
                .pend

;
; Look along row GY from FIL_X1 to FIL_X2 and push one seed for each
; unbroken run of the target colour.
;
; ONE SEED A RUN, not one a pixel: the whole point of the scanline form.
; FIL_IN remembers whether the last pixel was part of a run, so a seed
; goes on the stack at the START of each one and nowhere else.
;
FIL_SCAN        .proc
                PHP
                setaxl

                LDA @l GY                   ; off the top or the bottom of the
                BMI fs_done                 ;  screen: nothing to scan
                CMP #VFB_HEIGHT
                BCS fs_done

                LDA #0
                STA @l FIL_IN
                LDA @l FIL_X1
                STA @l GX

fs_loop         setaxl
                LDA @l GX
                CMP @l FIL_X2
                BEQ fs_look
                BCS fs_done

fs_look         CALL GFX_PGET
                BCS fs_out                  ; off screen: not a run
                CMP @l FIL_OLD
                BNE fs_out

                LDA @l FIL_IN               ; the target colour: a seed only
                BNE fs_next                 ;  if this starts the run
                CALL FIL_PUSH
                setaxl
                LDA #1
                STA @l FIL_IN
                BRA fs_next

fs_out          setaxl
                LDA #0
                STA @l FIL_IN

fs_next         setaxl
                LDA @l GX
                CMP @l FIL_X2
                BEQ fs_done
                INC A
                STA @l GX
                BRA fs_loop

fs_done         PLP
                RETURN
                .pend

;
; FILL x,y[,c] -- flood the area of one colour that contains (x,y).
;
S_FILL          .proc
                PHP
                TRACE "S_FILL"
                setaxl

                CALL EVALEXPR               ; x
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l GX
                CALL GFX_COMMAARG           ; y
                STA @l GY
                CALL GFX_OPTCOL

                setaxl
                LDA @l GX                   ; the seed has to be ON the screen
                STA @l FIL_SX               ;  -- there is no area to flood
                LDA @l GY                   ;  otherwise
                STA @l FIL_SY
                CALL GFX_PGET
                BCS fi_toend

                STA @l FIL_OLD              ; the colour being replaced
                setas
                LDA @l GCOL
                setal
                AND #$00FF
                CMP @l FIL_OLD              ; already that colour: nothing to
                BEQ fi_toend                ;  do, and doing it would not stop

                setaxl
                LDA #0
                STA @l FIL_SP
                LDA @l FIL_SX
                STA @l GX
                LDA @l FIL_SY
                STA @l GY
                CALL FIL_PUSH
                BRA fi_pop                  ; and NOT into the trampoline below:
                                            ;  falling through it exited before a
                                            ;  single pixel was filled, which looks
                                            ;  exactly like FILL not working at all

fi_toend        BRL fi_done                 ; the fill body is wider than a
                                            ;  branch reaches

fi_pop          CALL FIL_POP
                BCS fi_toend

                CALL GFX_PGET               ; a seed can be stale: another run
                BCS fi_pop                  ;  may have filled it since
                CMP @l FIL_OLD
                BNE fi_pop

                setaxl                      ; run left
                LDA @l GX
                STA @l FIL_X1
fi_left         setaxl
                LDA @l FIL_X1
                BEQ fi_lend
                DEC A
                STA @l GX
                CALL GFX_PGET
                BCS fi_lend
                CMP @l FIL_OLD
                BNE fi_lend
                setaxl
                LDA @l GX
                STA @l FIL_X1
                BRA fi_left

fi_lend         setaxl                      ; and right
                LDA @l FIL_X1
                STA @l FIL_X2
fi_right        setaxl
                LDA @l FIL_X2
                INC A
                CMP #VFB_WIDTH
                BCS fi_rend
                STA @l GX
                CALL GFX_PGET
                BCS fi_rend
                CMP @l FIL_OLD
                BNE fi_rend
                setaxl
                LDA @l GX
                STA @l FIL_X2
                BRA fi_right

fi_rend         setaxl                      ; paint the run
                LDA @l FIL_X1
                STA @l GHX0
                LDA @l FIL_X2
                STA @l GHX1
                CALL GFX_HLINE

                setaxl                      ; and look above and below it
                LDA @l GY
                STA @l FIL_Y
                DEC A
                STA @l GY
                CALL FIL_SCAN
                setaxl
                LDA @l FIL_Y
                INC A
                STA @l GY
                CALL FIL_SCAN
                setaxl
                LDA @l FIL_Y
                STA @l GY

                BRL fi_pop

fi_done         PLP
                RETURN
                .pend

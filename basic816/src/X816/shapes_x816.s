
;;;
;;; Shapes on the VERA2 bitmap: rectangles, circles, ellipses
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; Everything here is built out of GFX_PSET and GFX_HLINE and knows
;;; nothing else about the framebuffer -- so the clipping is done once,
;;; in GFX_ADDR, and a shape that runs off the edge draws the part that
;;; fits. That is the rule the rest of X816/graphics_x816.s already set.
;;;
;;; THE COLOUR IS OPTIONAL on every statement here, which is what makes
;;; GCOLOR worth a keyword: "GCOLOR 5 : CIRCLE 100,100,40" reads better
;;; than repeating the pen on every line, and a program that draws a
;;; picture in one colour should not have to say so eight times. The
;;; comma is peeked for rather than expected -- see GFX_OPTCOL.
;;;
;;; OUTLINE AND FILLED ARE SEPARATE KEYWORDS. help/GRAPHIC.TXT left
;;; "filled or outline is an argument" open for RECT and answered it
;;; itself for circles by listing CIRCLE and FCIRCLE, so the same answer
;;; is taken for rectangles: RECT and FRECT. A mode argument would have
;;; to be written on every call, and the one thing worse than a keyword
;;; is a magic number.
;;;

;
; The optional colour. If the next non-space character is a comma, read
; a colour after it; otherwise leave GCOL holding whatever GCOLOR (or
; the last drawing statement) put there.
;
; PEEKED and not expected, because "RECT 0,0,10,10" and
; "RECT 0,0,10,10,7" must both be whole statements -- the interpreter
; has to find the end of the line where it expects to.
;
GFX_OPTCOL      .proc
                PHP
                setaxl

                CALL SKIPWS
                setas
                LDA [BIP]
                CMP #','
                BNE oc_none

                CALL INCBIP
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                setas
                LDA ARGUMENT1
                STA @l GCOL

oc_none         PLP
                RETURN
                .pend

;
; Read "expr" into A (16-bit) after a comma.
;
GFX_COMMAARG    .proc
                PHP
                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                PLP
                RETURN
                .pend

;
; A horizontal run from GHX0 to GHX1 at GY, in GCOL.
;
; The span is drawn left to right whichever way round it was given, and
; every pixel goes through GFX_PSET -- so a span that starts off the
; left edge and ends on screen still draws its visible half. Filling by
; spans rather than by pixels is what makes FCIRCLE affordable: one
; address calculation an edge instead of one a pixel would be the
; obvious way and is four times the work.
;
GFX_HLINE       .proc
                PHP
                setaxl

                LDA @l GHX0                 ; put them in order
                CMP @l GHX1
                BCC hl_go
                BEQ hl_go
                LDA @l GHX1
                STA @l GT
                LDA @l GHX0
                STA @l GHX1
                LDA @l GT
                STA @l GHX0

hl_go           LDA @l GHX0
                STA @l GX
hl_loop         LDA @l GX
                CMP @l GHX1
                BEQ hl_last
                BCS hl_done
hl_last         CALL GFX_PSET
                setal
                LDA @l GX
                INC A
                STA @l GX
                LDA @l GX
                CMP @l GHX1
                BEQ hl_loop
                BCC hl_loop

hl_done         PLP
                RETURN
                .pend

;
; RECT x1,y1,x2,y2[,c] -- the outline.
;
S_RECT          .proc
                PHP
                TRACE "S_RECT"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l GRX0
                CALL GFX_COMMAARG
                STA @l GRY0
                CALL GFX_COMMAARG
                STA @l GRX1
                CALL GFX_COMMAARG
                STA @l GRY1
                CALL GFX_OPTCOL

                CALL GFX_RORDER

                setal                       ; the two horizontal edges
                LDA @l GRX0
                STA @l GHX0
                LDA @l GRX1
                STA @l GHX1
                LDA @l GRY0
                STA @l GY
                CALL GFX_HLINE
                setal
                LDA @l GRY1
                STA @l GY
                CALL GFX_HLINE

                setal                       ; and the two vertical ones
                LDA @l GRY0
                STA @l GY
rc_side         LDA @l GRX0
                STA @l GX
                CALL GFX_PSET
                setal
                LDA @l GRX1
                STA @l GX
                CALL GFX_PSET
                setal
                LDA @l GY
                CMP @l GRY1
                BEQ rc_done
                INC A
                STA @l GY
                BRA rc_side

rc_done         PLP
                RETURN
                .pend

;
; FRECT x1,y1,x2,y2[,c] -- filled.
;
S_FRECT         .proc
                PHP
                TRACE "S_FRECT"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l GRX0
                CALL GFX_COMMAARG
                STA @l GRY0
                CALL GFX_COMMAARG
                STA @l GRX1
                CALL GFX_COMMAARG
                STA @l GRY1
                CALL GFX_OPTCOL

                CALL GFX_RORDER

                setal
                LDA @l GRX0
                STA @l GHX0
                LDA @l GRX1
                STA @l GHX1
                LDA @l GRY0
                STA @l GY
fr_row          CALL GFX_HLINE
                setal
                LDA @l GY
                CMP @l GRY1
                BEQ fr_done
                INC A
                STA @l GY
                BRA fr_row

fr_done         PLP
                RETURN
                .pend

;
; Put the rectangle's corners in order, so that a program may give them
; either way round. SIGNED, because a coordinate off the left of the
; screen is negative and has to stay smaller than one that is not.
;
GFX_RORDER      .proc
                PHP
                setal

                SEC
                LDA @l GRX0
                SBC @l GRX1
                BVC ro_xv
                EOR #$8000
ro_xv           BPL ro_xswap
                BRA ro_y
ro_xswap        LDA @l GRX0
                STA @l GT
                LDA @l GRX1
                STA @l GRX0
                LDA @l GT
                STA @l GRX1

ro_y            SEC
                LDA @l GRY0
                SBC @l GRY1
                BVC ro_yv
                EOR #$8000
                ; The same sense as the x half above, which it did NOT
                ; have: this branch swapped when the corners were
                ; ALREADY in order, so y0 became the larger and every
                ; row loop below counted UP away from its limit, round
                ; through 65535 and back to it. FRECT filled the whole
                ; screen except the rectangle, which is a striking way
                ; to be told that a compare is backwards.
ro_yv           BPL ro_yswap
                BRA ro_done
ro_yswap        LDA @l GRY0
                STA @l GT
                LDA @l GRY1
                STA @l GRY0
                LDA @l GT
                STA @l GRY1

ro_done         PLP
                RETURN
                .pend

;
; The eight-way symmetry every Bresenham circle ends in: (cx,cy) plus
; and minus (dx,dy) and (dy,dx).
;
GFX_CPOINTS     .proc
                PHP
                setaxl

                LDA @l GCX
                CLC
                ADC @l GCDX
                STA @l GX
                LDA @l GCY
                CLC
                ADC @l GCDY
                STA @l GY
                CALL GFX_PSET

                setal
                LDA @l GCX
                SEC
                SBC @l GCDX
                STA @l GX
                CALL GFX_PSET

                setal
                LDA @l GCY
                SEC
                SBC @l GCDY
                STA @l GY
                CALL GFX_PSET

                setal
                LDA @l GCX
                CLC
                ADC @l GCDX
                STA @l GX
                CALL GFX_PSET

                setal                       ; and the four with dx and dy
                LDA @l GCX                  ;  exchanged
                CLC
                ADC @l GCDY
                STA @l GX
                LDA @l GCY
                CLC
                ADC @l GCDX
                STA @l GY
                CALL GFX_PSET

                setal
                LDA @l GCX
                SEC
                SBC @l GCDY
                STA @l GX
                CALL GFX_PSET

                setal
                LDA @l GCY
                SEC
                SBC @l GCDX
                STA @l GY
                CALL GFX_PSET

                setal
                LDA @l GCX
                CLC
                ADC @l GCDY
                STA @l GX
                CALL GFX_PSET

                PLP
                RETURN
                .pend

;
; The two spans a filled circle owes each step of the same walk.
;
GFX_CSPANS      .proc
                PHP
                setaxl

                LDA @l GCX
                SEC
                SBC @l GCDX
                STA @l GHX0
                LDA @l GCX
                CLC
                ADC @l GCDX
                STA @l GHX1
                LDA @l GCY
                CLC
                ADC @l GCDY
                STA @l GY
                CALL GFX_HLINE
                setal
                LDA @l GCY
                SEC
                SBC @l GCDY
                STA @l GY
                CALL GFX_HLINE

                setal
                LDA @l GCX
                SEC
                SBC @l GCDY
                STA @l GHX0
                LDA @l GCX
                CLC
                ADC @l GCDY
                STA @l GHX1
                LDA @l GCY
                CLC
                ADC @l GCDX
                STA @l GY
                CALL GFX_HLINE
                setal
                LDA @l GCY
                SEC
                SBC @l GCDX
                STA @l GY
                CALL GFX_HLINE

                PLP
                RETURN
                .pend

;
; Read cx, cy, r and the optional colour, shared by CIRCLE and FCIRCLE.
;
GFX_CARGS       .proc
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l GCX
                CALL GFX_COMMAARG
                STA @l GCY
                CALL GFX_COMMAARG
                STA @l GCR
                CALL GFX_OPTCOL

                PLP
                RETURN
                .pend

;
; The midpoint circle walk, one octant, shared by both statements.
;
; dx starts at 0 and dy at r, and the error term decides at each step
; whether dy comes in. Integer throughout: no square root and no
; trigonometry, which is the whole reason this algorithm is the one
; every machine uses.
;
; SPANS gets a non-zero value to fill rather than outline.
;
GFX_CWALK       .proc
                PHP
                setaxl

                LDA @l GCR                  ; a negative radius is nothing,
                BPL cw_notneg               ;  and r=0 is one pixel
                BRL cw_out
cw_notneg       BNE cw_go
                LDA @l GCX
                STA @l GX
                LDA @l GCY
                STA @l GY
                CALL GFX_PSET
                BRL cw_out

cw_go           LDA #0
                STA @l GCDX
                LDA @l GCR
                STA @l GCDY

                LDA #1                      ; err = 1 - r
                SEC
                SBC @l GCR
                STA @l GCE

cw_loop         LDA @l GCSPAN
                BEQ cw_line
                CALL GFX_CSPANS
                BRA cw_step
cw_line         CALL GFX_CPOINTS

cw_step         setal
                LDA @l GCDX                 ; done when dx passes dy
                CMP @l GCDY
                BCS cw_out

                LDA @l GCDX
                INC A
                STA @l GCDX

                LDA @l GCE                  ; err < 0: the easy step
                BMI cw_east

                LDA @l GCDY                 ; else dy comes in too
                DEC A
                STA @l GCDY
                LDA @l GCE                  ; err += 2*(dx-dy) + 1
                CLC
                ADC @l GCDX
                SEC
                SBC @l GCDY
                ASL A
                CLC
                ADC #1
                STA @l GCE
                BRA cw_loop

cw_east         LDA @l GCE                  ; err += 2*dx + 1
                CLC
                ADC @l GCDX
                ASL A
                CLC
                ADC #1
                STA @l GCE
                BRA cw_loop

cw_out          PLP
                RETURN
                .pend

;
; CIRCLE x,y,r[,c] and FCIRCLE x,y,r[,c].
;
S_CIRCLE        .proc
                PHP
                TRACE "S_CIRCLE"
                setaxl
                CALL GFX_CARGS
                setal
                LDA #0
                STA @l GCSPAN
                CALL GFX_CWALK
                PLP
                RETURN
                .pend

S_FCIRCLE       .proc
                PHP
                TRACE "S_FCIRCLE"
                setaxl
                CALL GFX_CARGS
                setal
                LDA #1
                STA @l GCSPAN
                CALL GFX_CWALK
                PLP
                RETURN
                .pend

; OVAL IS NOT HERE, and the half-built version was taken out rather
; than left to draw the wrong shape.
;
; Bresenham's ellipse needs TWO regions -- one stepping in x while the
; slope is shallower than -1 and one stepping in y after it -- and the
; second region's error term is b2*(x+0.5)^2 + a2*(y-1)^2 - a2*b2, which
; does not fit the 16-bit words everything else here uses. A single
; region draws the top of the ellipse and never reaches the ends of the
; other axis: the leftmost pixel of OVAL 300,50,340,70 was simply
; missing, which is exactly the shape "one region is enough" makes.
;
; What it needs is the incremental form -- sx = 2*b2*x and sy = 2*a2*y
; carried along so the loop adds instead of multiplying -- in 32-bit
; arithmetic, with OP_INT_MUL used three times at the start and never
; inside the walk. help/GRAPHIC.TXT still lists it.

;
; A = A * A, 16-bit.
;
GFX_SQ          .proc
                PHP
                setaxl
                STA ARGUMENT1
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT1+2
                STA ARGUMENT2+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                STA ARGTYPE2
                setal
                CALL OP_INT_MUL
                setaxl
                LDA ARGUMENT1
                PLP
                RETURN
                .pend

;
; GCOLOR c -- the pen every statement above will use when it is not
; given one.
;
S_GCOLOR        .proc
                PHP
                TRACE "S_GCOLOR"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                setas
                LDA ARGUMENT1
                STA @l GCOL

                PLP
                RETURN
                .pend

;
; BITMAP n,addr -- point a bitmap layer at its pixel data.
;
; VERA2's DISPLAY BASE at $9F62-$9F64, which is latched at vsync -- so
; this IS page flipping, and 1 MB holds two 8bpp frames. The layer
; number is accepted and ignored: VERA2 has one bitmap layer and a
; program that says which one is being clearer, not wrong.
;
; The address is in BYTES and the register wants it shifted, so a base
; must be aligned; the low bits are dropped rather than refused, which
; is the same clipping rule the rest of this page uses.
;
S_BITMAP        .proc
                PHP
                TRACE "S_BITMAP"
                setaxl

                CALL EVALEXPR               ; the layer, accepted and ignored
                CALL ASS_ARG1_BYTE

                CALL GFX_COMMAARG           ; the address, low 16
                STA @l GT
                setal
                LDA ARGUMENT1+2
                STA @l GT+2

                setas
                LDA @l GT
                STA @l VERA2_DISPL
                LDA @l GT+1
                STA @l VERA2_DISPM
                LDA @l GT+2
                STA @l VERA2_DISPH

                PLP
                RETURN
                .pend

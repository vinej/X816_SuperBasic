;;;
;;; Reading VRAM back, and moving it to and from the card
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; What the palette, sprite and tile pages were all missing is the same
;;; two things: a way to read a value back, and a way to move a block
;;; between VRAM and a file. Neither is hard; both were waiting on one
;;; decision, which is that VRAM IS NOT IN THE CPU ADDRESS SPACE.
;;;
;;; FK_LOAD reads a file into memory the CPU can address, and VRAM is
;;; not that -- it is reached a byte at a time through a port at $9F20.
;;; So every transfer here goes through a STAGING BUFFER in SDRAM:
;;; load the file to VIO_STAGE and stream it into the port, or stream it
;;; out of the port into VIO_STAGE and save that. One buffer, one pair
;;; of loops, and the eight file statements below are then thin.
;;;
;;; The pointer is MTEMP. [ptr] addressing only exists in the direct
;;; page, that page is 256 bytes and was down to two free (PORT.md 19),
;;; and MTEMP is exactly the shared scratch pointer CMD_LOAD already
;;; streams a loaded file through -- so this costs no direct page at all.
;;;
;;; SIZES ARE CHECKED AGAINST THE OBJECT, not against VRAM. A palette
;;; holds 256 entries; a file of 700 bytes loaded at entry 200 would run
;;; off the end of it and into the sprite attributes at $1FC00, which
;;; would look like sprites going mad rather than like a bad PALLOAD.
;;; Every statement here refuses instead.
;;;

;
; Point data port 0 at VIO_VA with auto-increment 1.
;
VIO_PORT        .proc
                PHP
                setas
                LDA #0
                STA @l VERA_CTRL            ; port 0, DCSEL 0
                LDA @l VIO_VA
                STA @l VERA_ADDR_L
                LDA @l VIO_VA+1
                STA @l VERA_ADDR_M
                LDA @l VIO_VA+2
                AND #$01                    ; VRAM is 17 bits
                ORA #$10                    ; auto-increment 1
                STA @l VERA_ADDR_H
                PLP
                RETURN
                .pend

;
; MTEMP := VIO_STAGE, ready to stream.
;
VIO_POINT       .proc
                PHP
                setal
                LDA #<>VIO_STAGE
                STA MTEMP
                LDA #`VIO_STAGE
                STA MTEMP+2
                PLP
                RETURN
                .pend

;
; Copy VIO_N bytes from the staging buffer into VRAM.
;
; The step is inlined rather than called: this runs once per BYTE, and a
; 256x256 tilemap is 128 KB of them.
;
VIO_WRITE       .proc
                PHP
                CALL VIO_POINT
                CALL VIO_PORT
                setaxl

vw_loop         LDA @l VIO_N                ; anything left?
                ORA @l VIO_N+2
                BEQ vw_done

                setas
                LDA [MTEMP]
                STA @l VERA_DATA0           ; the port steps itself
                setal

                INC MTEMP                   ; 16-bit, so the bank only moves
                BNE vw_count                ;  when the low word wraps
                INC MTEMP+2

vw_count        LDA @l VIO_N
                BNE vw_low
                LDA @l VIO_N+2              ; borrow into the high word
                DEC A
                STA @l VIO_N+2
                LDA #$FFFF
                STA @l VIO_N
                BRA vw_loop
vw_low          DEC A
                STA @l VIO_N
                BRA vw_loop

vw_done         PLP
                RETURN
                .pend

;
; And the other way: VIO_N bytes of VRAM into the staging buffer.
;
VIO_READ        .proc
                PHP
                CALL VIO_POINT
                CALL VIO_PORT
                setaxl

vr_loop         LDA @l VIO_N
                ORA @l VIO_N+2
                BEQ vr_done

                setas
                LDA @l VERA_DATA0
                STA [MTEMP]
                setal

                INC MTEMP
                BNE vr_count
                INC MTEMP+2

vr_count        LDA @l VIO_N
                BNE vr_low
                LDA @l VIO_N+2
                DEC A
                STA @l VIO_N+2
                LDA #$FFFF
                STA @l VIO_N
                BRA vr_loop
vr_low          DEC A
                STA @l VIO_N
                BRA vr_loop

vr_done         PLP
                RETURN
                .pend

;
; Load the file already named by SETFILEDESC into the staging buffer.
;
; Outputs:
;   VIO_N = the file's size
;
; NEITHER OF THESE CALLS SETFILEDESC, and that is the fix for a real bug
; rather than a style preference. SETFILEDESC records a POINTER to the
; string in ARGUMENT1, so it has to be called while ARGUMENT1 still holds
; the filename. VIO_SAVE used to call it itself, which works only when
; the filename is the LAST argument: SPRITESAVE and TMAPSAVE were fine
; and PALSAVE, whose filename comes first, handed the kernel a pointer to
; the COUNT and answered "Unable to save file". TILESAVE had it too.
;
; So the rule is local and visible at every call site: name the file,
; then SETFILEDESC, immediately.
;
VIO_LOAD        .proc
                PHP
                setaxl

                LDA #<>VIO_STAGE
                STA @l DOS_DST_PTR
                LDA #`VIO_STAGE
                STA @l DOS_DST_PTR+2

                JSL FK_LOAD                 ; carry SET is success on this side
                BCS vl_ok

                CALL SET_DOSSTAT
                PLP
                THROW ERR_LOAD

vl_ok           CALL SET_DOSSTAT
                setal
                LDA @l FD_IN.FILESIZE
                STA @l VIO_N
                LDA @l FD_IN.FILESIZE+2
                STA @l VIO_N+2

                PLP
                RETURN
                .pend

;
; Save VIO_T bytes of the staging buffer to the file already named by
; SETFILEDESC. See the note above about who calls that, and why.
;
; The count comes from VIO_T and not VIO_N because VIO_READ counts its
; own down to zero on the way in.
;
VIO_SAVE        .proc
                PHP
                setaxl

                LDA #<>VIO_STAGE
                STA @l DOS_SRC_PTR
                LDA #`VIO_STAGE
                STA @l DOS_SRC_PTR+2

                CLC                         ; END is INCLUSIVE, so + N - 1
                LDA #<>VIO_STAGE
                ADC @l VIO_T
                STA @l DOS_END_PTR
                LDA #`VIO_STAGE
                ADC @l VIO_T+2
                STA @l DOS_END_PTR+2
                SEC
                LDA @l DOS_END_PTR
                SBC #1
                STA @l DOS_END_PTR
                LDA @l DOS_END_PTR+2
                SBC #0
                STA @l DOS_END_PTR+2

                JSL FK_SAVE
                BCS vs_ok

                CALL SET_DOSSTAT
                PLP
                THROW ERR_SAVE

vs_ok           CALL SET_DOSSTAT
                PLP
                RETURN
                .pend

;
; VIO_N := VIO_T, for a transfer whose length is known rather than read
; off a file.
;
VIO_SETN        .proc
                PHP
                setal
                LDA @l VIO_T
                STA @l VIO_N
                LDA @l VIO_T+2
                STA @l VIO_N+2
                PLP
                RETURN
                .pend

;;;
;;; The palette -- 256 entries of two bytes at $1FA00.
;;;

;
; VIO_VA := the address of palette entry A (16-bit, 0-255 already).
; VIO_U  := that entry's byte offset into the palette, for a bounds check.
;
PAL_ADDR        .proc
                PHP
                setal
                AND #$00FF
                ASL A                       ; two bytes an entry
                STA @l VIO_U
                CLC
                ADC #<>VERA_PALETTE
                STA @l VIO_VA
                LDA #1                      ; the palette is above $10000
                STA @l VIO_VA+2
                PLP
                RETURN
                .pend

;
; PALGET(index) -- read an entry back as a 12-bit $0RGB value.
;
; The warning on help/PAL.TXT is the whole story and is not this
; routine's fault: an entry NOBODY EVER WROTE does not read back as the
; colour on screen. Only what a program set can be trusted, which is why
; PALSAVE takes a range instead of assuming 256.
;
FN_PALGET       .proc
                FN_START "FN_PALGET"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                CALL PAL_ADDR
                CALL VIO_PORT

                setas
                LDA @l VERA_DATA0           ; green and blue
                STA @l VIO_U
                LDA @l VERA_DATA0           ; red, in the low nibble
                AND #$0F
                STA @l VIO_U+1

                setal
                LDA @l VIO_U
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
; SETCOLOR index, rgb -- BASIC816's spelling for the sixteen text colours.
;
; The same store as PAL with the range held to 0-15, and not merely an
; alias: the point of the keyword is that 0-15 ARE the text palette, so
; an index of 200 is a mistake here and says so.
;
S_SETCOLOR      .proc
                PHP
                TRACE "S_SETCOLOR"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                CMP #16
                BCS sc_range
                CALL PAL_ADDR

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT

                CALL VIO_PORT
                setas
                LDA ARGUMENT1               ; green and blue
                STA @l VERA_DATA0
                LDA ARGUMENT1+1             ; red
                AND #$0F
                STA @l VERA_DATA0

                PLP
                RETURN
sc_range        THROW ERR_RANGE
                .pend

;
; PALLOAD file$, start -- load entries from a file, from an index on.
;
S_PALLOAD       .proc
                PHP
                TRACE "S_PALLOAD"
                setaxl

                CALL EVALEXPR               ; the filename, FIRST, and
                CALL ASS_ARG1_STR           ;  named and loaded before the
                CALL SETFILEDESC            ;  index expression can take
                CALL VIO_LOAD               ;  ARGUMENT1 away from it
                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; the first entry to fill
                CALL ASS_ARG1_BYTE

                setal
                LDA ARGUMENT1
                CALL PAL_ADDR

                LDA @l VIO_N+2              ; a file of more than 64 KB is
                BNE pl_range                ;  not a palette

                CLC                         ; offset + length must stay
                LDA @l VIO_U                ;  inside the 512-byte palette,
                ADC @l VIO_N                ;  or this writes over the
                BCS pl_range                ;  sprite attributes at $1FC00
                CMP #513
                BCS pl_range

                CALL VIO_WRITE

                PLP
                RETURN
pl_range        THROW ERR_RANGE
                .pend

;
; PALSAVE file$, start, count -- save a RANGE of entries.
;
S_PALSAVE       .proc
                PHP
                TRACE "S_PALSAVE"
                setaxl

                CALL EVALEXPR               ; the filename
                CALL ASS_ARG1_STR
                CALL SETFILEDESC

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; the first entry
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                CALL PAL_ADDR               ; VIO_VA, and VIO_U = start*2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; how many
                CALL ASS_ARG1_INT

                setal
                LDA ARGUMENT1
                BEQ ps_range                ; no entries is a mistake, not
                CMP #257                    ;  an empty file
                BCS ps_range
                ASL A                       ; two bytes an entry
                STA @l VIO_T
                LDA #0
                STA @l VIO_T+2

                CLC
                LDA @l VIO_U                ; start*2 + count*2 <= 512
                ADC @l VIO_T
                CMP #513
                BCS ps_range

                CALL VIO_SETN
                CALL VIO_READ
                CALL VIO_SAVE

                PLP
                RETURN
ps_range        THROW ERR_RANGE
                .pend

;;;
;;; Sprites -- attributes at $1FC00, pixels anywhere in VRAM.
;;;

;
; From sprite VIO_U: VIO_VA := where its pixels are, VIO_T := how many
; bytes of them there are.
;
; Both come out of the sprite's own attribute record, which is why
; SPRITEIMG and SPRITESIZE have to have been said first:
;
;   +0/+1  the image address, stored SHIFTED RIGHT FIVE, with bits 16:13
;          in +1's low nibble and the colour mode in +1 bit 7
;   +7     height 7:6 and width 5:4 as size codes 0-3 = 8, 16, 32, 64
;
; 4bpp (the mode bit clear) is half a byte a pixel, so half the bytes.
; The mode bit is copied out BEFORE the address is unshifted over it.
;
SPR_IMAGE       .proc
                PHP
                setaxl

                LDA @l VIO_U                ; SPR_REC works off ARGUMENT1
                STA ARGUMENT1
                CALL SPR_REC
                CALL VRAM_PORT

                setas
                LDA @l VERA_DATA0           ; +0
                STA @l VIO_V
                LDA @l VERA_DATA0           ; +1
                STA @l VIO_V+1
                LDA @l VERA_DATA0           ; +2 X
                LDA @l VERA_DATA0           ; +3
                LDA @l VERA_DATA0           ; +4 Y
                LDA @l VERA_DATA0           ; +5
                LDA @l VERA_DATA0           ; +6 collision, depth, flips
                LDA @l VERA_DATA0           ; +7 height, width, palette
                STA @l VIO_V+2

                setas                       ; the colour mode, kept before
                LDA @l VIO_V+1              ;  the address is unshifted
                AND #$80                    ;  over the byte holding it
                STA @l VIO_V+3

                setal                       ; addr := (+1:+0 & $0FFF) << 5
                LDA @l VIO_V
                AND #$0FFF
                PHA
                .rept 5
                ASL A
                .next
                STA @l VIO_VA               ; the low sixteen bits
                PLA
                .rept 11
                LSR A
                .next
                STA @l VIO_VA+2             ; ... and bit 16

                setas                       ; width, from the size code
                LDA @l VIO_V+2
                LSR A
                LSR A
                LSR A
                LSR A
                AND #$03
                TAX
                LDA @l spr_px,X
                STA @l VIO_U                ; pixels across

                LDA @l VIO_V+2              ; height
                LSR A
                LSR A
                LSR A
                LSR A
                LSR A
                LSR A
                AND #$03
                TAX
                LDA @l spr_px,X
                STA @l VIO_U+1              ; pixels down

                setal                       ; width * height. Both are
                LDA @l VIO_U                ;  powers of two and at most
                AND #$00FF                  ;  64, so 4096 is the largest
                STA @l VIO_T                ;  product and a repeated add
                LDA @l VIO_U                ;  is quite fast enough.
                XBA
                AND #$00FF
                TAX
                LDA #0
spr_mul         CLC
                ADC @l VIO_T
                DEX
                BNE spr_mul
                STA @l VIO_T
                LDA #0
                STA @l VIO_T+2

                setas
                LDA @l VIO_V+3              ; 8bpp keeps every byte
                BNE spr_done
                setal                       ; 4bpp is two pixels a byte
                LDA @l VIO_T
                LSR A
                STA @l VIO_T

spr_done        PLP
                RETURN
spr_px          .byte 8, 16, 32, 64
                .pend

;
; SPRITEGET(n, which) -- read a sprite's position back. 0 is X, 1 is Y.
;
; A function with an index rather than two functions without, for the
; reason MOUSE() gives on its own page: an argument costs one token and
; needs nothing else, while a no-argument function needs the whole
; minus-sign rule to know about it.
;
FN_SPRITEGET    .proc
                FN_START "FN_SPRITEGET"
                PHP
                setaxl

                CALL EVALEXPR               ; which sprite
                CALL ASS_ARG1_BYTE
                CALL SPR_REC

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; X or Y
                CALL ASS_ARG1_BYTE

                setas
                LDA ARGUMENT1
                AND #$01
                BEQ sg_x
                LDA #4                      ; +4/+5 is Y
                BRA sg_field
sg_x            LDA #2                      ; +2/+3 is X
sg_field        CALL SPR_FIELD
                CALL VRAM_PORT

                setas
                LDA @l VERA_DATA0
                STA @l VIO_U
                LDA @l VERA_DATA0
                AND #$03                    ; ten bits, so 0-1023
                STA @l VIO_U+1

                setal
                LDA @l VIO_U
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
; SPRITELOAD n, file$ -- load pixels straight into a sprite's image area.
;
; The file's own length is used and not the sprite's, so an image can be
; loaded a strip at a time; refusing a short file would prevent that for
; no gain.
;
S_SPRITELOAD    .proc
                PHP
                TRACE "S_SPRITELOAD"
                setaxl

                CALL EVALEXPR               ; which sprite
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                STA @l VIO_U
                CALL SPR_IMAGE              ; VIO_VA := where its pixels go

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; the filename
                CALL ASS_ARG1_STR
                CALL SETFILEDESC            ; while ARGUMENT1 is still it
                CALL VIO_LOAD

                CALL VIO_WRITE

                PLP
                RETURN
                .pend

;
; SPRITESAVE n, file$ -- and back out again, self-sizing.
;
S_SPRITESAVE    .proc
                PHP
                TRACE "S_SPRITESAVE"
                setaxl

                CALL EVALEXPR               ; which sprite
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                STA @l VIO_U
                CALL SPR_IMAGE              ; VIO_VA and VIO_T

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; the filename
                CALL ASS_ARG1_STR
                CALL SETFILEDESC

                CALL VIO_SETN
                CALL VIO_READ
                CALL VIO_SAVE

                PLP
                RETURN
                .pend

;
; Refuse a transfer that would run off the end of VRAM.
;
; VRAM is 128 KB and the address port wraps, so a file too big for where
; it is going does not fail -- it quietly writes over the beginning,
; which on this machine is the console tilemap. Refusing is the only way
; that is ever noticed.
;
; Clobbers VIO_V, which every caller has finished with by this point.
;
VIO_FITS        .proc
                PHP
                setaxl

                CLC
                LDA @l VIO_VA
                ADC @l VIO_N
                STA @l VIO_V
                LDA @l VIO_VA+2
                ADC @l VIO_N+2
                STA @l VIO_V+2

                CMP #3                      ; the sum, in 64 KB units
                BCS vf_bad
                CMP #2
                BCC vf_ok                   ; still inside $1FFFF
                LDA @l VIO_V                ; exactly $20000 is the end, and
                BNE vf_bad                  ;  an end is allowed

vf_ok           PLP
                RETURN
vf_bad          PLP
                THROW ERR_RANGE
                .pend

;;;
;;; Tilemaps and tile graphics.
;;;

;
; X := the shift that multiplies by A cells: 32, 64, 128 or 256, and 256
; is stored in the config as 0. Entered with 8-bit A and 16-bit X.
;
LYR_SHIFT       .proc
                PHP
                setaxl
                setas

                CMP #0
                BEQ ls_256
                LDX #5
                CMP #32
                BEQ ls_out
                LDX #6
                CMP #64
                BEQ ls_out
                LDX #7
                BRA ls_out
ls_256          LDX #8

ls_out          PLP
                RETURN
                .pend

;
; From layer ARGUMENT1:
;   VIO_VA  = its map base -- MAPBASE holds the address >> 9
;   VIO_U   = the map width in cells, VIO_U+1 the height (0 means 256)
;   VIO_U+2 = the config byte itself
;
LYR_MAP         .proc
                PHP
                PHX
                setaxl

                CALL LYR_SEL                ; X := 0 or LAYER_STRIDE

                setas
                LDA @l VERA_L0_MAPBASE,X
                STA @l VIO_V
                LDA @l VERA_L0_CONFIG,X
                STA @l VIO_V+1

                setal                       ; addr := mapbase << 9
                LDA @l VIO_V
                AND #$00FF
                PHA
                .rept 9
                ASL A
                .next
                STA @l VIO_VA
                PLA
                .rept 7
                LSR A
                .next
                STA @l VIO_VA+2             ; bit 16

                setas
                LDA @l VIO_V+1
                STA @l VIO_U+2              ; the callers want it too

                LSR A                       ; width, bits 5:4
                LSR A
                LSR A
                LSR A
                AND #$03
                TAX
                LDA @l map_cells,X
                STA @l VIO_U

                LDA @l VIO_V+1              ; height, bits 7:6
                LSR A
                LSR A
                LSR A
                LSR A
                LSR A
                LSR A
                AND #$03
                TAX
                LDA @l map_cells,X
                STA @l VIO_U+1

                PLX
                PLP
                RETURN
map_cells       .byte 32, 64, 128, 0        ; 0 stands for 256
                .pend

;
; From layer ARGUMENT1: VIO_VA := its tile graphics base.
;
; TILEBASE holds the address >> 11 in bits 7:2 and the tile size in 1:0,
; so masking off the size and shifting left nine is the same thing as
; shifting right two and left eleven, with one instruction less.
;
LYR_TILES       .proc
                PHP
                PHX
                setaxl

                CALL LYR_SEL

                setas
                LDA @l VERA_L0_TILEBASE,X
                AND #$FC
                STA @l VIO_V

                setal
                LDA @l VIO_V
                AND #$00FF
                PHA
                .rept 9
                ASL A
                .next
                STA @l VIO_VA
                PLA
                .rept 7
                LSR A
                .next
                STA @l VIO_VA+2

                PLX
                PLP
                RETURN
                .pend

;
; VIO_T := the whole map's size in bytes, from VIO_U's width and height.
;
; Both are powers of two, so this is 1 << (widthshift + heightshift + 1)
; -- and it needs all 32 bits: a 256x256 map is exactly $20000 bytes.
;
LYR_MAPSZ       .proc
                PHP
                PHX
                setaxl

                setas
                LDA @l VIO_U                ; width
                CALL LYR_SHIFT
                setal
                TXA
                STA @l VIO_V

                setas
                LDA @l VIO_U+1              ; height
                CALL LYR_SHIFT
                setal
                TXA
                CLC
                ADC @l VIO_V
                INC A                       ; two bytes a cell
                TAX

                LDA #1
                STA @l VIO_T
                LDA #0
                STA @l VIO_T+2
ms_loop         LDA @l VIO_T
                ASL A
                STA @l VIO_T                ; LDA does not touch the carry,
                LDA @l VIO_T+2              ;  so the ROL below still has
                ROL A                       ;  the one the ASL made
                STA @l VIO_T+2
                DEX
                BNE ms_loop

                PLX
                PLP
                RETURN
                .pend

;
; VIO_VA += (y * width + x) * 2 -- the address of one cell.
;
; Inputs:
;   VIO_VA, VIO_U = what LYR_MAP left
;   VIO_V = x, VIO_V+2 = y (words)
;
LYR_CELL        .proc
                PHP
                PHX
                setaxl

                setas
                LDA @l VIO_U
                CALL LYR_SHIFT              ; X := cells-per-row as a shift

                setal
                LDA @l VIO_V+2              ; y
lc_loop         ASL A
                DEX
                BNE lc_loop
                CLC
                ADC @l VIO_V                ; + x

                ASL A                       ; two bytes a cell; the carry
                STA @l VIO_V+2              ;  out of this is bit 16
                LDA #0
                ADC #0
                STA @l VIO_V

                CLC
                LDA @l VIO_VA
                ADC @l VIO_V+2
                STA @l VIO_VA
                LDA @l VIO_VA+2
                ADC @l VIO_V
                AND #$0001                  ; VRAM is 17 bits and wraps
                STA @l VIO_VA+2

                PLX
                PLP
                RETURN
                .pend

;
; The layer, x and y that three of the statements below all start with.
; Leaves VIO_VA pointing at the cell.
;
LYR_ARGS        .proc
                PHP
                setaxl

                CALL EVALEXPR               ; which layer
                CALL ASS_ARG1_BYTE
                CALL LYR_MAP

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; column
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l VIO_V

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; row
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l VIO_V+2

                CALL LYR_CELL

                PLP
                RETURN
                .pend

;
; TILEGET(n, x, y) -- read a cell's tile code back.
;
; Unlike TILEAT this takes a layer number, because a layer whose map has
; been pointed somewhere else by TILEMAP is exactly the one worth
; reading. The geometry comes from the layer's own registers rather than
; being assumed, so a 32-wide map reads correctly too.
;
FN_TILEGET      .proc
                FN_START "FN_TILEGET"
                PHP
                setaxl

                CALL LYR_ARGS
                CALL VIO_PORT

                setas
                LDA @l VERA_DATA0           ; the code; +1 is the attribute
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
; TILEATTR n, x, y, attr -- write a cell's colour attribute, leaving the
; character alone. Foreground in the low nibble, background in the high.
;
S_TILEATTR      .proc
                PHP
                TRACE "S_TILEATTR"
                setaxl

                CALL LYR_ARGS

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setal                       ; the attribute is the SECOND
                LDA @l VIO_VA               ;  byte of the cell. INC has no
                INC A                       ;  long addressing mode, so it
                STA @l VIO_VA               ;  goes through A.
                BNE ta_port
                LDA @l VIO_VA+2
                INC A
                AND #$0001
                STA @l VIO_VA+2

ta_port         CALL VIO_PORT
                setas
                LDA ARGUMENT1
                STA @l VERA_DATA0

                PLP
                RETURN
                .pend

;
; TMAPLOAD n, file$ -- a whole tilemap in from a file.
;
S_TMAPLOAD      .proc
                PHP
                TRACE "S_TMAPLOAD"
                setaxl

                CALL EVALEXPR               ; which layer
                CALL ASS_ARG1_BYTE
                CALL LYR_MAP
                CALL LYR_MAPSZ              ; VIO_T := what the map holds

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; the filename
                CALL ASS_ARG1_STR
                CALL SETFILEDESC            ; while ARGUMENT1 is still it
                CALL VIO_LOAD               ; VIO_N := what the file holds

                LDA @l VIO_N+2              ; a file bigger than the map
                CMP @l VIO_T+2              ;  would wrap over the console
                BCC tl_ok
                BNE tl_range
                LDA @l VIO_N
                CMP @l VIO_T
                BEQ tl_ok
                BCS tl_range

tl_ok           CALL VIO_WRITE

                PLP
                RETURN
tl_range        THROW ERR_RANGE
                .pend

;
; TMAPSAVE n, file$ -- and out again. Self-sizing: the config byte
; carries the map's width and height codes and a cell is two bytes.
;
S_TMAPSAVE      .proc
                PHP
                TRACE "S_TMAPSAVE"
                setaxl

                CALL EVALEXPR               ; which layer
                CALL ASS_ARG1_BYTE
                CALL LYR_MAP
                CALL LYR_MAPSZ

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; the filename
                CALL ASS_ARG1_STR
                CALL SETFILEDESC

                CALL VIO_SETN
                CALL VIO_READ
                CALL VIO_SAVE

                PLP
                RETURN
                .pend

;
; TILELOAD n, file$ -- the tile graphics themselves.
;
S_TILELOAD      .proc
                PHP
                TRACE "S_TILELOAD"
                setaxl

                CALL EVALEXPR               ; which layer
                CALL ASS_ARG1_BYTE
                CALL LYR_TILES

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; the filename
                CALL ASS_ARG1_STR
                CALL SETFILEDESC            ; while ARGUMENT1 is still it
                CALL VIO_LOAD

                CALL VIO_FITS               ; tile data has no length of
                CALL VIO_WRITE              ;  its own, so all that can be
                                            ;  checked is the end of VRAM
                PLP
                RETURN
                .pend

;
; TILESAVE n, file$, len -- and out again.
;
; The length is asked for because tile data genuinely has none: where the
; graphics stop is something only the program that drew them knows.
;
S_TILESAVE      .proc
                PHP
                TRACE "S_TILESAVE"
                setaxl

                CALL EVALEXPR               ; which layer
                CALL ASS_ARG1_BYTE
                CALL LYR_TILES

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; the filename
                CALL ASS_ARG1_STR
                CALL SETFILEDESC

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; how many bytes
                CALL ASS_ARG1_INT

                setal
                LDA ARGUMENT1
                BEQ ts_range                ; a file of nothing is a mistake
                STA @l VIO_T
                LDA ARGUMENT1+2
                AND #$0001
                STA @l VIO_T+2

                CALL VIO_SETN
                CALL VIO_FITS
                CALL VIO_SETN               ; VIO_FITS does not consume it,
                                            ;  but VIO_READ will
                CALL VIO_READ
                CALL VIO_SAVE

                PLP
                RETURN
ts_range        THROW ERR_RANGE
                .pend


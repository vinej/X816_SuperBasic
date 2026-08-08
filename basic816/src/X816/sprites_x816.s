;;;
;;; Sprites for the X816
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; VERA has 128 sprites and their attributes are VRAM, eight bytes each
;;; from $1FC00 -- so, like the palette and the PSG, no register
;;; protocol is involved. The layout was read out of the emulator's
;;; video.c rather than assumed from the X16:
;;;
;;;   +0    image address bits 12:5
;;;   +1    bit 7 colour mode (0 = 4bpp), bits 3:0 address bits 16:13
;;;   +2/+3 X, ten bits
;;;   +4/+5 Y, ten bits
;;;   +6    collision mask 7:4, z-depth 3:2, vflip 1, hflip 0
;;;   +7    height 7:6, width 5:4, palette offset 3:0
;;;
;;; Three of these statements are BASIC816's own keywords, which have
;;; thrown an argument error since phase 1 because they were written for
;;; the C256's VICKY. They mean something now.
;;;
;;; Bytes +6 and +7 pack several fields, so both are read-modify-write:
;;; writing a whole byte would silently clear the collision mask, the
;;; flips or the palette offset.
;;;

;
; VID_A := the address of sprite ARGUMENT1's attribute record.
;
; 128 records of eight bytes from $1FC00 end at $1FFF8, so the low word
; never carries and the bank byte is always 1.
;
SPR_REC         .proc
                PHP
                setal
                LDA ARGUMENT1
                AND #$007F
                ASL A
                ASL A
                ASL A
                CLC
                ADC #<>VERA_SPRATTR
                STA @l VID_A
                LDA #1
                STA @l VID_A+2
                PLP
                RETURN
                .pend

;
; Add A (8-bit, unsigned) to VID_A. Used to step to a field.
;
SPR_FIELD       .proc
                PHP
                setal
                AND #$00FF
                CLC
                ADC @l VID_A
                STA @l VID_A
                PLP
                RETURN
                .pend

;
; Point the data port at VID_A with auto-increment 1.
;
VRAM_PORT       .proc
                PHP
                setas
                LDA #0
                STA @l VERA_CTRL
                LDA @l VID_A
                STA @l VERA_ADDR_L
                LDA @l VID_A+1
                STA @l VERA_ADDR_M
                LDA @l VID_A+2
                AND #$01
                ORA #$10                    ; auto-increment 1
                STA @l VERA_ADDR_H
                PLP
                RETURN
                .pend

;
; Switch the sprite layer on. Individual sprites stay invisible until
; they are given a z-depth, so any of them may call this.
;
SPR_ENABLE      .proc
                PHP
                setas
                LDA #0
                STA @l VERA_CTRL            ; DCSEL 0
                LDA @l VERA_DC_VIDEO
                ORA #$40                    ; bit 6: sprites
                STA @l VERA_DC_VIDEO
                PLP
                RETURN
                .pend

;
; Write the z-depth in VID_A+4 into attribute byte +6, keeping the
; collision mask and the flip bits. Shared by SPRITE and SPRITESHOW.
;
SPR_SETZ        .proc
                PHP
                setas
                LDA #6
                CALL SPR_FIELD
                CALL VRAM_PORT

                setas
                LDA @l VERA_DATA0           ; read: keeps 7:4 and 1:0
                AND #$F3
                STA @l VID_A+6
                LDA @l VID_A+4
                AND #$03
                ASL A
                ASL A
                ORA @l VID_A+6
                PHA
                CALL VRAM_PORT              ; the read moved the pointer on
                PLA
                STA @l VERA_DATA0

                PLP
                RETURN
                .pend

;
; SPRITE n, zdepth -- 0 hidden, 1 behind the layers, 2 between, 3 in front.
;
S_SPRITE        .proc
                PHP
                TRACE "S_SPRITE"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                CALL SPR_REC

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setal
                LDA ARGUMENT1
                STA @l VID_A+4
                CALL SPR_SETZ
                CALL SPR_ENABLE

                PLP
                RETURN
                .pend

;
; SPRITESHOW n, on -- show or hide without disturbing anything else.
;
; "Show" means z-depth 3, in front. A sprite that belongs behind a layer
; should say so with SPRITE n,1 or n,2.
;
S_SPRITESHOW    .proc
                PHP
                TRACE "S_SPRITESHOW"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                CALL SPR_REC

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setal
                LDA ARGUMENT1
                BEQ spshow_off
                LDA #3
spshow_off      STA @l VID_A+4
                CALL SPR_SETZ
                CALL SPR_ENABLE

                PLP
                RETURN
                .pend

;
; SPRITEAT n, x, y -- position. Ten bits each, so 0-1023.
;
S_SPRITEAT      .proc
                PHP
                TRACE "S_SPRITEAT"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                CALL SPR_REC

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; X
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l VID_A+4

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; Y
                CALL ASS_ARG1_INT

                setas                       ; bytes +2 through +5
                LDA #2
                CALL SPR_FIELD
                CALL VRAM_PORT

                setas
                LDA @l VID_A+4
                STA @l VERA_DATA0
                LDA @l VID_A+5
                AND #$03
                STA @l VERA_DATA0
                LDA ARGUMENT1
                STA @l VERA_DATA0
                LDA ARGUMENT1+1
                AND #$03
                STA @l VERA_DATA0

                PLP
                RETURN
                .pend

;
; SPRITEIMG n, vramaddr -- where the sprite's pixels live.
;
; 4bpp, which is what the size codes assume. The address is stored
; shifted right five, so sprite images are 32-byte aligned.
;
S_SPRITEIMG     .proc
                PHP
                TRACE "S_SPRITEIMG"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                CALL SPR_REC

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT

                setal                       ; addr >> 5, 17 bits in
                LDA ARGUMENT1+2             ; bits 16 upward come back down
                AND #$00FF                  ;  eleven places
                .rept 11
                ASL A
                .next
                STA @l VID_A+6
                LDA ARGUMENT1
                LSR A
                LSR A
                LSR A
                LSR A
                LSR A
                ORA @l VID_A+6
                STA @l VID_A+4

                CALL VRAM_PORT
                setas
                LDA @l VID_A+4              ; bits 12:5
                STA @l VERA_DATA0
                LDA @l VID_A+5              ; bits 16:13; bit 7 clear = 4bpp
                AND #$0F
                STA @l VERA_DATA0

                PLP
                RETURN
                .pend

;
; SPRITESIZE n, w, h -- size codes 0-3, meaning 8, 16, 32 and 64 pixels.
;
S_SPRITESIZE    .proc
                PHP
                TRACE "S_SPRITESIZE"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                CALL SPR_REC

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; width code, bits 5:4
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                AND #$0003
                ASL A
                ASL A
                ASL A
                ASL A
                STA @l VID_A+4

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; height code, bits 7:6
                CALL ASS_ARG1_BYTE

                setal
                LDA ARGUMENT1
                AND #$0003
                .rept 6
                ASL A
                .next
                ORA @l VID_A+4
                STA @l VID_A+4

                setas
                LDA #7
                CALL SPR_FIELD
                CALL VRAM_PORT

                setas
                LDA @l VERA_DATA0           ; keep the palette offset
                AND #$0F
                STA @l VID_A+6
                LDA @l VID_A+4
                ORA @l VID_A+6
                PHA
                CALL VRAM_PORT
                PLA
                STA @l VERA_DATA0

                PLP
                RETURN
                .pend

;;;
;;; Tilemap cells and layer visibility.
;;;
;;; The console IS a tilemap: layer 0, VRAM $00000, two bytes a cell,
;;; 128 cells to a row. So a cell address is y*256 + x*2, which is a
;;; shift and an add rather than a multiply.
;;;
;;; A cell is a screen code and a colour attribute, foreground in the
;;; low nibble and background in the high one. Writing one is therefore
;;; a way to place a character AND its colours in a single statement,
;;; which PRINT cannot do.
;;;
;;; Two more keywords that have thrown an argument error since phase 1.
;;;

;
; TILEAT x, y, code, attr -- write one cell of the console tilemap.
;
S_TILEAT        .proc
                PHP
                TRACE "S_TILEAT"
                setaxl

                CALL EVALEXPR               ; column
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                AND #$00FF
                ASL A                       ; two bytes a cell
                STA @l VID_A

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; row
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                AND #$00FF
                XBA                         ; times 256: a row is 128 cells
                CLC
                ADC @l VID_A
                STA @l VID_A
                LDA #0
                STA @l VID_A+2              ; the map is at VRAM $00000

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; screen code
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                STA @l VID_A+4

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; colour attribute
                CALL ASS_ARG1_BYTE

                CALL VRAM_PORT
                setas
                LDA @l VID_A+4
                STA @l VERA_DATA0
                LDA ARGUMENT1
                STA @l VERA_DATA0

                PLP
                RETURN
                .pend

;
; TILESHOW layer, on -- switch a display layer on or off.
;
; Layer 0 is the console on this machine, not layer 1 as on the X16, so
; TILESHOW 0,0 blanks the text screen. It comes back.
;
S_TILESHOW      .proc
                PHP
                TRACE "S_TILESHOW"
                setaxl

                CALL EVALEXPR               ; which layer
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                AND #$0001
                BEQ tsh_layer0
                LDA #$20                    ; bit 5: layer 1
                BRA tsh_mask
tsh_layer0      LDA #$10                    ; bit 4: layer 0
tsh_mask        STA @l VID_A

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; on or off
                CALL ASS_ARG1_BYTE

                setas
                LDA #0
                STA @l VERA_CTRL            ; DCSEL 0
                LDA ARGUMENT1
                BEQ tsh_off

                LDA @l VERA_DC_VIDEO
                ORA @l VID_A
                STA @l VERA_DC_VIDEO
                PLP
                RETURN

tsh_off         LDA @l VID_A
                EOR #$FF
                AND @l VERA_DC_VIDEO
                STA @l VERA_DC_VIDEO

                PLP
                RETURN
                .pend

;;;
;;; Where a layer keeps its map and its tiles.
;;;
;;; Layer 0's registers are $9F2D-$9F33 and layer 1's are $9F34-$9F3A,
;;; so a layer's block is seven bytes and X holds n*7. Within a block:
;;;
;;;   +0  config    colour depth 1:0, bitmap 2, 256-colour text 3,
;;;                 map width 5:4, map height 7:6
;;;   +1  map base  the address >> 9, so a 512-byte boundary
;;;   +2  tile base the address >> 11 in bits 7:2, so a 2 KB boundary;
;;;                 bits 1:0 are the tile width and height and are not
;;;                 ours to touch
;;;
;;; Careful with layer 0 while the console is live: its map at $00000 and
;;; its font at $04000 ARE the text screen. Repointing them is how you
;;; get your own screen; typing TILEMAP 0,0 blind is how you get it back.
;;;

LAYER_STRIDE    = 7

;
; X := the register offset of layer ARGUMENT1. Only two layers exist.
;
LYR_SEL         .proc
                PHP
                setaxl
                LDA ARGUMENT1
                AND #$0001
                BEQ lsel_0
                LDX #LAYER_STRIDE
                PLP
                RETURN
lsel_0          LDX #0
                PLP
                RETURN
                .pend

;
; TILEMAP n, addr -- point a layer at its map.
;
S_TILEMAP       .proc
                PHP
                TRACE "S_TILEMAP"
                setaxl
                PHX

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                CALL LYR_SEL

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT

                LDA ARGUMENT1           ; stored as addr >> 9, so a finer
                AND #$01FF              ;  address would be rounded down in
                BNE tm_bad              ;  silence. Refused instead.

                LDA ARGUMENT1+2         ; bit 16 belongs at bit 7
                AND #$0001
                .rept 7
                ASL A
                .next
                STA @l VID_A
                LDA ARGUMENT1
                .rept 9
                LSR A
                .next
                ORA @l VID_A

                setas
                STA @l VERA_L0_MAPBASE,X

                PLX
                PLP
                RETURN

tm_bad          PLX
                PLP
                THROW ERR_ARGUMENT
                .pend

;
; TILESET n, addr -- point a layer at its tile graphics.
;
S_TILESET       .proc
                PHP
                TRACE "S_TILESET"
                setaxl
                PHX

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                CALL LYR_SEL

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT

                LDA ARGUMENT1           ; 2 KB boundary
                AND #$07FF
                BNE ts_bad

                LDA ARGUMENT1+2
                AND #$0001
                .rept 7
                ASL A
                .next
                STA @l VID_A
                LDA ARGUMENT1
                .rept 9
                LSR A
                .next
                ORA @l VID_A

                setas
                AND #$FC
                STA @l VID_A+4
                LDA @l VERA_L0_TILEBASE,X
                AND #$03                ; the tile width and height share the
                ORA @l VID_A+4          ;  byte and belong to LAYERMODE
                STA @l VERA_L0_TILEBASE,X

                PLX
                PLP
                RETURN

ts_bad          PLX
                PLP
                THROW ERR_ARGUMENT
                .pend

;
; LAYERMODE n, cfg -- the layer configuration byte.
;
; Depth 1:0 (0 is text), bitmap 2, 256-colour text 3, map width 5:4 and
; height 7:6 as 32, 64, 128 or 256 tiles. The console is mode 0.
;
S_LAYERMODE     .proc
                PHP
                TRACE "S_LAYERMODE"
                setaxl
                PHX

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                CALL LYR_SEL

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setas
                LDA ARGUMENT1
                STA @l VERA_L0_CONFIG,X

                PLX
                PLP
                RETURN
                .pend

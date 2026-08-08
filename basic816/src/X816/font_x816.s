;;;
;;; The redefinable character set
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The console is VERA layer 0 and its font is ordinary VRAM the kernel
;;; filled at boot. There is NO character ROM, so unlike the C64 or the
;;; X16 there is no ROM number to select: a font is an ADDRESS, and
;;; anything you can write is a font.
;;;
;;; Layer 0's registers were read out of the emulator's video.c rather
;;; than assumed from the X16 -- $9F2D through $9F31, and the two that
;;; matter here are
;;;
;;;   $9F2E  map base, the address >> 9
;;;   $9F2F  tile base in bits 7:2, the address >> 11; bit 0 is the tile
;;;          width and bit 1 the height, which is why this is a
;;;          read-modify-write and not a store
;;;
;;; A font is 256 glyphs of 8 bytes = 2 KB on a 2 KB boundary, one byte
;;; per scanline, top first, bit 7 leftmost. Codes are CP437 and the
;;; tile index IS the character code -- no $20 bias, so 65 really is A.
;;; The kernel's font sits at $04000 with the tilemap below it, and
;;; $04800 is the next free slot.
;;;
;;; COPY BEFORE YOU EDIT. Editing the font at $04000 edits the one being
;;; drawn with, including the message telling you what went wrong. The
;;; safe order is FONTCOPY &h4000,&h4800 : CHARSET &h4800, and CHARSET
;;; &h4000 typed blind still puts it back.
;;;

;
; CHARSET addr -- point the console at a font.
;
; The address is stored shifted right eleven, so a font has to start on
; a 2 KB boundary; anything finer is silently rounded down by the
; hardware, which would be a baffling way to find out. It is refused
; here instead.
;
S_CHARSET       .proc
                PHP
                TRACE "S_CHARSET"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT

                LDA ARGUMENT1           ; a 2 KB boundary means the low
                AND #$07FF              ;  eleven bits are zero
                BNE cs_bad

                setal                   ; addr >> 9, then mask off bits 1:0,
                LDA ARGUMENT1+2         ;  which together are addr >> 11 sitting
                AND #$0001              ;  in bits 7:2 -- the layout the
                .rept 7                 ;  register wants.
                ASL A
                .next                   ; Bit 16 belongs at bit 7. XBA put it
                STA @l VID_A            ;  at bit 8, which the $FC mask below
                LDA ARGUMENT1           ;  then discarded: every font address
                .rept 9                 ;  at or above $10000 -- the whole
                LSR A                   ;  upper half of VRAM -- was silently
                .next                   ;  wrong, and both fonts the tests use
                ORA @l VID_A            ;  live below it.

                setas
                AND #$FC                ; keep the tile size bits below
                STA @l VID_A+4

                LDA @l VERA_L0_TILEBASE
                AND #$03                ; the width and height of a tile are
                ORA @l VID_A+4          ;  in the same byte and are not ours
                STA @l VERA_L0_TILEBASE

                PLP
                RETURN

cs_bad          PLP
                THROW ERR_ARGUMENT
                .pend

;
; CHARSETAT -- where the console is reading its font from.
;
; Takes no parentheses, which only became possible once the tokenizer
; could tell a no-argument function from a negation (tokens.s,
; TKPREVFN). It is what makes CHARSET recoverable from a program:
; save it, point somewhere else, put it back.
;
FN_CHARSETAT    .proc
                PHP
                setaxl

                setas
                LDA @l VERA_L0_TILEBASE
                AND #$FC
                setal
                AND #$00FF
                .rept 9                 ; the stored value is addr >> 9
                ASL A
                .next
                STA ARGUMENT1
                LDA #0
                ROL A                   ; the ninth shift carried out of bit 16
                STA ARGUMENT1+2

                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                PLP
                RETURN
                .pend

;
; Point the VRAM data port at glyph ARGUMENT1 of the font in VID_A.
;
; VID_A := font base + code*8, which cannot carry out of 17 bits for any
; font that fits in VRAM.
;
FNT_GLYPHAT     .proc
                PHP
                setal

                LDA ARGUMENT1
                AND #$00FF
                ASL A                   ; eight bytes a glyph
                ASL A
                ASL A
                CLC
                ADC @l VID_A
                STA @l VID_A
                LDA @l VID_A+2
                ADC #0
                STA @l VID_A+2

                CALL VRAM_PORT
                PLP
                RETURN
                .pend

;
; GLYPH addr, code, d0,d1,d2,d3,d4,d5,d6,d7 -- redefine one character.
;
; Eight bytes is a lot of arguments. It is also the only spelling that
; needs nothing else to exist: READ them from DATA in a loop and a whole
; alphabet is a dozen lines.
;
; All eight are collected BEFORE the VRAM port is pointed at anything,
; and only then written. The port is three registers of global state and
; EVALEXPR is a whole interpreter; holding an address latched in VERA
; across eight of them, plus whatever the cursor interrupt does, is
; asking for it. Nothing between FNT_GLYPHAT and the last store now.
;
S_GLYPH         .proc
                PHP
                TRACE "S_GLYPH"
                setaxl
                PHX

                CALL EVALEXPR           ; the font
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l VID_A
                LDA ARGUMENT1+2
                AND #$0001
                STA @l VID_A+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; the character code
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                STA @l FNT_CODE

                LDX #0                  ; eight scanlines, top first
gl_row          setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                setas
                LDA ARGUMENT1
                STA @l FNT_ROWS,X
                setal
                INX
                CPX #8
                BCC gl_row

                setal                   ; nothing runs between here and the
                LDA @l FNT_CODE         ;  last store, which is the point
                STA ARGUMENT1
                CALL FNT_GLYPHAT

                LDX #0
gl_out          setas
                LDA @l FNT_ROWS,X
                STA @l VERA_DATA0       ; the port auto-increments
                setal
                INX
                CPX #8
                BCC gl_out

                PLX
                PLP
                RETURN
                .pend

;
; FONTCOPY src, dst -- duplicate 2 KB of font.
;
; VERA has TWO address pointers with a data port each, selected by bit 0
; of $9F25, so this needs no buffer in main memory and no second pass:
; point port 0 at the source, port 1 at the destination, and the copy is
; a load and a store with both addresses stepping themselves.
;
S_FONTCOPY      .proc
                PHP
                TRACE "S_FONTCOPY"
                setaxl
                PHX

                CALL EVALEXPR           ; source
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l VID_A
                LDA ARGUMENT1+2
                AND #$0001
                STA @l VID_A+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; destination
                CALL ASS_ARG1_INT

                setas                   ; port 0 reads the source
                LDA #0
                STA @l VERA_CTRL
                LDA @l VID_A
                STA @l VERA_ADDR_L
                LDA @l VID_A+1
                STA @l VERA_ADDR_M
                LDA @l VID_A+2
                AND #$01
                ORA #$10                ; auto-increment 1
                STA @l VERA_ADDR_H

                setas                   ; port 1 writes the destination
                LDA #1                  ; bit 0 of CTRL is which port the
                STA @l VERA_CTRL        ;  address registers refer to
                LDA ARGUMENT1
                STA @l VERA_ADDR_L
                LDA ARGUMENT1+1
                STA @l VERA_ADDR_M
                LDA ARGUMENT1+2
                AND #$01
                ORA #$10
                STA @l VERA_ADDR_H

                setxl                   ; CTRL selects which address the
                LDX #2048               ;  ADDRESS registers refer to, but
fc_byte         setas                   ;  DATA0 always steps pointer 0 and
                LDA @l VERA_DATA0       ;  DATA1 always steps pointer 1 -- so
                STA @l VERA_DATA1       ;  the loop is two instructions and
                DEX                     ;  touches no register but the ports
                BNE fc_byte

                setas                   ; leave the port selection as found
                LDA #0
                STA @l VERA_CTRL

                PLX
                PLP
                RETURN
                .pend

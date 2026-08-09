
;;;
;;; BMX version 1 -- the X16's native bitmap file
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The format the X16 tools and Prog8 emit, which is the point of it:
;;; there is a supply of art and of converters already, and none of it
;;; is any use to a BASIC that cannot read the file.
;;;
;;;   offset  size  field
;;;   0-2     3     magic "BMX"
;;;   3       1     version (1)
;;;   4       1     bits per pixel
;;;   5       1     VERA colour depth code
;;;   6-7     2     width, little-endian
;;;   8-9     2     height
;;;   10      1     palette entries, 0 meaning 256
;;;   11      1     first palette index
;;;   12-13   2     file offset of the pixel data
;;;   14      1     compression, 0 = none
;;;   15      1     border colour
;;;
;;; The palette follows the header, two bytes an entry in VERA's own
;;; {G,B},{-,R} layout; the pixels follow the palette.
;;;
;;; PIXELS GO TO VRAM, CONTIGUOUSLY from the address given. The library
;;; version writes rows a settable stride apart so a narrow image can be
;;; stamped into a wider screen; that is a second argument nobody would
;;; pass and a 320-wide image -- which is the whole 320x240 bitmap --
;;; comes out identical either way.
;;;
;;; COMPRESSED FILES ARE REFUSED rather than half-read. Byte 14 is the
;;; only thing that says so, and a file whose pixels are packed would
;;; otherwise load as noise.
;;;

BMX_HDR         = 16            ; bytes before the palette

;
; A 16-bit field from the header at offset X.
;
BMX_WORD        .proc
                PHP
                setaxl
                setas
                LDA @l VIO_STAGE+1,X
                STA @l BMX_T+1
                LDA @l VIO_STAGE,X
                STA @l BMX_T
                setaxl
                LDA @l BMX_T
                PLP
                RETURN
                .pend

;
; Check the header. Throws rather than returning a code: a BASIC
; statement has one way to say no.
;
BMX_CHECK       .proc
                PHP
                setaxl

                LDA @l VIO_N+2              ; a file too short to hold a
                BNE ck_long                 ;  header is not one
                LDA @l VIO_N
                CMP #BMX_HDR
                BCC ck_bad
ck_long
                setas
                LDA @l VIO_STAGE            ; "BMX"
                CMP #'B'
                BNE ck_bad
                LDA @l VIO_STAGE+1
                CMP #'M'
                BNE ck_bad
                LDA @l VIO_STAGE+2
                CMP #'X'
                BNE ck_bad
                LDA @l VIO_STAGE+3          ; version 1 and nothing else
                CMP #1
                BNE ck_bad
                LDA @l VIO_STAGE+14         ; and uncompressed
                BNE ck_bad

                PLP
                RETURN
ck_bad          PLP
                THROW ERR_ARGUMENT
                .pend

;
; BMXLOAD file$, addr -- palette into the palette, pixels into VRAM.
;
S_BMXLOAD       .proc
                PHP
                TRACE "S_BMXLOAD"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_STR
                CALL SETFILEDESC

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; where the pixels go
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l BMX_VA
                LDA ARGUMENT1+2
                STA @l BMX_VA+2

                CALL VIO_LOAD               ; the whole file, and VIO_N
                CALL BMX_CHECK

                ; ---- the palette ----
                setaxl
                setas
                LDA @l VIO_STAGE+10         ; 0 means 256
                setal
                AND #$00FF
                BNE bl_pc
                LDA #256
bl_pc           STA @l BMX_PN

                setas
                LDA @l VIO_STAGE+11
                setal
                AND #$00FF
                ASL A                       ; two bytes an entry
                CLC
                ADC #<>VERA_PALETTE
                STA @l VIO_VA
                LDA #`VERA_PALETTE
                STA @l VIO_VA+2
                CALL VIO_PORT               ; auto-increment 1, from there

                setaxl
                LDA #BMX_HDR                ; the palette follows the header
                STA @l BMX_I
bl_pal          setaxl
                LDA @l BMX_PN
                BEQ bl_pixels
                LDA @l BMX_I
                TAX
                setas
                LDA @l VIO_STAGE,X
                STA @l VERA_DATA0
                setaxl
                LDA @l BMX_I
                INC A
                TAX
                setas
                LDA @l VIO_STAGE,X
                STA @l VERA_DATA0
                setaxl
                LDA @l BMX_I
                CLC
                ADC #2
                STA @l BMX_I
                LDA @l BMX_PN
                DEC A
                STA @l BMX_PN
                BRA bl_pal

                ; ---- the pixels ----
bl_pixels       setaxl
                LDX #12                     ; where they start in the file
                CALL BMX_WORD
                STA @l BMX_I

                SEC                         ; how many there are: whatever is
                LDA @l VIO_N                ;  left of the file
                SBC @l BMX_I
                STA @l BMX_N
                LDA @l VIO_N+2
                SBC #0
                STA @l BMX_N+2

                setal                       ; the VRAM address they go to
                LDA @l BMX_VA
                STA @l VIO_VA
                LDA @l BMX_VA+2
                STA @l VIO_VA+2
                CALL VIO_PORT

                setal                       ; MTEMP = the first pixel byte
                LDA #<>VIO_STAGE
                CLC
                ADC @l BMX_I
                STA MTEMP
                LDA #`VIO_STAGE
                ADC #0
                STA MTEMP+2

bl_copy         setal
                LDA @l BMX_N
                ORA @l BMX_N+2
                BEQ bl_done

                setas
                LDA [MTEMP]
                STA @l VERA_DATA0           ; the port steps itself
                setal

                INC MTEMP
                BNE bl_dec
                INC MTEMP+2

bl_dec          LDA @l BMX_N
                BNE bl_lo
                LDA @l BMX_N+2
                DEC A
                STA @l BMX_N+2
                LDA #$FFFF
                STA @l BMX_N
                BRA bl_copy
bl_lo           DEC A
                STA @l BMX_N
                BRA bl_copy

bl_done         PLP
                RETURN
                .pend

;
; BMXSAVE file$, addr, w, h -- write one back out, 8bpp.
;
; WIDTH AND HEIGHT ARE ARGUMENTS, and help/ADVANCED.TXT's sketch of this
; statement did not have them. It could not work without: nothing in
; VRAM says how big a picture is, and a save that guessed 320x240 would
; be wrong for every sprite sheet and tile page anybody wanted to keep.
;
; AND SO IS THE PALETTE RANGE, which is the argument that matters most.
; An entry nobody ever wrote does not read back as the colour in use
; (HELP PAL), so a save that took all 256 would write junk for every
; entry the program had not set -- and loading that file installs the
; junk FOR REAL, over the text palette, and the screen goes black. That
; is not a hypothesis: the first version of this statement defaulted to
; 256 and the test session that reloaded its own output came back with
; a blank screen. Naming the range is how a program says which entries
; are its own.
;
S_BMXSAVE       .proc
                PHP
                TRACE "S_BMXSAVE"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_STR
                CALL SETFILEDESC

                CALL GFX_COMMAARG           ; the VRAM address
                STA @l BMX_VA
                setal
                LDA ARGUMENT1+2
                STA @l BMX_VA+2
                CALL GFX_COMMAARG           ; width
                STA @l BMX_W
                CALL GFX_COMMAARG           ; height
                STA @l BMX_H
                CALL GFX_COMMAARG           ; the first palette entry
                STA @l BMX_PS
                CALL GFX_COMMAARG           ; and how many
                STA @l BMX_PN

                ; ---- the header ----
                setas
                LDA #'B'
                STA @l VIO_STAGE
                LDA #'M'
                STA @l VIO_STAGE+1
                LDA #'X'
                STA @l VIO_STAGE+2
                LDA #1                      ; version
                STA @l VIO_STAGE+3
                LDA #8                      ; bits per pixel
                STA @l VIO_STAGE+4
                LDA #3                      ; VERA's depth code for 8bpp
                STA @l VIO_STAGE+5
                setal
                LDA @l BMX_W
                STA @l BMX_T
                setas
                LDA @l BMX_T
                STA @l VIO_STAGE+6
                LDA @l BMX_T+1
                STA @l VIO_STAGE+7
                setal
                LDA @l BMX_H
                STA @l BMX_T
                setas
                LDA @l BMX_T
                STA @l VIO_STAGE+8
                LDA @l BMX_T+1
                STA @l VIO_STAGE+9
                setal                       ; the palette range asked for,
                LDA @l BMX_PN               ;  and 256 is written as 0
                AND #$00FF
                setas
                STA @l VIO_STAGE+10
                setal
                LDA @l BMX_PS
                setas
                STA @l VIO_STAGE+11
                setal                       ; where the pixels start: past
                LDA @l BMX_PN               ;  the header and this many
                ASL A                       ;  two-byte entries
                CLC
                ADC #BMX_HDR
                STA @l BMX_PX
                setas
                LDA @l BMX_PX
                STA @l VIO_STAGE+12
                LDA @l BMX_PX+1
                STA @l VIO_STAGE+13
                LDA #0                      ; uncompressed
                STA @l VIO_STAGE+14
                STA @l VIO_STAGE+15         ; border

                ; ---- the palette, straight out of VERA ----
                setal
                LDA @l BMX_PS
                ASL A
                CLC
                ADC #<>VERA_PALETTE
                STA @l VIO_VA
                LDA #`VERA_PALETTE
                STA @l VIO_VA+2
                CALL VIO_PORT

                setaxl
                LDA #BMX_HDR
                STA @l BMX_I
bs_pal          setaxl
                LDA @l BMX_I
                TAX
                setas
                LDA @l VERA_DATA0
                STA @l VIO_STAGE,X
                setaxl
                LDA @l BMX_I
                INC A
                STA @l BMX_I
                CMP @l BMX_PX
                BCC bs_pal

                ; ---- the pixels ----
                setal
                LDA @l BMX_VA
                STA @l VIO_VA
                LDA @l BMX_VA+2
                STA @l VIO_VA+2
                CALL VIO_PORT

                LDA @l BMX_W                ; w * h bytes, in 32 bits
                STA ARGUMENT1
                LDA #0
                STA ARGUMENT1+2
                LDA @l BMX_H
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                STA ARGTYPE2
                setal
                CALL OP_INT_MUL
                setaxl
                LDA ARGUMENT1
                STA @l BMX_N
                LDA ARGUMENT1+2
                STA @l BMX_N+2

                setal                       ; MTEMP = just past the palette
                LDA #<>VIO_STAGE
                CLC
                ADC @l BMX_PX
                STA MTEMP
                LDA #`VIO_STAGE
                STA MTEMP+2

bs_copy         setal
                LDA @l BMX_N
                ORA @l BMX_N+2
                BEQ bs_write

                setas
                LDA @l VERA_DATA0
                STA [MTEMP]
                setal

                INC MTEMP
                BNE bs_dec
                INC MTEMP+2

bs_dec          LDA @l BMX_N
                BNE bs_lo
                LDA @l BMX_N+2
                DEC A
                STA @l BMX_N+2
                LDA #$FFFF
                STA @l BMX_N
                BRA bs_copy
bs_lo           DEC A
                STA @l BMX_N
                BRA bs_copy

bs_write        setal                       ; header + palette + pixels
                LDA @l BMX_W
                STA ARGUMENT1
                LDA #0
                STA ARGUMENT1+2
                LDA @l BMX_H
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                STA ARGTYPE2
                setal
                CALL OP_INT_MUL
                setaxl
                CLC
                LDA ARGUMENT1
                ADC @l BMX_PX
                STA @l VIO_T
                LDA ARGUMENT1+2
                ADC #0
                STA @l VIO_T+2

                CALL VIO_SAVE

                PLP
                RETURN
                .pend

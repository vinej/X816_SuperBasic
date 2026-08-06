;;;
;;; X816-specific statements
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The token table (tokens.s) is unconditional, so every statement the
;;; C256 layer provided must exist here. Console statements are real
;;; (bound to the kernel); C256 video-hardware statements (sprites,
;;; tiles, bitmap) throw ERR_ARGUMENT until a VERA feature pass gives
;;; them X816 semantics.
;;;

;
; TEXTCOLOR fg, bg -- set the console text colors (0-15 each)
;
S_TEXTCOLOR     .proc
                PHP
                TRACE "S_TEXTCOLOR"

                CALL EVALEXPR       ; Get the foreground index
                CALL ASS_ARG1_BYTE  ; Assert that the result is a byte value

                setas
                LDA ARGUMENT1
                AND #$0F
                PHA                 ; Save the foreground color

                LDA #','            ; Check for the comma separator
                CALL EXPECT_TOK

                CALL EVALEXPR       ; Get the background index
                CALL ASS_ARG1_BYTE

                setaxl
                LDA ARGUMENT1       ; X = background
                AND #$000F
                TAX
                PLA                 ; C = foreground (8-bit push above)
                AND #$00FF
                JSL KERN_CON_COLOR

                PLP
                RETURN
                .pend

;
; LOCATE col, row -- position the cursor on the 80x60 console
;
S_LOCATE        .proc
                PHP
                TRACE "S_LOCATE"

                setaxl

                CALL EVALEXPR               ; Get the column
                CALL ASS_ARG1_BYTE          ; Make sure the value is a byte
                LDA ARGUMENT1
                PHA                         ; Save it for later

                LDA #','                    ; Check for the comma separator
                CALL EXPECT_TOK

                CALL EVALEXPR               ; Get the row
                CALL ASS_ARG1_BYTE          ; Make sure the value is a byte

                LDY ARGUMENT1               ; Y = the row
                PLX                         ; X = the column
                CALL CURSORXY

                PLP
                RETURN
                .pend

;
; Statements with no X816 implementation yet: report a bad argument
; rather than doing nothing silently. THROW aborts the statement, so
; there is no need to consume the argument list.
;
S_SETTIME       .proc
                THROW ERR_ARGUMENT
                .pend

S_SETDATE       .proc
                THROW ERR_ARGUMENT
                .pend

S_SETBGCOLOR    .proc
                THROW ERR_ARGUMENT
                .pend

S_SETBORDER     .proc
                THROW ERR_ARGUMENT
                .pend

S_SETCOLOR      .proc
                THROW ERR_ARGUMENT
                .pend

S_GRAPHICS      .proc
                THROW ERR_ARGUMENT
                .pend

S_BITMAP        .proc
                THROW ERR_ARGUMENT
                .pend

S_CLRBITMAP     .proc
                THROW ERR_ARGUMENT
                .pend

S_PLOT          .proc
                THROW ERR_ARGUMENT
                .pend

S_LINE          .proc
                THROW ERR_ARGUMENT
                .pend

S_FILL          .proc
                THROW ERR_ARGUMENT
                .pend

S_SPRITE        .proc
                THROW ERR_ARGUMENT
                .pend

S_SPRITEAT      .proc
                THROW ERR_ARGUMENT
                .pend

S_SPRITESHOW    .proc
                THROW ERR_ARGUMENT
                .pend

S_TILESET       .proc
                THROW ERR_ARGUMENT
                .pend

S_TILEMAP       .proc
                THROW ERR_ARGUMENT
                .pend

S_TILESHOW      .proc
                THROW ERR_ARGUMENT
                .pend

S_TILEAT        .proc
                THROW ERR_ARGUMENT
                .pend

S_MEMCOPY       .proc
                THROW ERR_ARGUMENT
                .pend

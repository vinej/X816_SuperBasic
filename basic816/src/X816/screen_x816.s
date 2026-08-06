;;;
;;; X816 screen routines (kernel console + VERA text matrix)
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;

;
; Ensure that text mode is enabled.
; The X816 kernel console owns the display; nothing to do.
;
ENSURETEXT  .proc
            RETURN
            .pend

;
; Send the character in A to the screen.
;
; The X816 console interprets only $08 BS, $0A LF, $0D CR — and $0D is
; carriage-return-ONLY (column 0, same row). BASIC uses CR as its line
; terminator, so translate CR -> LF here (the DurexForth lesson: without
; this the REPL overprints one row forever). BS is echoed as BS,SP,BS so
; the erased character disappears from the text matrix — SCRCOPYLINE
; reads the matrix back, so the erase is what makes editing work.
;
; Inputs:
;   A = the character to print
;
SCREEN_PUTC .proc
            PHP
            PHB
            setaxl
            PHA
            PHX
            PHY

            AND #$00FF              ; The hidden high byte of A is not zero
            CMP #CHAR_CR
            BNE not_cr
            LDA #CHAR_LF            ; CR means "next line" in BASIC
not_cr      CMP #CHAR_BS
            BEQ do_bs

            JSL KERN_CON_PUTC

done        setaxl
            PLY
            PLX
            PLA
            PLB
            PLP
            RETURN

do_bs       LDA #CHAR_BS            ; Erasing backspace: BS, space, BS
            JSL KERN_CON_PUTC
            LDA #CHAR_SP
            JSL KERN_CON_PUTC
            LDA #CHAR_BS
            JSL KERN_CON_PUTC
            BRA done
            .pend

;
; Put the cursor at the start of a line, emitting a newline only if it
; is not already in column 0.
;
; SuperBasic shows no READY banner, so nothing is written between one
; line and the next -- which only works if output reliably ends with a
; newline, and it does not: the error printer leaves the cursor sitting
; after "Syntax error". The old banner began with a CR and quietly
; covered that. Without a check the next line is typed onto the tail of
; the message and SCRCOPYLINE, which reads the row back from the text
; matrix, hands the tokenizer "Syntax error   PRINT 10/4" -- so every
; command after an error became an error itself.
;
; The console owns the cursor, so ask it rather than tracking a column
; here that could drift from the kernel's.
;
ATCOL0      .proc
            PHP
            PHB
            setaxl
            PHA
            PHX
            PHY

            JSL KERN_CON_GETXY      ; C = column, X = row
            AND #$00FF
            BEQ done                ; Already at the left margin

            CALL PRINTCR

done        setaxl
            PLY
            PLX
            PLA
            PLB
            PLP
            RETURN
            .pend

;
; UART output: the X816 has no serial port. The BCONSOLE device mask
; never enables DEV_UART on this platform, but bios.s still assembles a
; call site, so provide a no-op.
;
UART_PUTC   .proc
            RETURN
            .pend

;
; Show or hide the cursor
;
; Inputs:
;   A = cursor visibility. 0 = hide, any other value = show
;
ISHOWCURSOR .proc
            PHP
            PHB
            setaxl
            PHA
            PHX
            PHY

            AND #$00FF
            BEQ hide
            LDA #1
hide        JSL KERN_CON_CURSOR

            setaxl
            PLY
            PLX
            PLA
            PLB
            PLP
            RETURN
            .pend

;
; Set the location of the cursor
;
; Inputs:
;   X = the column of the cursor
;   Y = the row of the cursor
;
ICURSORXY   .proc
            PHP
            PHB
            setaxl
            PHA
            PHX
            PHY

            TXA                     ; C = column
            AND #$00FF
            PHA
            TYA                     ; X = row
            AND #$00FF
            TAX
            PLA
            JSL KERN_CON_GOTOXY

            setaxl
            PLY
            PLX
            PLA
            PLB
            PLP
            RETURN
            .pend

;
; Clear the screen and move the cursor to the home position
;
ICLSCREEN   .proc
            PHP
            PHB
            setaxl
            PHA
            PHX
            PHY

            JSL KERN_CON_CLS
            LDA #0                  ; Home the cursor explicitly
            LDX #0
            JSL KERN_CON_GOTOXY

            setaxl
            PLY
            PLX
            PLA
            PLB
            PLP
            RETURN
            .pend

;
; Copy the line the user just entered on the screen to INPUTBUF.
; Trim whitespace from the end to make the input buffer null-terminated.
;
; Called right after the CR echo, so the line to copy is the row ABOVE
; the cursor (the LF echo moved the cursor down; if the screen scrolled,
; the typed line also moved up one row, so row-1 is right either way).
;
; The kernel has no "read character at (x,y)" call, so this reads the
; VERA text matrix directly: 1bpp tile map at VRAM $00000, map width
; 128, cell = (glyph, attribute) -> VRAM address of (col,row) is
; row*256 + col*2. Glyphs are CP437 = ASCII identity, so the byte read
; IS the character. Data port 0 with auto-increment 2 skips attributes.
; (The kernel cursor handler uses port 1 and restores state, so port 0
; is ours to use outside interrupts.)
;
ISCRCPYLINE .proc
            PHX
            PHY
            PHB
            PHP
            setaxl

            JSL KERN_CON_GETXY      ; C = column, X = row
            TXA
            DEC A                   ; The row above the cursor
            BPL row_ok
            LDA #0                  ; Clamp (cannot happen after a CR echo)

row_ok      setas
            STA @l VERA_ADDR_M      ; VRAM address = row * 256
            LDA #0
            STA @l VERA_CTRL        ; Select address port 0
            STA @l VERA_ADDR_L
            LDA #$20                ; Auto-increment 2 (skip attributes), bank 0
            STA @l VERA_ADDR_H

            setxl
            LDX #0
copy_loop   LDA @l VERA_DATA0       ; Read one glyph from the text matrix
            STA @l INPUTBUF,X
            INX
            CPX #80                 ; The console is 80 columns wide
            BNE copy_loop

            LDA #0                  ; Ensure the buffer is terminated
            STA @l INPUTBUF+80

            LDX #79
trim_loop   LDA @l INPUTBUF,X       ; Replace trailing spaces with NULs
            CMP #CHAR_SP
            BNE done

            LDA #0
            STA @l INPUTBUF,X

            DEX
            BPL trim_loop

done        PLP
            PLB
            PLY
            PLX
            RETURN
            .pend

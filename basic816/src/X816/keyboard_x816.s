;;;
;;; X816 keyboard routines (kernel console input)
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; Kernel key events are 16-bit: $0001-$00FF is a CP437/ASCII
;;; character (Enter = $0D, Backspace = $08), $0100|n is a key with no
;;; character (arrows, F-keys). GETKEY drops those, because a statement
;;; asking for a character has nothing to do with an arrow; the LINE
;;; EDITOR takes them instead, in EDITKEY at the bottom of this file.
;;;

; IBM key position numbers for the keys with no character, from
; X816_Calypsi runtime/console.h. The emulator's own SDL mapping
; (src/keyboard.c) agrees, which is the second source that says these
; are right rather than plausible.
KEYN_INS        = 75
KEYN_DEL        = 76
KEYN_LEFT       = 79
KEYN_HOME       = 80
KEYN_END        = 81
KEYN_RIGHT      = 89

;
; Get a character from the keyboard.
; Blocks if there are no keys in the buffer.
;
; Outputs:
;   A = the key read
;
IGETKEY         .proc
                PHX
                PHY
                PHB
                PHD
                PHP
                setaxl

wait            JSL KERN_CON_GETC       ; Blocking key read
                BCS wait                ; Kernel error: keep waiting
                CMP #0
                BEQ wait
                CMP #KEY_SPECIAL        ; Ignore keys with no character
                BGE wait

                PLP                     ; A low byte carries the character out
                PLD
                PLB
                PLY
                PLX
                RETURN
                .pend

;
; Get a character from the keyboard and echo it to the screen.
; Blocks if there are no keys in the buffer.
;
; The echo goes through PRINTC, so CR becomes a newline and BS erases
; on screen (see SCREEN_PUTC) — which is exactly what the screen-editor
; REPL needs, since SCRCOPYLINE reads the edited line back from the
; text matrix.
;
; Outputs:
;   A = the key read
;
GETKEYE         .proc
                PHX
                PHY
                PHB
                PHD
                PHP

                CALL GETKEY             ; Blocking read (character keys only)

                setas
                PHA
                CMP #CHAR_BS            ; Echo backspace, CR and printables;
                BEQ echo                ; swallow other control characters
                CMP #CHAR_CR
                BEQ echo
                CMP #CHAR_SP
                BLT no_echo

echo            CALL PRINTC
no_echo         PLA

                PLP                     ; A low byte carries the character out
                PLD
                PLB
                PLY
                PLX
                RETURN
                .pend

;
; Read a line of text from the user into IOBUF (single-line editor for
; the INPUT statement). Adapted from the C256 version minus the lock
; keys; the logic is otherwise identical.
;
IINPUTLINE      .proc
                PHP
                TRACE "IINPUTLINE"

                setxl
                setas
                LDA @lBCONSOLE      ; Redirected by INPUT #? Take the line
                AND #DEV_CHANNEL    ;  off the channel and do not touch the
                BEQ il_keyboard     ;  keyboard or the cursor at all.
                setal
                CALL CHN_GETLINE
                PLP
                RETURN

il_keyboard     setas
                LDA #1              ; Show the cursor
                CALL SHOWCURSOR

                ; Zero out the input buffer
                LDX #0
                LDA #0
zero_loop       STA @lIOBUF,X
                INX
                CPX #$100
                BNE zero_loop

                LDX #0
getchar         CALL GETKEY         ; Get a keypress
                CMP #CHAR_CR        ; Got a CR?
                BNE not_cr
                JMP endofline       ; Yes: we're done

not_cr          CMP #CHAR_BS        ; Is it a backspace?
                BNE not_bs

                CPX #0              ; Are we at the beginning of the line?
                BEQ getchar         ; Yes: ignore the backspace

                PHX                 ; Save the cursor position
clr_loop        LDA @lIOBUF+1,X     ; Get the character above
                STA @lIOBUF,X       ; Save it to the current position
                BEQ done_clr        ; If we copied a NUL, we're done copying
                INX                 ; Otherwise, keep copying down
                CPX #$FF            ; Until we're at the end of the buffer
                BNE clr_loop
done_clr        PLX                 ; Restore the cursor position

                DEX                 ; Move the cursor left
                BRA print_bs        ; And print the backspace

not_bs          CMP #$20            ; Is it in range 00 -- 1F?
                BLT getchar         ; Yes: ignore it

                ; A regular printable key was found
                STA @lIOBUF,X       ; Save it to the input buffer
                INX                 ; Move the cursor forward

echo            CALL PRINTC         ; Print the character
                BRA getchar         ; And get another...

print_bs        LDA #CHAR_BS        ; Backspace character...
                CALL PRINTC         ; Print it (erasing on screen)
                BRA getchar         ; And get another...

endofline       LDA #0              ; Hide the cursor
                CALL SHOWCURSOR

                PLP
                RETURN
                .pend

;;;
;;; The line editor's keys.
;;;
;;; SuperBasic edits the SCREEN, not a buffer: IREADLINE echoes what is
;;; typed and ISCRCPYLINE reads the finished row back out of the text
;;; matrix. That is why moving the cursor is the whole of an arrow key
;;; here -- put it in the middle of a line, type, and the row that gets
;;; tokenized is the row as it now looks. No buffer has to be kept in
;;; step with the display, because the display IS the buffer.
;;;
;;; So typing OVERWRITES, as it does on the machines this borrows from,
;;; and INSERT and DELETE are the two things that cannot be had that
;;; way: they open and close a gap by shifting the row itself.
;;;
;;; A LINE IS ONE ROW. ISCRCPYLINE copies 80 columns of the row above
;;; the cursor and nothing else, so LEFT stops at the left margin
;;; instead of wrapping, and up and down are left alone -- there is no
;;; second row to go to, and no history buffer for them to mean
;;; anything else.
;;;

;
; Where the cursor is, parked where a routine that has just called
; another one can still find it.
;
; Outputs:
;   ED_COL, ED_ROW
;
ED_POS      .proc
            PHP
            setaxl                  ; Widths BEFORE the pushes, so the
            PHA                     ;  pulls below cannot disagree with
            PHX                     ;  a caller that was 8-bit
            JSL KERN_CON_GETXY      ; A = column, X = row, both already
            STA @l ED_COL           ;  masked to a byte by the kernel
            TXA
            STA @l ED_ROW
            PLX
            PLA
            PLP
            RETURN
            .pend

;
; Read the row the cursor is on into IOBUF, 80 bytes.
;
; The same access ISCRCPYLINE uses and for the same reasons: 1bpp map at
; VRAM $00000, 128 cells wide, cell = (glyph, attribute), so (col,row)
; is at row*256 + col*2, and auto-increment 2 walks glyphs only.
;
; STEPPING OVER THE ATTRIBUTES IS WHAT MAKES THIS SAFE WITH THE CURSOR
; ON. The blink is a VSYNC handler (X816_Calypsi ccursor.s) that draws
; by writing a reversed ATTRIBUTE and never touches a glyph, so the row
; read here cannot contain a cursor and the row written back cannot rub
; one out. It uses VERA port 1 and restores it; port 0 is ours.
;
; IOBUF belongs to the INPUT statement, which cannot be running: this is
; reached only from the READY prompt, where no program is executing and
; no deferred handler can be entered.
;
; Inputs:
;   ED_ROW
;
ED_RDROW    .proc
            PHP
            setaxl                  ; Widths BEFORE the pushes, so the
            PHA                     ;  pulls below cannot disagree with
            PHX                     ;  a caller that was 8-bit
            LDA @l ED_ROW
            setas
            STA @l VERA_ADDR_M      ; VRAM address = row * 256
            LDA #0
            STA @l VERA_CTRL        ; Select address port 0
            STA @l VERA_ADDR_L
            LDA #$20                ; Auto-increment 2, bank 0
            STA @l VERA_ADDR_H

            setxl
            LDX #0
rd_loop     LDA @l VERA_DATA0
            STA @l IOBUF,X
            INX
            CPX #80
            BNE rd_loop

            setaxl
            PLX
            PLA
            PLP
            RETURN
            .pend

;
; Write IOBUF's 80 bytes back over the row the cursor is on.
;
; Inputs:
;   ED_ROW, IOBUF
;
ED_WRROW    .proc
            PHP
            setaxl                  ; Widths BEFORE the pushes, so the
            PHA                     ;  pulls below cannot disagree with
            PHX                     ;  a caller that was 8-bit
            LDA @l ED_ROW
            setas
            STA @l VERA_ADDR_M
            LDA #0
            STA @l VERA_CTRL
            STA @l VERA_ADDR_L
            LDA #$20
            STA @l VERA_ADDR_H

            setxl
            LDX #0
wr_loop     LDA @l IOBUF,X
            STA @l VERA_DATA0
            INX
            CPX #80
            BNE wr_loop

            setaxl
            PLX
            PLA
            PLP
            RETURN
            .pend

;
; Open or close a gap in the row the cursor is on.
;
; A proc of its own rather than two more arms of EDITKEY's dispatch,
; because together they are half its size and the branches out of that
; dispatch have to reach every arm -- 65816 conditional branches carry
; a signed byte, and the first version of this did not assemble.
;
; Inputs:
;   A = KEYN_INS or KEYN_DEL
;
ED_SHIFT    .proc
            PHP
            setaxl
            PHA
            PHX
            PHY

            CMP #KEYN_DEL
            BEQ del

            ; INSERT: the row moves right from the cursor and whatever
            ; stood in column 79 falls off the end, which is the only
            ; place it can go on a row that is the whole line.
            CALL ED_POS
            CALL ED_RDROW
            setaxl
            LDA #79
            SEC
            SBC @l ED_COL           ; How many cells have to move
            BEQ ins_gap             ; On the last column: nothing to shift
            TAY
            LDX #79
            setas
ins_loop    LDA @l IOBUF-1,X
            STA @l IOBUF,X
            DEX
            DEY
            BNE ins_loop

ins_gap     setaxl
            LDA @l ED_COL
            TAX
            setas
            LDA #CHAR_SP
            STA @l IOBUF,X
            BRA write

            ; DELETE closes one, and a space arrives at the far end.
del         CALL ED_POS
            CALL ED_RDROW
            setaxl
            LDA #79
            SEC
            SBC @l ED_COL
            BEQ del_pad
            TAY
            LDA @l ED_COL
            TAX
            setas
del_loop    LDA @l IOBUF+1,X
            STA @l IOBUF,X
            INX
            DEY
            BNE del_loop

del_pad     setas
            LDA #CHAR_SP
            STA @l IOBUF+79

write       CALL ED_WRROW

            setaxl
            PLY
            PLX
            PLA
            PLP
            RETURN
            .pend

;
; Read one key FOR THE LINE EDITOR.
;
; A character comes back exactly as GETKEYE returns it, echo and all. A
; key with no character does its work here and comes back as ZERO, which
; IREADLINE already treats as "nothing yet" -- so the editor gains six
; keys without gaining a state machine.
;
; Outputs:
;   A (low byte) = the character, or 0 if a special key was handled
;
EDITKEY     .proc
            PHX
            PHY
            PHB
            PHD
            PHP
            setaxl

wait        JSL KERN_CON_GETC       ; Blocking key read
            BCS wait                ; Kernel error: keep waiting
            CMP #0
            BEQ wait
            CMP #KEY_SPECIAL
            BGE special

            setas                   ; A character: echo it as GETKEYE does,
            PHA                     ;  since this stands in for that call
            CMP #CHAR_BS
            BEQ echo
            CMP #CHAR_CR
            BEQ echo
            CMP #CHAR_SP
            BLT no_echo
echo        CALL PRINTC
no_echo     PLA

done        PLP                     ; A low byte carries the character out
            PLD
            PLB
            PLY
            PLX
            RETURN

            ; ---- a key with no character ------------------------------
            ;
            ; setaxl is NOT redundant. The CPU gets here from BGE with
            ; 16-bit registers, but the assembler reads the file in
            ; order and the line above it is the 8-bit echo path -- so
            ; without this the mask below assembles as AND #$FF, the
            ; CPU eats the next byte as an operand and runs the rest of
            ; the dispatch off its rails. That is the same bug, in the
            ; same shape, that made TOKAT execute a BRK.
special     setaxl
            AND #$00FF              ; The IBM key position
            CMP #KEYN_LEFT
            BEQ k_left
            CMP #KEYN_RIGHT
            BEQ k_right
            CMP #KEYN_HOME
            BEQ k_home
            CMP #KEYN_END
            BEQ k_end
            CMP #KEYN_INS
            BEQ k_shift
            CMP #KEYN_DEL
            BEQ k_shift
            BRA none                ; Everything else still does nothing

k_shift     CALL ED_SHIFT           ; A is still the key position
            BRA none

move        setaxl
            LDA @l ED_ROW
            TAX
            LDA @l ED_COL
            JSL KERN_CON_GOTOXY

none        setaxl                  ; Handled: no character for the caller
            LDA #0
            BRA done

k_left      CALL ED_POS
            setaxl
            LDA @l ED_COL
            BEQ none                ; At the left margin: a line is one row
            DEC A
            STA @l ED_COL
            BRA move

k_right     CALL ED_POS
            setaxl
            LDA @l ED_COL
            CMP #79
            BGE none                ; The last column the row has
            INC A
            STA @l ED_COL
            BRA move

k_home      CALL ED_POS
            setaxl
            LDA #0
            STA @l ED_COL
            BRA move

            ; END is one past the last glyph, which needs the row read to
            ; find -- the console knows where the cursor is, not where the
            ; text stops.
k_end       CALL ED_POS
            CALL ED_RDROW
            setas
            setxl
            LDX #79
end_scan    LDA @l IOBUF,X
            CMP #CHAR_SP
            BNE end_found
            DEX
            BPL end_scan            ; X = $FFFF once the row is all blank
end_found   INX
            CPX #80
            BLT end_ok
            LDX #79                 ; A full row: sit on its last column
end_ok      setaxl
            TXA
            STA @l ED_COL
            BRA move
            .pend

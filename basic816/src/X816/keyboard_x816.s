;;;
;;; X816 keyboard routines (kernel console input)
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; Kernel key events are 16-bit: $0001-$00FF is a CP437/ASCII
;;; character (Enter = $0D, Backspace = $08), $0100|n is a key with no
;;; character (arrows, F-keys). Phase 1 ignores special keys; a later
;;; pass maps arrows for full-screen editing.
;;;

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

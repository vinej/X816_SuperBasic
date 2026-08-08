;;;
;;; BASIC for the 65816 processor
;;;

.cpu "65816"

.include "constants.s"
.include "memorymap.s"
.include "macros.s"

.section code

;;
;; Jump table 

COLDBOOT        JML START               ; Entry point to boot up BASIC from scratch
.if SYSTEM != SYSTEM_X816
MONITOR         JML IMONITOR            ; Entry point to the machine language monitor
.endif

;;
;; I/O hooks... these could be replaced by an external system
;;

READLINE        JML IREADLINE           ; Wait for the user to enter a line of text (for programming input)
SCRCOPYLINE     JML ISCRCPYLINE         ; Copy the line on the screen the user just input to INPUTBUF
INPUTLINE       JML IINPUTLINE          ; Read a single line of text from the user, and copy it to TEMPBUF (for INPUT statement)
GETKEY          JML IGETKEY             ; Wait for a keypress by the user and return the ASCII code in A
PRINTC          JML IPRINTC             ; Print the character in A to the console
SHOWCURSOR      JML ISHOWCURSOR         ; Set cursor visibility: A=0, hide... A<>0, show.
CURSORXY        JML ICURSORXY           ; Set the position of the cursor to (X, Y)
CLSCREEN        JML ICLSCREEN           ; Clear the screen

;;
;; A mess o' includes...
;;

;.include "bootstrap.s"

.include "bios.s"
.include "utilities.s"
.include "tokens.s"
.include "heap.s"
.include "strings.s"
.include "listing.s"
.include "eval.s"
.include "returnstack.s"
.include "interpreter.s"
.include "repl.s"
.include "operators.s"
.include "statements.s"
.include "functions.s"
.include "superbasic.s"          ; the SuperBasic language layer
.if SYSTEM == SYSTEM_X816
.include "X816/channels_x816.s"  ; record I/O: OPEN, CLOSE, PRINT #, INPUT #
.include "X816/audio_x816.s"     ; VERA PCM and the YM2151
.include "X816/input_x816.s"     ; joystick, I2C, mouse
.include "X816/font_x816.s"      ; the redefinable character set
.include "X816/graphics_x816.s"  ; bitmap drawing on VERA2
.endif
.include "commands.s"
.include "variables.s"
.include "integers.s"
.include "floats.s"
.if SYSTEM == SYSTEM_X816
.include "X816/transcendentals_x816.s"
.else
.include "transcendentals.s"
.endif
.include "arrays.s"
.include "dos.s"

.if SYSTEM != SYSTEM_X816
; The machine-language monitor and the inline assembler. NOT built for
; SuperBasic: a BASIC for this machine does not need a 65816 monitor,
; and between them they held about a fifth of the direct page -- which
; is a single 256-byte page, was full, and is what every new feature
; needs a few bytes of. See PORT.md section 19.
;
; Kept for the other targets so the C256 build still reproduces stock.
.include "monitor.s"
.endif

.if UNITTEST
.include "tests/basictests.s"
.endif

START       CLC                 ; Go to native mode
            XCE

            setdp GLOBAL_VARS
            setdbr BASIC_BANK

            setaxl
            CALL INITBASIC

.if SYSTEM == SYSTEM_X816
            ; K_EXEC hands over with interrupts masked and the shell never
            ; re-enables them. This has to sit outside every PHP/PLP pair
            ; -- INITIO and INITBASIC both bracket themselves, so a CLI
            ; inside either is restored away before it takes effect. With
            ; IRQs masked the kernel's VSYNC handler never runs and the
            ; console has no cursor at all.
            CLI
.endif

            LDA #STACK_END      ; Set the system stack
            TCS

            ; Clear the screen and print the welcome message
            ; CALL CLSCREEN

            setdbr `GREET
            LDX #<>GREET
            CALL PRINTS
            setdbr BASIC_BANK

            ; setaxl
            ; LDA #<>WAIT         ; Send subsquent restarts to the WAIT loop
            ; STA RESTART

.if UNITTEST
            CALL TST_BASIC      ; Run the BASIC816 unit tests
.else
            ; BRK
            ; NOP
            JMP INTERACT        ; Start accepting input from the user
.endif

WAIT        JMP WAIT

INITBASIC   .proc
            PHP

            CALL INITIO         ; Initialize I/O system
            CALL CMD_NEW        ; Clear the program

            PLP
            RETURN
            .pend
.send

.section data
.if SYSTEM == SYSTEM_X816
GREET       .text "X816 SuperBasic (BASIC816) "
.else
GREET       .text "C256 Foenix BASIC816 "
.endif
            .include "version.s"
            .byte 13,0
.send

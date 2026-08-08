;;;
;;; Top-level BASIC commands
;;;

;
; Enter the monitor
;
; Not on the X816: the monitor and the inline assembler are not built
; there (basic816.s), and BRK would drop into the kernel's handler with
; nothing waiting to catch it. The keyword stays reserved and refuses --
; deleting the token would renumber every one after it, and a
; zero-length record in its place would TERMINATE the table walk
; (TKNEXTBIG), quietly unmaking every keyword that follows.
;
.if SYSTEM == SYSTEM_X816
CMD_MONITOR     .proc
                THROW ERR_SYNTAX
                .pend
.else
CMD_MONITOR     BRK
                NOP
                RETURN
.endif

;;;
;;; AUTO -- number the lines as they are typed
;;;
;;; It needs no editor and no input machinery of its own, which is why it
;;; could be written before either exists: the REPL reads a line by
;;; letting the user type on the console and then COPYING THE WHOLE
;;; CONSOLE LINE into the input buffer. So printing the number first is
;;; the entire trick -- it arrives in the buffer as though it had been
;;; typed, and everything downstream is unchanged.
;;;
;;; Press RETURN on a line with nothing but the number to stop. That is
;;; what a person will try, and the alternative is worse than useless: an
;;; empty numbered line DELETES that line, so a beginner leaving AUTO the
;;; obvious way would silently remove the line they had just written.
;;;

;
; AUTO [start [, step]] -- 10, 10 by default. AUTO 0 switches it off.
;
CMD_AUTO        .proc
                PHP
                TRACE "CMD_AUTO"
                setaxl

                LDA #10
                STA @l AUTO_NEXT
                STA @l AUTO_STEP

                CALL SKIPWS
                setas
                LDA [BIP]
                BEQ au_on                   ; AUTO on its own
                CMP #':'
                BEQ au_on

                setaxl
                CALL EVALEXPR               ; where to start
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l AUTO_NEXT
                BNE au_step

                setas                       ; AUTO 0: stop
                LDA #0
                STA @l AUTO_ON
                PLP
                RETURN

au_step         setas
                LDA #','
                STA TARGETTOK
                CALL OPT_TOK
                BCC au_on
                CALL INCBIP

                setaxl
                CALL EVALEXPR               ; and by how much
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                BEQ au_bad                  ; a step of nothing never ends
                STA @l AUTO_STEP

au_on           setas
                LDA #1
                STA @l AUTO_ON
                PLP
                RETURN
au_bad          THROW ERR_ARGUMENT
                .pend

;
; Put the next number on the screen, if AUTO is on.
;
AUTO_PROMPT     .proc
                PHP
                setaxl

                setas
                LDA @l AUTO_ON
                BEQ ap_done

                setal
                LDA @l AUTO_NEXT
                STA ARGUMENT1
                LDA #0
                STA ARGUMENT1+2
                CALL PR_INTEGER
                setas
                LDA #CHAR_SP
                CALL PRINTC

                setal                       ; advance even if the line is
                CLC                         ;  abandoned, which is what every
                LDA @l AUTO_NEXT            ;  BASIC that has this does
                ADC @l AUTO_STEP
                STA @l AUTO_NEXT

ap_done         setaxl
                PLP
                RETURN
                .pend

;
; Nothing after the number means the user is finished.
;
AUTO_CHECK      .proc
                PHP
                setaxl
                PHX

                setas
                LDA @l AUTO_ON
                BEQ ac_done

                setaxl
                LDX #0
ac_scan         setas
                LDA @l INPUTBUF,X
                BEQ ac_stop                 ; ran out: only a number was there
                CMP #CHAR_SP
                BEQ ac_next
                CALL ISNUMERAL
                BCC ac_done                 ; something real on the line
ac_next         setaxl
                INX
                CPX #80
                BCC ac_scan

ac_stop         setas                       ; switch off, and leave nothing
                LDA #0                      ;  for the line to do -- an empty
                STA @l AUTO_ON              ;  numbered line would DELETE the
                STA @l INPUTBUF             ;  line it names

ac_done         setaxl
                PLX
                PLP
                RETURN
                .pend

;
; Clear the program area and all variables
;
CMD_NEW         .proc
                PHP
                TRACE "CMD_NEW"
                PHD

                setdp GLOBAL_VARS

                setaxl

                LD_L LASTLINE,BASIC_BOT     ; Delete all lines

                setaxl
                LDA #0
                LDY #LINE_LINK
                STA [LASTLINE],Y
                LDY #LINE_NUMBER
                STA [LASTLINE],Y
                LDY #LINE_TOKENS
                STA [LASTLINE],Y

                CALL CLRINTERP              ; Set the interpreter state to the default

                PLD
                PLP
                RETURN
                .pend

;
; Attempt to run a program
;
CMD_RUN         .proc
                PHB
                PHP

                TRACE "CMD_RUN"

                setal
                LDA #<>BASIC_BOT            ; Point to the first line of the program
                STA CURLINE
                LDA #`BASIC_BOT
                STA CURLINE + 2

                CALL CLRINTERP              ; Set the interpreter state to the default
                CALL EXECPROGRAM

                PLP
                PLB
                RETURN
                .pend

;
; List the program
;
CMD_LIST        .proc
                PHP
                TRACE "CMD_LIST"

                setal

                STZ MARG1               ; MARG1 is starting line number, default 0

                LDA #$7FFF
                STA MARG2               ; MARG2 is ending line number, default MAXINT

                CALL PRINTCR

                CALL PEEK_TOK
                AND #$00FF
                CMP #0                  ; If no arguments...
                BEQ call_list           ; ... just list with the defaults
                CMP #TOK_MINUS          ; If just "- ###"...
                BEQ parse_endline       ; ... try to parse the end line number

                CALL SKIPWS
                CALL PARSEINT           ; Try to get the starting line
                LDA ARGUMENT1           ; And save it to MARG1
                STA MARG1

                CALL PEEK_TOK
                AND #$00FF
                CMP #0                  ; If no arguments...
                BEQ call_list           ; ... just list with the defaults
                CMP #TOK_MINUS
                BNE error               ; At this point, if not '-', it's a syntax error
          
parse_endline   CALL EXPECT_TOK         ; Try to eat the '-'

                CALL SKIPWS
                CALL PARSEINT           ; Try to get the ending line
                LDA ARGUMENT1           ; And save it to MARG2
                STA MARG2

call_list       LDA CURLINE+2           ; Save CURLINE
                PHA
                LDA CURLINE
                PHA

                LDA BIP+2               ; Save BIP
                PHA
                LDA BIP
                PHA


                CALL LISTPROG

                PLA
                STA BIP
                PLA
                STA BIP+2

                PLA
                STA CURLINE
                PLA
                STA CURLINE+2

                PLP
                RETURN
error           THROW ERR_SYNTAX        ; Throw a syntax error
                .pend


;;;
;;; Core BASIC Statements
;;;

.if SYSTEM == SYSTEM_C256
.include "C256/statements_c256.s"
.elsif SYSTEM == SYSTEM_X816
.include "X816/statements_x816.s"
.endif

;
; Read a line of input from the keyboard and assign it to the variable
; INPUT <variable>
S_INPUT         .proc
                PHP
                TRACE "S_INPUT"

.if SYSTEM == SYSTEM_X816
                setas               ; INPUT #n, ... reads from a channel
                CALL PEEK_TOK
                CMP #'#'
                BNE in_console
                setal
                CALL S_INPUTCH
                PLP
                RETURN
in_console
.endif

varloop         CALL SKIPWS

                setas
                LDA [BIP]
                BNE check_colon
                JMP done            ; If EOL, we're done
check_colon     CMP #':'
                BNE check_string
                JMP done            ; If colon, we're done

check_string    CMP #CHAR_DQUOTE    ; Is it the start of a string?
                BNE check_var       ; No: then it should be a variable name

                CALL EVALSTRING     ; Parse the string
                CALL PR_STRING      ; Pring the string

                LDA #';'            ; Look for a semicolon
                CALL EXPECT_TOK

check_var       CALL ISALPHA        ; Check to see if it's the start of a variable
                BCC syntax_err      ; No: it's a syntax error

                CALL VAR_FINDNAME   ; Try to find the variable name
                BCC syntax_err      ; If we didn't get a variable, throw a syntax error

                LDA #"?"            ; Print a "? " to follow
                CALL PRINTC
                LDA #CHAR_SP
                CALL PRINTC

                CALL INPUTLINE      ; Get a line of keyboard input

                setas
                LDA TOFINDTYPE      ; Check the type of the variable
                CMP #TYPE_STRING    ; If it's a string...
                BEQ in_string       ; ... go to copy the string data

                CMP #TYPE_INTEGER   ; If it's an integer...
                BNE chk_float
                BRL in_integer      ; ... go to parse the integer

chk_float       CMP #TYPE_FLOAT     ; If it's a float...
                BEQ in_float        ; ... go to parse the float

                THROW ERR_TYPE      ; Otherwise, throw a type error

syntax_err      THROW ERR_SYNTAX

in_string       setal
                LDA #<>IOBUF
                STA ARGUMENT1
                LDA #`IOBUF
                STA ARGUMENT1+2
                setas
                LDA #TYPE_STRING
                STA ARGTYPE1

save_input      setal
                CALL VAR_SET        ; Attempt to set the value to the variable

                LDA #CHAR_CR        ; Print a newline
                CALL PRINTC
                
done            PLP
                RETURN

in_float        setal               ; Parse the input as an integer (or try to)
                LDA BIP             ; Save the BIP for later use
                STA SAVEBIP
                LDA BIP+2
                STA SAVEBIP+2

                LDA #<>IOBUF        ; Point to the line that was just input
                STA BIP
                LDA #`IOBUF
                STA BIP+2

.if SYSTEM == SYSTEM_X816
                CALL SKIPWS         ; Leading blanks hang the number parsers,
                                    ;  and PRINT puts one in front of every
                                    ;  positive number -- so INPUT #1 reading
                                    ;  back what PRINT #1 wrote would wedge.
                                    ;  Upstream BASIC816 has the same defect
                                    ;  from the keyboard; guarded so that the
                                    ;  C256 build still reproduces stock.
.endif
                CALL PARSENUM       ; Attempt to parse the number

                setal
                LDA SAVEBIP         ; Restore the BIP
                STA BIP
                LDA SAVEBIP+2
                STA BIP+2
                BRA save_input

in_integer      setal               ; Parse the input as an integer (or try to)
                LDA BIP             ; Save the BIP for later use
                STA SAVEBIP
                LDA BIP+2
                STA SAVEBIP+2

                LDA #<>IOBUF        ; Point to the line that was just input
                STA BIP
                LDA #`IOBUF
                STA BIP+2

                ; TODO: intercept errors

.if SYSTEM == SYSTEM_X816
                CALL SKIPWS         ; Leading blanks hang the number parsers,
                                    ;  and PRINT puts one in front of every
                                    ;  positive number -- so INPUT #1 reading
                                    ;  back what PRINT #1 wrote would wedge.
                                    ;  Upstream BASIC816 has the same defect
                                    ;  from the keyboard; guarded so that the
                                    ;  C256 build still reproduces stock.
.endif
                CALL PARSEINT       ; Attempt to parse the integer

                setal
                LDA SAVEBIP         ; Restore the BIP
                STA BIP
                LDA SAVEBIP+2
                STA BIP+2
                BRA save_input
                .pend

;
; Read one of more characters from the keyboard without echoing them to the screen
; GET <variable> [, <variable> ...]
S_GET           .proc
                PHP
                TRACE "S_GET"

varloop         CALL SKIPWS

                setas
                LDA [BIP]
                BEQ done            ; If EOL, we're done
                CMP #':'
                BEQ done            ; If colon, we're done

                CALL ISALPHA        ; Check to see if it's the start of a variable
                BCC syntax_err      ; No: it's a syntax error

                CALL VAR_FINDNAME   ; Try to find the variable name
                BCC syntax_err      ; If we didn't get a variable, throw a syntax error

                CALL TEMPSTRING     ; Get a temporary string
                CALL GETKEY         ; Get a key from the keyboard, without echoing it

                setas               ; Save the character as a temporary string
                LDY #0
                STA [STRPTR],Y
                LDA #0
                INY
                STA [STRPTR],Y

                setal
                LDA STRPTR
                STA ARGUMENT1
                LDA STRPTR+2
                STA ARGUMENT1+2
                setas
                LDA #TYPE_STRING
                STA ARGTYPE1
                
                CALL VAR_SET        ; Attempt to set the value to the variable

                CALL SKIPWS
                LDA [BIP]           ; Get the next non-space
                BEQ done            ; EOL? We're done
                CMP #':'            ; Colon? We're done
                BEQ done
                CMP #','            ; Comma?
                BNE syntax_err      ; Nope: syntax error

                CALL INCBIP         ; Yes... check for another variable
                BRA varloop
                
done            PLP
                RETURN
syntax_err      THROW ERR_SYNTAX
                .pend

; Call a machine language subroutine. Return from subroutines must be long (RTL)
; CALL address [,a_value [,x_value [,y_value]]]
S_CALL          .proc
                PHP
                TRACE "S_CALL"

                CALL EVALEXPR       ; Get the address
                CALL ASS_ARG1_INT   ; Assure the address is an integer

                setas
                LDA #$5C            ; Set the opcode for JML
                STA MJUMPINST
                setal               ; Set the JML address to the argument
                LDA ARGUMENT1
                STA MJUMPADDR
                setas
                LDA ARGUMENT1+2
                STA MJUMPADDR+2

                ; Get the optional value for A

                setas
                LDA #','
                STA TARGETTOK
                CALL OPT_TOK        ; Is there a comma?
                BCC launch          ; Not present... go ahead and launch
                CALL INCBIP

                CALL EVALEXPR       ; Otherwise, get value for A
                CALL ASS_ARG1_INT16 ; Make sure it's a 16-bit integer
                setal
                LDA ARGUMENT1
                STA MARG1           ; Save it to MARG1

                ; Get the optional value for X

                setas
                LDA #','
                STA TARGETTOK
                CALL OPT_TOK        ; Is there a comma?
                BCC launch          ; Not present... go ahead and launch
                CALL INCBIP

                CALL EVALEXPR       ; Otherwise, get value for X
                CALL ASS_ARG1_INT16 ; Make sure it's a 16-bit integer
                setal
                LDA ARGUMENT1
                STA MARG2           ; Save it to MARG2

                ; Get the optional value for Y

                setas
                LDA #','
                STA TARGETTOK
                CALL OPT_TOK        ; Is there a comma?
                BCC launch          ; Not present... go ahead and launch
                CALL INCBIP

                CALL EVALEXPR       ; Otherwise, get value for Y
                CALL ASS_ARG1_INT16 ; Make sure it's a 16-bit integer
                setal
                LDY ARGUMENT1
launch          LDX MARG2
                LDA MARG1

                PHD
                PHB
                PHP
                JSL MJUMPINST       ; Call the subroutine indicated
                PLP
                PLB
                PLD

                CALL SKIPSTMT       ; Skip to the ending colon or end of line

                PLP
                RETURN
type_err        THROW ERR_TYPE
                .pend

; Dimmension an array DIM A(i_0, i_1, ... i_n)
S_DIM           .proc
                PHP
                TRACE "S_DIM"

                setas

                CALL SKIPWS

                CALL VAR_FINDNAME   ; Try to find the variable name
                BCC syntax_err      ; If we didn't get a variable, throw a syntax error

                LDA #TOK_LPAREN     ; Verify we have a left parenthesis
                CALL EXPECT_TOK

                LDA #TOK_FUNC_OPEN  ; Push the "operator" marker for the start of the function
                CALL PHOPERATOR

                LDX #1

                LDA #0
                STA @lARRIDXBUF     ; Set the dimension count to 0

dim_loop        CALL EVALEXPR       ; Evaluate the count
                CALL ASS_ARG1_INT   ; Make sure it is an integer

                setal
                LDA ARGUMENT1
                STA @lARRIDXBUF,X   ; And store it in the buffer

                setas
                LDA @lARRIDXBUF     ; Add to the dimension count
                INC A
                STA @lARRIDXBUF
                BMI overflow        ; If > 127 throw an error

                INX
                INX

                CALL SKIPWS         ; Skip any whitespace
                LDA [BIP]           ; Check the character
                CMP #','            ; Is it a comma?
                BEQ skip_comma      ; Yes: get the next dimension
                CMP #TOK_RPAREN     ; No: is it a ")"?
                BNE syntax_err      ; No: throw a syntax error

                CALL INCBIP         ; Yes: we're done... skip the parenthesis

                CALL ARR_ALLOC      ; Allocate the array

                setal
                LDA CURRBLOCK       ; Set up the pointer to the array
                STA ARGUMENT1
                setas
                LDA CURRBLOCK+2
                STA ARGUMENT1+2
                STZ ARGUMENT1+3

                LDA TOFINDTYPE      ; Get the type of the values
                ORA #$80            ; Make sure we change the type to array
                STA TOFINDTYPE      ; And save it back for searching
                STA ARGTYPE1        ; And for the value to set

                CALL VAR_SET        ; And set the variable

                PLP
                RETURN
skip_comma      CALL INCBIP
                JMP dim_loop

syntax_err      THROW ERR_SYNTAX
overflow        THROW ERR_ARGUMENT
                .pend

; Read data from data statements
; READ variable, variable, ...
S_READ          .proc
                PHP
                TRACE "S_READ"

varloop         CALL SKIPWS

                setas
                LDA [BIP]
                BEQ done            ; If EOL, we're done
                CMP #':'
                BEQ done            ; If colon, we're done

                CALL ISALPHA        ; Check to see if it's the start of a variable
                BCC syntax_err      ; No: it's a syntax error

                CALL VAR_FINDNAME   ; Try to find the variable name
                BCC syntax_err      ; If we didn't get a variable, throw a syntax error

                CALL NEXTDATA       ; Try to get the next data item into ARGUMENT1
                CALL VAR_SET        ; Attempt to set the value to the variable

                CALL SKIPWS
                LDA [BIP]           ; Get the next non-space
                BEQ done            ; EOL? We're done
                CMP #':'            ; Colon? We're done
                BEQ done
                CMP #','            ; Comma?
                BNE syntax_err      ; Nope: syntax error

                CALL INCBIP         ; Yes... check for another variable
                BRA varloop
                
done            PLP
                RETURN
syntax_err      THROW ERR_SYNTAX
                .pend

; Helper subroutine... try to find and parse the next literal in a DATA statement
; Throw error if we're out
NEXTDATA        .proc
                PHP
                TRACE "NEXTDATA"

                LDA BIP+2           ; Save BIP
                STA SAVEBIP+2
                LDA BIP
                STA SAVEBIP

                LDA CURLINE+2       ; Save CURLINE
                STA SAVELINE+2
                LDA CURLINE
                STA SAVELINE  

                ; Check if DATABIP is set
                setal
                LDA DATABIP+2
                BNE data_set
                LDA DATABIP
                BEQ scan_start      ; No: scan for a DATA statement

data_set        LDA DATABIP         ; Move BIP to the DATA statement
                STA BIP
                LDA DATABIP+2
                STA BIP+2

                LDA DATALINE        ; Set CURLINE from DATALINE
                STA CURLINE
                LDA DATALINE+2
                STA CURLINE+2

                setas
                LDA [BIP]           ; Check character at BIP
                BEQ scan_DATA       ; EOL? scan for a DATA statement
                CMP #':'            ; Colon?
                BEQ scan_DATA       ; ... scan for a DATA statement
                CMP #','            ; Comma?
                BNE skip_parse      ; No: skip leading WS and try to parse
                CALL INCBIP         ; Yes: move to the next char

skip_parse      CALL SKIPWS         ; Skip white space

                LDA [BIP]
                CMP #CHAR_DQUOTE    ; Is it a quote?
                BEQ read_string     ; Yes: process the string
                CALL ISNUMERAL      ; Is it a numeral?
                BCS read_number     ; Yes: process the number

syntax_err      THROW ERR_SYNTAX    ; Otherwise: throw syntax error

scan_start      TRACE "scan_start"
                setal
                LDA #<>BASIC_BOT    ; Point CURLINE to the first line
                STA CURLINE
                LDA #`BASIC_BOT
                STA CURLINE+2

                CLC
                LDA CURLINE         ; Point BIP to the first possible token
                ADC #LINE_TOKENS
                STA BIP
                LDA CURLINE+2
                ADC #0
                STA BIP+2

                ; Scan for a DATA statement
scan_data       TRACE "scan_data"
                setas
                LDA #$80            ; We don't want to process nesting
                STA SKIPNEST

                LDA #TOK_DATA       ; We're looking for a DATA token
                STA TARGETTOK

                CALL SKIPTOTOK      ; Try to find the DATA token
                BRA skip_parse

                ; Read a string literal
read_string     CALL EVALSTRING     ; Try to read a string
                BRA done

                ; Read an integer or floating point literal
read_number     CALL PARSENUM       ; Try to read a number

                TRACE "got number"

done            setal
                LDA BIP             ; Save BIP to DATABIP
                STA DATABIP
                LDA BIP+2
                STA DATABIP+2

                LDA CURLINE         ; Save CURLINE to DATALINE
                STA DATALINE
                LDA CURLINE+2
                STA DATALINE+2

                LDA SAVELINE        ; Restore CURLINE
                STA CURLINE
                LDA SAVELINE+2
                STA CURLINE+2

                LDA SAVEBIP         ; Restore BIP
                STA BIP
                LDA SAVEBIP+2
                STA BIP+2

                PLP
                RETURN
                .pend

; Store date for later reads. When executed, just goes to the end of the statement
S_DATA          .proc
                TRACE "S_DATA"
                CALL SKIPSTMT
                RETURN
                .pend

; Reset the DATA pointer to the beginning
S_RESTORE       .proc
                TRACE "S_RESTORE"
                STZ DATABIP         ; Just set DATABIP to 0
                STZ DATABIP+2       ; The next READ will move it to the first DATA
                STZ DATALINE        ; Set DATALINE to 0
                STZ DATALINE+2
                RETURN
                .pend

; Clear the screen and move the cursor to the home position
S_CLS           .proc
                CALL CLSCREEN
                RETURN
                .pend

; Write an 24-bit value to an address in memory
; POKEL <address>,<value>
S_POKEL         .proc

                CALL EVALEXPR       ; Get the address
                CALL ASS_ARG1_INT   ; ...AS AN INTEGER. Without this a
                                    ;  float address was used as its own
                                    ;  BIT PATTERN: POKE A,77 with A
                                    ;  holding 2097408 wrote to $000400,
                                    ;  the exponent and mantissa read as
                                    ;  an address, silently and in bank 0.
                                    ;  PEEK has always converted; these
                                    ;  three never did.

                setal
                LDA ARGUMENT1+2     ; And save it to the stack
                PHA
                LDA ARGUMENT1
                PHA

                setas
                LDA [BIP]
                CMP #','
                BNE syntax_err
                CALL INCBIP

                CALL EVALEXPR       ; Get the value
                CALL ASS_ARG1_INT   ; likewise: the range checks below
                                    ;  read bytes of ARGUMENT1, and a
                                    ;  float's bytes are not its value

                setal
                LDA ARGUMENT1+3
                BNE range_err

                PLA                 ; Pull the target address from the stack
                STA INDEX           ; and into INDEX
                PLA
                STA INDEX+2

                setal
                LDA ARGUMENT1
                STA [INDEX]         ; And write it to the address

                setas
                LDY #2
                LDA ARGUMENT1+2
                STA [INDEX],Y

                RETURN
syntax_err      THROW ERR_SYNTAX
range_err       THROW ERR_RANGE
                .pend

; Write an 16-bit value to an address in memory
; POKEW <address>,<value>
S_POKEW         .proc

                CALL EVALEXPR       ; Get the address
                CALL ASS_ARG1_INT   ; ...AS AN INTEGER. Without this a
                                    ;  float address was used as its own
                                    ;  BIT PATTERN: POKE A,77 with A
                                    ;  holding 2097408 wrote to $000400,
                                    ;  the exponent and mantissa read as
                                    ;  an address, silently and in bank 0.
                                    ;  PEEK has always converted; these
                                    ;  three never did.

                setal
                LDA ARGUMENT1+2     ; And save it to the stack
                PHA
                LDA ARGUMENT1
                PHA

                setas
                LDA [BIP]
                CMP #','
                BNE syntax_err
                CALL INCBIP

                CALL EVALEXPR       ; Get the value
                CALL ASS_ARG1_INT   ; likewise: the range checks below
                                    ;  read bytes of ARGUMENT1, and a
                                    ;  float's bytes are not its value

                setal
                LDA ARGUMENT1+2
                BNE range_err

                PLA                 ; Pull the target address from the stack
                STA INDEX           ; and into INDEX
                PLA
                STA INDEX+2

                setal
                LDA ARGUMENT1
                STA [INDEX]         ; And write it to the address

                RETURN
syntax_err      THROW ERR_SYNTAX
range_err       THROW ERR_RANGE
                .pend

; Write an 8-bit value to an address in memory
; POKE <address>,<value>
S_POKE          .proc

                CALL EVALEXPR       ; Get the address
                CALL ASS_ARG1_INT   ; ...AS AN INTEGER. Without this a
                                    ;  float address was used as its own
                                    ;  BIT PATTERN: POKE A,77 with A
                                    ;  holding 2097408 wrote to $000400,
                                    ;  the exponent and mantissa read as
                                    ;  an address, silently and in bank 0.
                                    ;  PEEK has always converted; these
                                    ;  three never did.

                setal
                LDA ARGUMENT1+2     ; And save it to the stack
                PHA
                LDA ARGUMENT1
                PHA

                setas
                LDA [BIP]
                CMP #','
                BNE syntax_err
                CALL INCBIP

                CALL EVALEXPR       ; Get the value
                CALL ASS_ARG1_INT   ; likewise: the range checks below
                                    ;  read bytes of ARGUMENT1, and a
                                    ;  float's bytes are not its value

                setas
                LDA ARGUMENT1+1     ; Make sure the value is from 0 - 255
                BNE range_err

                setal
                LDA ARGUMENT1+2
                BNE range_err

                PLA                 ; Pull the target address from the stack
                STA INDEX           ; and into INDEX
                PLA
                STA INDEX+2

                setas
                LDA ARGUMENT1
                STA [INDEX]         ; And write it to the address

                RETURN
syntax_err      THROW ERR_SYNTAX
range_err       THROW ERR_RANGE
                .pend

; Stop execution in such a manner that CONT can restart it.
S_STOP          .proc
                THROW ERR_BREAK     ; Throw a BREAK exception
                .pend

; Start a remark or comment in the code
; Everything in the program until the next end-of-line will be ignored
S_REM           .proc
                PHP

                setas
rem_loop        LDA [BIP]
                BEQ done

                CALL INCBIP
                BRA rem_loop

done            PLP
                RETURN
                .pend

; Break out of an enclosing DO loop
S_EXIT          .proc
                PHP

                PLP
                RETURN
                .pend

; Start a loop that may be ended conditionally
; DO [WHILE <conditional expr> | UNTIL <conditional expr>]
;
; Pushes to the return stack:
;   return CURLINE (4)
;   return BIP (4 bytes) <= "top" of stack
;
S_DO            .proc
                PHP
                ; TRACE "S_DO"

                ; ; Save the current line to the RETURN stack

                ; setal
                ; LDA CURLINE+2
                ; CALL PHRETURN
                ; LDA CURLINE
                ; CALL PHRETURN

                ; ; Save the BIP for right after FOR to the RETURN stack
                ; LDA BIP+2           ; Save current BIP
                ; PHA
                ; LDA BIP
                ; PHA

                ; CALL SKIPSTMT       ; Skip to the next statement
                ; LDA BIP+2           ; Save the BIP for the next statement to the RETURN stack
                ; CALL PHRETURN
                ; LDA BIP
                ; CALL PHRETURN

                ; PLA                 ; Restore the original BIP
                ; STA BIP
                ; PLA
                ; STA BIP+2

                PLP
                RETURN
                .pend

;
; Structure of the record DO pushes to the RETURN stack
; (in order of how the parameters will appear in memory on the stack)
;
DO_RECORD       .struct
BIP             .dword  ?
CURLINE         .dword  ?
                .ends

; Close a DO loop
; LOOP [WHILE <conditional expr> | UNTIL <conditional expr>]
;
; Expects the return stack to contain:
;   return CURLINE (4)
;   return BIP (4 bytes) <= "top" of stack
;
S_LOOP          .proc
                PHP
                ; PHB
                ; TRACE "S_LOOP"

                ; setdbr 0

                ; setaxl
                ; LDY RETURNSP
                ; INY
                ; INY

                ; LDA #DO_RECORD.CURLINE,Y        ; Pull the CURLINE for the matching DO
                ; STA CURLINE
                ; LDA #DO_RECORD.CURLINE+2,Y
                ; STA CURLINE_2

                ; LDA #DO_RECORD.BIP,Y            ; Pull the BIP for the matching DO
                ; STA BIP
                ; LDA #DO_RECORD.BIP+2,Y
                ; STA BIP+2

                ; setas                           ; jump back to that spot
                ; LDA #EXEC_RETURN
                ; STA EXECACTION

                ; PHB
                PLP
                RETURN
                .pend

;
; Iterate over a variable from an initial value to an ending value
; FOR <variable> = <initial expr> TO <final expr> [STEP <increment>]
;
; Pushes to the return stack:
;   return CURLINE (4)
;   return BIP (4 bytes),
;   <variable> (4 bytes),
;   <final value> (6 bytes),
;   <increment> (6 bytes) <== "top" of stack
;
S_FOR           .proc
                PHP
                TRACE "S_FOR"

                ; Save the current line to the RETURN stack

                setal
                LDA CURLINE+2
                CALL PHRETURN
                LDA CURLINE
                CALL PHRETURN

                ; Save the BIP for right after FOR to the RETURN stack
                LDA BIP+2           ; Save current BIP
                PHA
                LDA BIP
                PHA

                CALL SKIPSTMT       ; Skip to the next statement
                LDA BIP+2           ; Save the BIP for the next statement to the RETURN stack
                CALL PHRETURN
                LDA BIP
                CALL PHRETURN

                PLA                 ; Restore the original BIP
                STA BIP
                PLA
                STA BIP+2

                ; Find the set the initial value of the index variable

                CALL SKIPWS

get_name        CALL VAR_FINDNAME   ; Try to find the variable name
                BCS push_name       ; If we didn't find a name, thrown an error

                THROW ERR_NOTFOUND

push_name       setas               ; Push the search record for the index variable
                LDA TOFINDTYPE      ; To the return stack
                CALL PHRETURNB
                LDA TOFIND+2
                CALL PHRETURNB
                setal
                LDA TOFIND
                CALL PHRETURN

else            CALL SKIPWS         ; Scan for an "="
                setas
                LDA [BIP]
                CMP #TOK_EQ
                BNE syntax_err      ; If not found: signal an syntax error

                LDA TOFINDTYPE      ; Verify type of variable
                CMP #TYPE_INTEGER   ; Is it integer?
                BEQ process_initial ; Yes: it's ok
                CMP #TYPE_FLOAT     ; Is it floating point?
                BEQ process_initial ; Yes: it's ok

process_initial CALL INCBIP         ; Otherwise, skip over it
                CALL EVALEXPR       ; Evaluate the expression
                CALL VAR_SET        ; Attempt to set the value of the variable

                ; Process the limit value
                setas
                LDA #TOK_TO         ; Expect the next token to be TO
                CALL EXPECT_TOK

                CALL EVALEXPR       ; Evaluate the limit value

                ; TODO: assert that we have a number

                setal               ; Push the ending value
                LDA ARGTYPE1
                CALL PHRETURN
                LDA ARGUMENT1+2
                CALL PHRETURN
                LDA ARGUMENT1
                CALL PHRETURN

                ; Process the optional STEP
                setas
                LDA #TOK_STEP
                STA TARGETTOK
                CALL OPT_TOK        ; Seek an optional STEP token
                BCC default_inc     ; Not found: set a default increment of 1

                CALL INCBIP
                CALL EVALEXPR       ; Evaluate the next expression

                setas
                LDA ARGTYPE1        ; Push the result as the increment
                CALL PHRETURN
                setal
                LDA ARGUMENT1+2
                CALL PHRETURN
                LDA ARGUMENT1
                CALL PHRETURN
                BRA done

default_inc     setal               ; Push 1 as the increment
                LDA #TYPE_INTEGER
                CALL PHRETURN
                LDA #0
                CALL PHRETURN
                LDA #1
                CALL PHRETURN

done            PLP
                RETURN
syntax_err      THROW ERR_SYNTAX
                .pend

;
; Structure of the record FOR pushes to the RETURN stack
; (in order of how the parameters will appear in memory on the stack)
;
FOR_RECORD      .struct
INCREMENT       .dword  ?
INCTYPE         .word   ?
FINAL           .dword  ?
FINALTYPE       .word   ?
VARIBLE         .dword  ?
VARTYPE         .word   ?
BIP             .dword  ?
CURLINE         .dword  ?
                .ends

;
; Close a FOR loop
;
; Expects a return stack looking like this:
;   return CURLINE (4)
;   return BIP (4 bytes),
;   <variable> (4 bytes),
;   <final value> (6 bytes),
;   <increment> (6 bytes) <== "top" of stack
;
S_NEXT          .proc
                PHP
                PHB
                TRACE "S_NEXT"

                setdbr 0
                setdp GLOBAL_VARS

                setaxl

                ; NEXT takes an OPTIONAL variable name, and until now it
                ; consumed nothing at all. The loop RAN correctly and
                ; then the name was left sitting in the line for the
                ; interpreter to read as the start of the next
                ; statement -- so every "FOR I=1 TO 3 ... NEXT I" in
                ; this BASIC printed its results and then reported a
                ; syntax error, on the pass that ENDS the loop and only
                ; then. Bare NEXT was unaffected, which is how the
                ; commonest loop in BASIC stayed broken this long: the
                ; emulator sessions all used the bare form.
                ;
                ; VAR_FINDNAME does its own SKIPWS and its own ISALPHA
                ; and consumes NOTHING when there is no name, so the
                ; carry is of no interest here -- ":" and end-of-line
                ; both leave BIP where it was.
                ;
                ; THE NAME IS NOT CHECKED against the loop it closes.
                ; The FOR record keeps a POINTER to where the name was
                ; written in the program text, and the same variable
                ; mentioned twice has two different pointers, so telling
                ; "NEXT I" from "NEXT J" would mean comparing the names
                ; themselves. help/LANGUAGE.TXT says so rather than
                ; leaving it to be discovered.
                CALL VAR_FINDNAME

                setaxl
                ; Get the final value

                LDY RETURNSP                    ; Y := pointer to first byte of the FOR record
                INY                             ; RETURNSP points to the first free slot, so move up 2 bytes
                INY

                ; Get the variable and its current value
                setal
                LDA #FOR_RECORD.VARIBLE,B,Y     ; TOFIND := FOR_RECORD.VARIABLE
                STA TOFIND
                LDA #FOR_RECORD.VARIBLE+2,B,Y
                setas
                STA TOFIND+2
                LDA #FOR_RECORD.VARTYPE,B,Y
                STA TOFINDTYPE

                setal
                PHY
                CALL VAR_REF                    ; Get the value of the variable
                PLY

                setal
                LDA #FOR_RECORD.INCREMENT,B,Y   ; ARGUMENT2 := FOR_RECORD.INCREMENT
                STA ARGUMENT2
                LDA #FOR_RECORD.INCREMENT+2,B,Y
                STA ARGUMENT2+2
                setas
                LDA #FOR_RECORD.INCTYPE,B,Y
                STA ARGTYPE2

                setal
                PHY
                CALL OP_PLUS                    ; Add the increment to the current value
                CALL VAR_SET                    ; Assign the new value to the variable
                PLY

                setal
                LDA #FOR_RECORD.FINAL,B,Y       ; ARGUMENT2 := FOR_RECORD.FINAL
                STA ARGUMENT2
                LDA #FOR_RECORD.FINAL+2,B,Y
                STA ARGUMENT2+2
                setas
                LDA #FOR_RECORD.FINALTYPE,B,Y
                STA ARGTYPE2

                setal
                LDA #FOR_RECORD.INCREMENT+2,B,Y ; Check the increment's sign
                BMI going_down

going_up        CALL OP_LTE                     ; Is current =< limit?
                CALL IS_ARG1_Z
                BEQ end_loop                    ; No: end the loop
                BRA loop_back                   ; Yes: loop back

going_down      CALL OP_GTE                     ; Is current >= limit?
                CALL IS_ARG1_Z
                BEQ end_loop                    ; No: end the loop

                ; Not at end, so add the increment, reassign, and loop

loop_back       TRACE "loop back"
               
                setal                           ; Set the BIP to the correct spot (right after the FOR)
                LDA #FOR_RECORD.BIP,B,Y
                STA BIP
                LDA #FOR_RECORD.BIP+2,B,Y
                STA BIP+2

                ; Set the CURLINE to the correct spot (right after the FOR)
                LDA #FOR_RECORD.CURLINE,B,Y     ; CURLINE := FOR_RECORD.CURLINE
                STA CURLINE
                LDA #FOR_RECORD.CURLINE+2,B,Y
                STA CURLINE+2

                setas                           ; Set the action to RETURN to the spot
                LDA #EXEC_RETURN
                STA EXECACTION

                BRA done

                ; Got to the end of the loop, cleanup the RETURN stack

end_loop        TRACE "end_loop"

                LDX #ARGUMENT1
                CALL PLARGUMENT                 ; Restore the value of the variable

                setal
                CLC
                LDA RETURNSP
                ADC #size(FOR_RECORD)           ; Move pointer by number of bytes in a FOR record
                STA RETURNSP
                LDA RETURNSP+2
                ADC #0
                STA RETURNSP+2

done            PLB
                PLP
                RETURN
                .pend

; Jump to a subroutine. Push BIP, CURLINE, and LINENUM to stack
; RETURN will pull them back
S_GOSUB         .proc
                PHP
                TRACE "S_GOSUB"

                LDA CURLINE                 ; Save the current line for later
                PHA
                LDA CURLINE+2
                PHA

                CALL TARGET_FIND            ; a line number, or a LABEL
                BCC not_found

                setas                       ; Tell the interpreter to restart at the selected line
                LDA #EXEC_GOTO
                STA EXECACTION

                CALL SKIPSTMT               ; Skip to the next statement

                setal
                PLA                         ; Save the old value of CURLINE to the RETURN stack
                CALL PHRETURN
                PLA
                CALL PHRETURN

                LDA BIP+2                   ; Save the BASIC Instruction Pointer to the RETURN stack
                CALL PHRETURN
                LDA BIP
                CALL PHRETURN

                INC GOSUBDEPTH              ; Increase the count of GOSUBs on the stack

                PLP
                RETURN
syntax_err      PLA
                PLA
                THROW ERR_SYNTAX
not_found       PLA
                PLA
                THROW ERR_NOLINE
                .pend

; RETURN from a subroutine call... pulls BIP, CURLINE, and LINENUM from the stack
S_RETURN        .proc
                PHP
                TRACE "S_RETURN"

                setaxl
                LDA GOSUBDEPTH              ; Check that there is at least on GOSUB on the stack
                BEQ underflow               ; No? It's a stack underflow error

                CALL PLRETURN               ; Restore BIP, and CURLINE from the return stack
                STA BIP
                CALL PLRETURN
                STA BIP+2
                CALL PLRETURN
                STA CURLINE
                CALL PLRETURN
                STA CURLINE+2

                DEC GOSUBDEPTH              ; Indicate we've popped that GOSUB off the stack

                setas                       ; Tell the interpreter to restart at the selected line
                LDA #EXEC_RETURN
                STA EXECACTION

                PLP
                RETURN
underflow       TRACE "underflow"
                THROW ERR_STACKUNDER
                .pend

;;;
;;; IF, in two forms
;;;
;;; The classic one, which BASIC816 had:
;;;
;;;     IF <test> THEN <line number>
;;;
;;; and the block one, which is what makes this SuperBasic:
;;;
;;;     IF <test> THEN
;;;       ...
;;;     ELSE
;;;       ...
;;;     ENDIF
;;;
;;; They are told apart by what follows THEN: a line number, or nothing.
;;;
;;; NO STATE IS KEPT, and that is the whole trick. ELSE can only ever be
;;; REACHED by falling out of a branch that was taken, so it always means
;;; "skip to my ENDIF" and needs to know nothing else. ENDIF does
;;; nothing at all. A false IF skips to its ELSE or its ENDIF. There is
;;; no stack, nothing to unwind, and a GOTO out of a block leaves nothing
;;; behind to leak.
;;;

;
; Skip forward to the ELSE or the ENDIF that closes this block.
;
; Inputs:
;   IFMODE = 1 to stop at an ELSE as well, 0 for an ENDIF only
;   CURLINE = the line the IF or ELSE is on
;
; Outputs:
;   CURLINE, BIP = just past the token that closed the block
;   EXECACTION = EXEC_RETURN, because BIP is set and must not be reset
;
; ONLY THE FIRST TOKEN OF EACH LINE IS LOOKED AT, so IF, ELSE and ENDIF
; must start their own lines in the block form. That restriction is
; worth having rather than working around: a scanner that walked every
; token would have to understand strings, REM and the two-byte escape,
; or it would eventually find an ENDIF inside a quoted string. Reading
; one token a line cannot make that mistake -- and SKIPTOTOK, which does
; walk tokens, had exactly that class of bug until today.
;
SKIPBLOCK       .proc
                PHP
                setaxl

                setas
                STZ NESTING

sb_line         CALL NEXTLINE               ; CURLINE and LINENUM move on
                setal
                LDA LINENUM
                BEQ sb_noend                ; ran off the end of the program

                CLC                         ; BIP := this line's first token
                LDA CURLINE
                ADC #LINE_TOKENS
                STA BIP
                setas
                LDA CURLINE+2
                ADC #0
                STA BIP+2
                CALL SKIPWS

                setal
                CALL TOKAT                  ; 16-bit, so $FF is handled here

                CMP @l BLKCLOSE
                BEQ sb_close
                CMP @l BLKOPEN
                BEQ sb_deeper
                CMP @l BLKALT
                BEQ sb_alt
                BRA sb_line

sb_deeper       setas                       ; an inner block: its end is not
                INC NESTING                 ;  the one we are looking for
                BRA sb_line

sb_close        setas
                LDA NESTING
                BEQ sb_found
                DEC NESTING
                BRA sb_line

sb_alt          setas
                LDA NESTING
                BNE sb_line                 ; belongs to an inner block

sb_found        setal
                CALL TOKSKIP                ; step past it, however wide
                setas
                LDA #EXEC_RETURN            ; BIP is already where execution
                STA EXECACTION              ;  resumes, so it must not be
                                            ;  reset to the head of the line
                PLP
                RETURN

sb_noend        PLP
                THROW ERR_SYNTAX
                .pend

;
; Set the three tokens SKIPBLOCK looks for.
;
; A is the opener, X the closer, Y the alternative ending -- pass the
; closer again when there is no second one.
;
BLK_SET         .proc
                PHP
                setaxl
                STA @l BLKOPEN
                setal
                TXA
                STA @l BLKCLOSE
                TYA
                STA @l BLKALT
                PLP
                RETURN
                .pend

S_ELSE          .proc
                PHP
                TRACE "S_ELSE"
                setaxl
                LDA #TOK_IF                 ; an ELSE closes at its ENDIF and
                LDX #TOK_ENDIF              ;  never at another ELSE, so the
                LDY #TOK_ENDIF              ;  alternative is the closer again
                CALL BLK_SET
                CALL SKIPBLOCK
                PLP
                RETURN
                .pend

;
; ENDIF -- nothing to do. Both branches arrive here and carry on.
;
S_ENDIF         .proc
                TRACE "S_ENDIF"
                RETURN
                .pend

;;;
;;; PROC, ENDPROC and LOCAL
;;;
;;;     10 PROC box(3, 4)
;;;     ...
;;;     100 DEFPROC box(w, h)
;;;     110   LOCAL i
;;;     120   FOR i = 1 TO h
;;;     130     PRINT w
;;;     140   NEXT
;;;     150 ENDPROC
;;;
;;; DEFPROC defines and PROC calls, rather than BBC BASIC's PROCname,
;;; because a keyword and a name cannot be glued together by a tokenizer
;;; that matches keywords anywhere in a line.
;;;
;;; THERE IS NO PROCEDURE TABLE. A call searches the program for its
;;; DEFPROC exactly as GOSUB searches for a line number -- the same cost,
;;; the same code shape, and nothing to register, to invalidate on NEW,
;;; or to get out of step with the program text.
;;;
;;; PARAMETERS ARE LOCAL, automatically. Binding one is the same
;;; operation LOCAL performs: push the old value on the return stack,
;;; count it into the frame, then assign. ENDPROC puts all of them back,
;;; so a procedure cannot quietly change a variable its caller was using
;;; as a loop counter.
;;;
;;; They bind LAST FIRST. Arguments go on the argument stack as they are
;;; evaluated and a stack gives them up in reverse, so rather than find
;;; somewhere to turn them round, the binding walks the parameter list to
;;; the Nth name, then the (N-1)th. The list is short and the walk is a
;;; few bytes of code instead of a buffer.
;;;

;
; Compare the name at PROCNAME with the one at SCRATCH. Both are raw
; program text, ending at any character a name cannot contain.
;
; C set when they match. Case-insensitive: the tokenizer leaves
; identifiers exactly as typed, and a procedure called in two cases is
; one procedure.
;
PROCNAMECMP     .proc
                PHP
                setas
                setxl
                LDY #0

pn_loop         LDA [PROCNAME],Y
                AND #$DF                    ; a case-insensitive compare that
                STA @l PROCCH                  ;  needs no table: among the
                LDA [SCRATCH],Y             ;  characters a name may contain,
                AND #$DF                    ;  clearing bit 5 folds case and
                CMP @l PROCCH                  ;  collides with nothing else
                BNE pn_no

                LDA [SCRATCH],Y             ; equal -- but is the name over?
                CALL ISVARCHAR
                BCC pn_yes                  ; both ended, on the same character

                INY
                CPY #40                     ; no name is this long
                BNE pn_loop

pn_yes          PLP
                SEC
                RETURN
pn_no           PLP
                CLC
                RETURN
                .pend

;
; Step BIP over a name.
;
PROC_SKIPNAME   .proc
                PHP
                setas
psn_loop        LDA [BIP]
                CALL ISVARCHAR
                BCC psn_done
                CALL INCBIP
                BRA psn_loop
psn_done        PLP
                RETURN
                .pend

;
; Find the line whose first token is NAMETOK and whose name matches
; PROCNAME -- a DEFPROC for a call, a LABEL for a GOTO.
;
; The same search serves both because they are the same question, and it
; is the question GOSUB has always asked of a line number: walk the
; program until something matches. Nothing is registered in advance, so
; nothing can be stale.
;
; Outputs:
;   C set, CURLINE = its line and BIP just past the name; or C clear
;
NAME_FIND       .proc
                PHP
                setaxl

                LDA #<>BASIC_BOT
                STA CURLINE
                LDA #`BASIC_BOT
                STA CURLINE+2

pf_check        setaxl
                LDY #LINE_NUMBER
                LDA [CURLINE],Y
                BEQ pf_none                 ; number 0: the end of the program

                CLC                         ; BIP := the line's first token
                LDA CURLINE
                ADC #LINE_TOKENS
                STA BIP
                setas
                LDA CURLINE+2
                ADC #0
                STA BIP+2
                CALL SKIPWS

                setal
                CALL TOKAT
                CMP @l NAMETOK
                BNE pf_next

                CALL TOKSKIP
                CALL SKIPWS
                setal                       ; the header's name
                LDA BIP
                STA SCRATCH
                LDA BIP+2
                STA SCRATCH+2
                CALL PROCNAMECMP
                BCS pf_found

pf_next         CALL NEXTLINE
                BRA pf_check

pf_found        CALL PROC_SKIPNAME
                PLP
                SEC
                RETURN
pf_none         PLP
                CLC
                RETURN
                .pend

;
; Save the variable named by TOFIND/TOFINDTYPE on the return stack and
; count it into the frame, so that ENDPROC can put it back.
;
; The NAME POINTER is what is saved, and it points into the program text,
; which does not move while a program runs. It cannot be TOFIND by then:
; VAR_FIND rewrites TOFIND to its uppercased copy in TEMPBUF, and the
; next lookup overwrites that.
;
PROC_MAKELOCAL  .proc
                PHP
                setaxl

                LDA TOFIND+2
                CALL PHRETURN
                LDA TOFIND
                CALL PHRETURN
                setas
                LDA TOFINDTYPE
                setal
                AND #$00FF
                CALL PHRETURN

                CALL VAR_FIND               ; its value, if it has one yet
                BCS pml_have
                setal                       ; never assigned: keep a zero, so
                LDA #0                      ;  ENDPROC restores it to nothing
                STA ARGUMENT1               ;  rather than to rubbish
                STA ARGUMENT1+2
                BRA pml_push
pml_have        CALL VAR_REF
pml_push        setal
                LDA ARGUMENT1+2
                CALL PHRETURN
                LDA ARGUMENT1
                CALL PHRETURN

                setal
                LDA @l PROCLOCALS       ; INC has no long addressing mode
                INC A
                STA @l PROCLOCALS

                PLP
                RETURN
                .pend

;
; TOFIND := the PROCIDX'th parameter of the header at PROCHDR, 1-based.
;
PROC_PARAM      .proc
                PHP
                setaxl
                PHY

                LDA @l PROCHDR
                STA BIP
                LDA @l PROCHDR+2
                STA BIP+2

                CALL SKIPWS
                setas
                LDA [BIP]
                CMP #TOK_LPAREN
                BNE pp_none
                CALL INCBIP

                setaxl
                LDY #0
pp_next         CALL SKIPWS
                setas
                LDA [BIP]
                CALL ISALPHA
                BCC pp_none
                CALL VAR_FINDNAME
                BCC pp_none

                setaxl
                INY
                TYA                         ; CPY has no long mode either
                CMP @l PROCIDX
                BEQ pp_found

                CALL SKIPWS
                setas
                LDA [BIP]
                CMP #','
                BNE pp_none
                CALL INCBIP
                BRA pp_next

pp_found        setaxl
                PLY
                PLP
                SEC
                RETURN
pp_none         setaxl
                PLY
                PLP
                CLC
                RETURN
                .pend

;
; DEFPROC, arrived at by falling into it. A definition is not a thing to
; execute, so this steps over the body to its ENDPROC -- which is how a
; procedure can sit anywhere in the program, including above the code
; that calls it.
;
S_DEFPROC       .proc
                PHP
                TRACE "S_DEFPROC"
                setaxl
                LDA #TOK_DEFPROC
                LDX #TOK_ENDPROC
                LDY #TOK_ENDPROC
                CALL BLK_SET
                CALL SKIPBLOCK
                PLP
                RETURN
                .pend

;
; LOCAL v [, v ...] -- keep these until ENDPROC puts them back.
;
; A local NUMBER starts at zero and a local STRING starts empty, which is
; worth the few bytes: a local that starts as whatever the caller left
; there is a bug that only appears the second time the procedure runs.
;
S_LOCAL         .proc
                PHP
                TRACE "S_LOCAL"
                setaxl

                LDA @l PROCDEPTH
                BEQ sl_outside

sl_name         CALL SKIPWS
                setas
                LDA [BIP]
                CALL ISALPHA
                BCC sl_syntax
                CALL VAR_FINDNAME
                BCC sl_syntax

                CALL PROC_MAKELOCAL

                setas                       ; and start it empty
                LDA TOFINDTYPE
                CMP #TYPE_STRING
                BEQ sl_string
                setal
                LDA #0
                STA ARGUMENT1
                STA ARGUMENT1+2
                BRA sl_settype
sl_string       setal
                LDA #<>proc_empty
                STA ARGUMENT1
                LDA #`proc_empty
                STA ARGUMENT1+2
sl_settype      setas
                LDA TOFINDTYPE
                STA ARGTYPE1
                setal
                CALL VAR_SET

                CALL SKIPWS
                setas
                LDA [BIP]
                CMP #','
                BNE sl_done
                CALL INCBIP
                BRA sl_name

sl_done         PLP
                RETURN
sl_outside      PLP
                THROW ERR_STACKUNDER
sl_syntax       THROW ERR_SYNTAX
                .pend

proc_empty      .byte 0                     ; what a LOCAL string starts as

;
; PROC name [(a [, a ...])] -- call one.
;
S_PROC          .proc
                PHP
                TRACE "S_PROC"
                setaxl
                PHX
                PHY

                CALL SKIPWS
                setal                       ; the name, kept while the
                LDA BIP                     ;  arguments are evaluated
                STA PROCNAME
                LDA BIP+2
                STA PROCNAME+2
                setas
                LDA [BIP]
                CALL ISALPHA
                BCS sp_named                ; the error exits are at the far
                JMP sp_syntax               ;  end of a long statement
sp_named        CALL PROC_SKIPNAME

                ; ---- the arguments, onto the argument stack ----
                setaxl
                LDY #0
                CALL SKIPWS
                setas
                LDA [BIP]
                CMP #TOK_LPAREN
                BNE sp_noargs
                CALL INCBIP

sp_arg          CALL SKIPWS
                setas
                LDA [BIP]
                CMP #TOK_RPAREN
                BEQ sp_close

                setaxl
                PHY                         ; EVALEXPR is a whole interpreter
                CALL EVALEXPR               ;  and Y is not its to keep
                setaxl
                LDX #ARGUMENT1
                CALL PHARGUMENT
                PLY
                INY
                CPY #9
                BCC sp_okcount
                JMP sp_toomany
sp_okcount

                CALL SKIPWS
                setas
                LDA [BIP]
                CMP #','
                BNE sp_close
                CALL INCBIP
                BRA sp_arg

sp_close        setas
                LDA [BIP]
                CMP #TOK_RPAREN
                BEQ sp_rparen
                JMP sp_syntax
sp_rparen       CALL INCBIP

sp_noargs       setaxl
                TYA                         ; nor STY
                STA @l PROCARGN
                CALL SKIPSTMT               ; BIP is now past the call

                ; ---- the frame: what GOSUB saves, plus the local count ----
                setaxl
                LDA CURLINE+2
                CALL PHRETURN
                LDA CURLINE
                CALL PHRETURN
                LDA BIP+2
                CALL PHRETURN
                LDA BIP
                CALL PHRETURN
                LDA @l PROCLOCALS              ; the CALLER's, restored by ENDPROC
                CALL PHRETURN
                setal
                LDA #0
                STA @l PROCLOCALS
                LDA @l PROCDEPTH
                INC A
                STA @l PROCDEPTH

                ; ---- find it ----
                setaxl
                LDA #TOK_DEFPROC
                STA @l NAMETOK
                CALL NAME_FIND
                BCS sp_found
                JMP sp_nosuch
sp_found

                setal                       ; where the parameter list begins,
                LDA BIP                     ;  returned to once per parameter
                STA @l PROCHDR
                LDA BIP+2
                STA @l PROCHDR+2

                ; ---- bind, last parameter first ----
                setal
                LDA @l PROCARGN
                BEQ sp_body
                STA @l PROCIDX

sp_bind         setaxl                      ; the argument stack gives them
                LDX #ARGUMENT1              ;  up in reverse, which is why
                CALL PLARGUMENT             ;  PROCIDX counts down
                setal
                LDA ARGUMENT1               ; park it: reading the parameter's
                STA @l PROCVAL                 ;  old value lands in ARGUMENT1
                LDA ARGUMENT1+2
                STA @l PROCVAL+2
                setas
                LDA ARGTYPE1
                STA @l PROCVALT

                CALL PROC_PARAM
                BCS sp_gotparam
                JMP sp_argcount
sp_gotparam

                CALL PROC_MAKELOCAL         ; a parameter IS a local

                setal
                LDA @l PROCVAL
                STA ARGUMENT1
                LDA @l PROCVAL+2
                STA ARGUMENT1+2
                setas
                LDA @l PROCVALT                ; the ARGUMENT's type; TOFINDTYPE
                STA ARGTYPE1                ;  is still the PARAMETER's, so
                setal                       ;  VAR_SET casts between them
                CALL VAR_SET

                setal
                LDA @l PROCIDX
                DEC A
                STA @l PROCIDX
                BNE sp_bind

sp_body         setal                       ; the body is the lines below the
                LDA @l PROCHDR                 ;  header, so finish the header
                STA BIP                     ;  line and fall off the end of it
                LDA @l PROCHDR+2
                STA BIP+2
                CALL SKIPSTMT

                setas
                LDA #EXEC_RETURN            ; CURLINE and BIP are both set
                STA EXECACTION

                PLY
                PLX
                PLP
                RETURN

sp_syntax       THROW ERR_SYNTAX
sp_toomany      THROW ERR_ARGUMENT
sp_nosuch       THROW ERR_NOTFOUND
sp_argcount     THROW ERR_ARGUMENT
                .pend

;
; LABEL name -- a place to jump to that is not a number.
;
; It does nothing when it is reached, which is the whole of it: a GOTO
; that finds a label lands ON the label's line, the statement returns,
; and execution carries on into whatever follows. Nothing has to skip
; over it and nothing has to remember it.
;
S_LABEL         .proc
                PHP
                TRACE "S_LABEL"
                CALL SKIPSTMT               ; the name is not for executing
                PLP
                RETURN
                .pend

;
; Find what a GOTO, GOSUB or THEN is aiming at: a line number, or a
; LABEL.
;
; Outputs:
;   C set and CURLINE at the target; BIP left just past the name or the
;   number, ON THE ORIGINAL LINE -- GOSUB has to go on from there to
;   work out where to come back to.
;
TARGET_FIND     .proc
                PHP
                setaxl

                CALL SKIPWS
                setas
                LDA [BIP]
                CALL ISALPHA
                BCS tf_label

                setaxl                      ; a line number, as it always was
                CALL PARSEINT
                LDA ARGUMENT1
                BEQ tf_no
                CALL FINDLINE
                BCC tf_no
                BRA tf_yes

tf_label        setal                       ; a name: the same search PROC
                LDA BIP                     ;  uses, pointed at LABEL instead
                STA PROCNAME
                LDA BIP+2
                STA PROCNAME+2
                CALL PROC_SKIPNAME          ; past it, at the CALL site

                setal                       ; NAME_FIND scans with BIP, and
                LDA BIP                     ;  the caller still needs it
                PHA
                LDA BIP+2
                PHA

                setaxl
                LDA #TOK_LABEL
                STA @l NAMETOK
                CALL NAME_FIND

                setal                       ; PLA moves N and Z, never C
                PLA
                STA BIP+2
                PLA
                STA BIP
                BCC tf_no

tf_yes          PLP
                SEC
                RETURN
tf_no           PLP
                CLC
                RETURN
                .pend

;
; ENDPROC -- put every local back, then return to the caller.
;
S_ENDPROC       .proc
                PHP
                TRACE "S_ENDPROC"
                setaxl

                LDA @l PROCDEPTH
                BEQ se_outside

se_locals       setal
                LDA @l PROCLOCALS
                BEQ se_frame

                CALL PLRETURN               ; the reverse of PROC_MAKELOCAL
                STA ARGUMENT1
                CALL PLRETURN
                STA ARGUMENT1+2
                CALL PLRETURN
                setas
                STA ARGTYPE1
                STA TOFINDTYPE
                setal
                CALL PLRETURN
                STA TOFIND
                CALL PLRETURN
                setas
                STA TOFIND+2
                setal
                CALL VAR_SET

                setal
                LDA @l PROCLOCALS
                DEC A
                STA @l PROCLOCALS
                BRA se_locals

se_frame        setaxl
                CALL PLRETURN
                STA @l PROCLOCALS              ; the caller's count
                CALL PLRETURN
                STA BIP
                CALL PLRETURN
                setas
                STA BIP+2
                setal
                CALL PLRETURN
                STA CURLINE
                CALL PLRETURN
                setas
                STA CURLINE+2
                setal
                LDA @l PROCDEPTH
                DEC A
                STA @l PROCDEPTH

                setas
                LDA #EXEC_RETURN
                STA EXECACTION
                PLP
                RETURN

se_outside      PLP
                THROW ERR_STACKUNDER
                .pend

; Test an expression, and take one of the two forms above.
S_IF            .proc
                PHP
                TRACE "S_IF"

                CALL EVALEXPR               ; Evaluate the expression
                CALL IS_ARG1_Z              ; Z set when the result is FALSE
                setas
                BEQ if_false
                LDA #1
                BRA if_keep
if_false        LDA #0
if_keep         STA @l IFTRUE                  ; kept across the THEN check

                setas
                LDA #TOK_THEN               ; THEN is required in BOTH forms.
                CALL EXPECT_TOK             ;  BASIC816 checked it only when
                                            ;  the test was true, so a false
                                            ;  "IF x GOTO 100" was skipped in
                                            ;  silence instead of reported.

                CALL SKIPWS
                setas
                LDA [BIP]
                BEQ if_block                ; nothing after THEN: the block
                                            ;  form, and the body is the
                                            ;  lines below

                ; ---- IF <test> THEN <line number> ----
                setas
                LDA @l IFTRUE
                BEQ if_notaken

                CALL TARGET_FIND            ; a line number, or a LABEL
                BCC not_found

                TRACE_L "TRUE",CURLINE
                setas                       ; Restart at the selected line
                LDA #EXEC_GOTO
                STA EXECACTION
                BRA done

if_notaken      TRACE "FALSE"
                CALL SKIPSTMT               ; Skip to the next EOL or ":"
                BRA done

                ; ---- IF <test> THEN / ELSE / ENDIF ----
if_block        setas
                LDA @l IFTRUE
                BNE done                    ; true: fall into the body

                setaxl                      ; false: to the ELSE or the ENDIF,
                LDA #TOK_IF                 ;  whichever comes first at this
                LDX #TOK_ENDIF              ;  level
                LDY #TOK_ELSE
                CALL BLK_SET
                CALL SKIPBLOCK

done            PLP
                RETURN

syntax_err      THROW ERR_SYNTAX
not_found       THROW ERR_NOLINE
                .pend

; End the execution of the program
S_END           .proc
                PHP
                TRACE "S_END"

                setas                       ; Signal a stop to the interpreter
                LDA #EXEC_STOP
                STA EXECACTION

                PLP
                RETURN
                .pend

; Start executing the designated line
S_GOTO          .proc
                PHP
                TRACE "S_GOTO"

                CALL TARGET_FIND            ; a line number, or a LABEL
                BCC not_found

                setas                       ; Tell the interpreter to restart at the selected line
                LDA #EXEC_GOTO
                STA EXECACTION

                PLP
                RETURN

syntax_err      THROW ERR_SYNTAX
not_found       THROW ERR_NOLINE
                .pend

; Reset heap and variables
S_CLR           .proc
                TRACE "S_CLR"

                CALL INITEVALSP             ; Initialize stacks
                CALL INITHEAP               ; Initialize the heap
                CALL INITVARS               ; Initialize the variables

                RETURN
                .pend

; Set a variable to a value
; Format:   LET name = expr
;           name = expr
S_LET           .proc
                PHP

                TRACE "S_LET"

                LDA [BIP]           ; Get the character
                BPL get_name        ; If it's not a token, try to find the variable name

                CALL INCBIP         ; Skip over the token

get_name        CALL VAR_FINDNAME   ; Try to find the variable name
                BCS check_array     ; If we didn't find a name, thrown an error
                JMP syntax_err

check_array     TRACE "check_array"
                setas
                LDA TOFINDTYPE      ; Save the variable name for later
                PHA                 ; (it will get over-written by variable references)
                LDA TOFIND+2
                PHA
                LDA TOFIND+1
                PHA
                LDA TOFIND
                PHA         

                CALL PEEK_TOK       ; Look ahead to the next token
                CMP #TOK_LPAREN     ; Is it a "("
                BNE get_value       ; No: it's a scalar assignment, look for the "="

                LDA #TOK_LPAREN
                CALL EXPECT_TOK     ; Skip any whitespace before the open parenthesis

                LDA #0
                STA @l ARRIDXBUF    ; Blank out the array index buffer
                CALL ARR_GETIDX     ; Yes: get the array indexes

get_value       CALL SKIPWS         ; Scan for an "="
                TRACE "get_value"  

                setas
                LDA [BIP]
                CMP #TOK_EQ
                BEQ found_eq        ; If not found: signal an syntax error
                JMP syntax_err

found_eq        CALL INCBIP         ; Otherwise, skip over it       

                CALL EVALEXPR       ; Evaluate the expression

                PLA                 ; Restore the variable name
                STA TOFIND
                PLA
                STA TOFIND+1
                PLA
                STA TOFIND+2
                PLA
                STA TOFINDTYPE

                AND #$80            ; Is it an array we're setting?
                BEQ set_scalar      ; No: do a scalar variable set

                TRACE "set_array"
                CALL VAR_FIND       ; Try to find the array
                BCC notfound_err

                setal
                LDY #BINDING.VALUE
                LDA [INDEX],Y       ; Save the pointer to the array to CURRBLOCK
                STA CURRBLOCK
                setas
                INY
                INY
                LDA [INDEX],Y
                STA CURRBLOCK+2

                CALL ARR_SET        ; Yes: Set the value of the array cell
                BRA done            ; and we're finished!

set_scalar      TRACE "set_scalar"
                CALL VAR_SET        ; Attempt to set the value of the variable

done            TRACE_L "S_LET DONE", BIP

                PLP
                RETURN

syntax_err      THROW ERR_SYNTAX    ; Throw a syntax error
notfound_err    THROW ERR_NOTFOUND  ; Throw variable name not found
                .pend

; Print expressions to the screen
; Format: PRINT expr  -- print an expression followed by a newline
;         PRINT expr, [expr ...] -- print an expression followed by a TAB
;         PRINT expr; [expr ...]-- print an expression with no newline after
S_PRINT         .proc
                PHP
                TRACE "S_PRINT"

.if SYSTEM == SYSTEM_X816
                setas               ; PRINT #n, ... goes to a file channel.
                CALL PEEK_TOK       ;  S_PRINTCH eats the "#n," and calls
                CMP #'#'            ;  back here, so this cannot recurse
                BNE pr_console      ;  more than once.
                setal
                CALL S_PRINTCH
                PLP
                RETURN
pr_console
.endif
                setas
                CALL PEEK_TOK       ; Look ahead to the next non-whitespace character
                CMP #0              ; Is it EOL or :?
                BEQ pr_nl_exit      ; Yes: just print return

pr_loop         CALL EVALEXPR       ; Attempt to evaluate the expression following
                setas
                LDA ARGTYPE1        ; Get the type of the result
                CMP #TYPE_NAV       ; Is is NAV?
                BEQ check_nl        ; Yes: we are probably just printing a newline

                CMP #TYPE_STRING    ; Is it a string?
                BNE check_int       ; No: check to see if it's an integer
                CALL PR_STRING      ; Yes: print the string
                BRA check_nl

check_int       CMP #TYPE_INTEGER   ; Is it an integer?
                BNE check_float     ; No: check to see if it is a float
                CALL PR_INTEGER     ; Print the integer in ARGUMENT1
                BRA check_nl

check_float     CMP #TYPE_FLOAT     ; Is it a float?
                BNE done            ; No: just quit
                CALL PR_FLOAT       ; Print the float in ARGUMENT1
                BRA check_nl

                ; Check for the next non-whitespace... should be a null, colon, comma, or semicolon
check_nl        CALL SKIPWS
                LDA [BIP]
                BEQ pr_nl_exit      ; If it's nul, print a newline and return
                CMP #':'            ; If it's a colon
                BEQ pr_nl_exit      ; print a newline and return
                CMP #','            ; If it's a comma
                BEQ pr_comma        ; Print a TAB and try another expression
                CMP #';'            ; If it's a semicolon...
                BEQ is_more         ; Print nothing, and try another expression

                THROW ERR_SYNTAX    ; If we get here, we don't have a well formed statement

pr_comma        LDA #CHAR_TAB       ; Print a TAB
                CALL PRINTC

is_more         CALL INCBIP         ; Skip the separator
                CALL SKIPWS         ; Skip any whitespace
                LDA [BIP]           ; Get the character
                BEQ done            ; If it's NULL, return without printing a newline
                CMP #':'            ; If it's a colon
                BEQ done            ; ... return without printing a newline
                BRA pr_loop         ; Otherwise, we should have another expression, try to handle it

pr_nl_exit      CALL PRINTCR        ; Print the newline and finish

done            PLP
                RETURN
                .pend

;
; Print a string in ARGUMENT1
;
; Inputs:
;   ARGUMENT1 = pointer to a string to print
;
PR_STRING       .proc
                PHP
                PHB
                TRACE_L "PR_STRING",ARGUMENT1

                setdp GLOBAL_VARS

                ; setaxl
                ; LDA ARGUMENT1               ; If string is NULL, print nothing
                ; BNE start_print
                ; setas
                ; LDA ARGUMENT1+2
                ; BEQ done

                ; BRK

                setas
start_print     LDY #0
loop            LDA [ARGUMENT1],Y
                BEQ done
                CALL PRINTC
                INY
                BRA loop

done            PLB
                PLP
                RETURN
                .pend

;
; Print an integer in ARGUMENT1
;
; Inputs:
;   ARGUMENT1 = integer to print
;
PR_INTEGER      .proc
                PHP

                setal
                CALL ITOS           ; Convert the integer to a string

                LDA STRPTR          ; Copy the pointer to the string to ARGUMENT1
                STA ARGUMENT1
                LDA STRPTR+2
                STA ARGUMENT1+2
                CALL PR_STRING      ; And print it

                PLP
                RETURN
                .pend

;
; Print an float in ARGUMENT1
;
; Inputs:
;   ARGUMENT1 = floating point number to print
;
PR_FLOAT        .proc
                PHP

                TRACE "PR_FLOAT"

                CALL FTOS           ; Convert the float to a string

                setal
                LDA STRPTR          ; Copy the pointer to the string to ARGUMENT1
                STA ARGUMENT1
                LDA STRPTR+2
                STA ARGUMENT1+2
                CALL PR_STRING      ; And print it

                PLP
                RETURN
                .pend

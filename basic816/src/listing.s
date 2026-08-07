;;;
;;; Routines for listing BASIC programs
;;;

;
; List a program
;
; Inputs:
;   MARG1 = starting line (line number must be >= this to be listed)
;   MARG2 = ending line (line number must be <= this to be listed)
;
LISTPROG    .proc
            PHA
            PHY
            PHD
            PHP
            TRACE "LISTPROG"

            setdp GLOBAL_VARS

            setaxl
            LDA #<>BASIC_BOT
            STA BIP
            STA CURLINE
            LDA #`BASIC_BOT
            STA BIP+2
            STA CURLINE+2

list_loop   JSL FK_TESTBREAK
            BCS throw_break     ; If C: user pressed an interrupt key, stop the listing

            LDY #LINE_NUMBER
            LDA [CURLINE],Y
            BEQ done

            CMP MARG1
            BLT skip_line
            
            CMP MARG2
            BEQ print_line
            BGE done

print_line  CALL LISTLINE
            BRA list_loop

done        PLP
            PLD
            PLY
            PLA
            RETURN

skip_line   CALL NEXTLINE           ; Go to the next line
            BRA list_loop           ; And try again
throw_break THROW ERR_BREAK         ; Throw a BREAK condition
            .pend

;
; Print an entire line of BASIC
;
; Inputs:
;   BIP = pointer to the first byte to print
;
LISTLINE    .proc
            PHP
            TRACE "LISTLINE"

            ; Print the line number
            setaxl
            STA ARGUMENT1
            STZ ARGUMENT1+2
            CALL ITOS           ; Convert the integer to a string

            LDA STRPTR          ; Copy the pointer to the string to ARGUMENT1
            INC A
            STA ARGUMENT1
            LDA STRPTR+2
            STA ARGUMENT1+2
            CALL PR_STRING      ; And print it

            CLC                 ; Move the BIP to the first byte of the line
            LDA CURLINE
            ADC #LINE_TOKENS
            STA BIP
            LDA CURLINE+2
            ADC #0
            STA BIP+2

            setas
            LDA #CHAR_SP
            CALL PRINTC
            setal

loop        CALL LISTBYTE
            BCC loop

            setas
            LDA #CHAR_CR
            CALL PRINTC

            CALL NEXTLINE

            PLP
            RETURN
            .pend

;
; Print the current byte of the BASIC program and increment the BASIC instruction pointer
;
; Inputs:
;   BIP = pointer to the byte to print
;
; Outputs:
;   C is set if the current byte is 0, reset otherwise
LISTBYTE    .proc
            PHP
            PHD
            PHB
            ; TRACE "LISTBYTE"

            setdp <>GLOBAL_VARS
            setdbr `GLOBAL_VARS

            setas
            setxl
            LDA [BIP]           ; Get the current byte
            BEQ end_of_line     ; If it's 0, return with C set
            BMI is_token        ; If it's 0x80 - 0xFF, it's a token

            CALL PRINTC         ; Is not a token, just print the byte
            BRA done            ; And return

            ; An extended token is $FF followed by its sub-id, so the
            ; record has to be found the same way the interpreter finds
            ; it -- and INCBIP at the end has to step over both bytes.
is_token    setal
            CALL TOKAT          ; The 16-bit token value
            CALL GETTOKREC      ; X = the record, in whichever table
            setal
            TXA
            STA INDEX
            LDA #`TOKENS
            STA INDEX+2

pr_default  setdbr `TOKENS
            LDY #TOKEN.name
            LDA [INDEX],Y
            TAX

            CALL PRINTS

done        setal
            CALL TOKSKIP        ; one byte, or two for an extended token
            PLB
            PLD
            PLP
            CLC
            RETURN

end_of_line PLB
            PLD
            PLP
            SEC
            RETURN
            .pend


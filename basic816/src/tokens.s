;;;
;;; Define BASIC tokens
;;;

;
; Token structure and macro
;

TOKEN       .struct name, length, precedence, eval, arity
precedence  .byte \precedence
length      .byte \length
name        .word <>\name
eval        .word <>\eval
arity       .word <>\arity
            .ends

DEFTOK      .macro name, type, precedence, evaluate, arity
            .section data
TOKEN_TEXT  .null \name
            .send data
            .dstruct TOKEN,TOKEN_TEXT,len(\name),\type | \precedence,\evaluate,\arity
            .endm

; ---------------------------------------------------------------------
; TOKENS OF ONE, TWO AND THREE BYTES
;
; A token is a byte with bit 7 set, so there are 128 of them and the
; base table filled up. $FF is an ESCAPE: in a tokenized line it means
; "the next byte selects from TOKENS2 instead". That left 127 base ids
; ($80-$FE) and bought 128 more.
;
; THE SECOND ESCAPE, and why it had to come before the next feature
; group rather than after it. 48 items are still on the help pages and
; 43 of them want a keyword nobody has spent an id on yet; TOKENS2 has
; 37 free. So the tables run out before the work does -- and unlike
; running out of BYTES, which is 18 KB away and not close, there is no
; version of finishing help/ that fits without this.
;
; So sub-id $FF of TOKENS2 is now an escape in its turn: $FF $FF <sub>
; selects from TOKENS3. It costs one sub-id and buys 128, and it is the
; same shape as the change that bought TOKENS2 -- deliberately, because
; the machinery for it already exists and only had to learn to count to
; three.
;
; Sub-ids in every table start at $80, still deliberately: nothing has
; to care whether a byte it is scanning past is an id or a sub-id --
; all of them have bit 7 set -- so the many places that only ask
; "token, or character?" keep working untouched.
;
; A token VALUE, as handed to GETTOKREC and its callers, is 16 bits and
; the high byte says which table:
;
;   $00id       the base table, id $80-$FE
;   $FFsub      TOKENS2, sub $80-$FE  ($FF is the escape below)
;   $FEsub      TOKENS3, sub $80-$FF
;
; $FE is free as a selector because a base VALUE is always $00xx, so
; the three ranges cannot collide. TOKAT builds a value from the line
; and TOKSKIP steps over whichever width it is; GETTOKREC is still the
; single place that maps a value to a record, which is what keeps
; TOKTYPE, TOKEVAL, TOKPRECED and TOKARITY out of this entirely.
;
; A TOKENS3 KEYWORD MUST BE AT LEAST THREE CHARACTERS. TKWRITE closes
; the line up by (keyword length - bytes written), and for a two-letter
; keyword written as three bytes that count goes negative and copies
; 255 bytes of the line over itself. DEFTOK3 refuses at assembly time
; rather than leaving it to be found at runtime.
; ---------------------------------------------------------------------
TOK_EXTEND = $FF

;
; Like DEFTOK, but for TOKENS3 -- where a keyword shorter than the
; token that replaces it would make TKWRITE close the line up by a
; negative number.
;
DEFTOK3     .macro name, type, precedence, evaluate, arity
            .cerror len(\name) < 3, "A TOKENS3 keyword needs at least three characters: it is written as three bytes"
            DEFTOK \name, \type, \precedence, \evaluate, \arity
            .endm

.section globals
TKTAB       .dword ?        ; the table TKMATCH is currently searching
TKEXT       .byte ?         ; which table a match came from: 0, 2 or 3
.send


;
; Token routines
;

;
; Parse an integer
;
; Inputs:
;   BIP = pointer to the first digit of the number
;
; Outputs:
;   ARGUMENT1 = the value of the number read.
;
PARSEINT    .proc
            TRACE "PARSEINT"
            PHP
            PHD

            setdp GLOBAL_VARS

            setaxl
            STZ ARGUMENT1       ; Default to Not-a-value
            STZ ARGUMENT1+2
            setas
            STZ ARGTYPE1

            LDA [BIP]           ; Check to see if it starts with '$'
            CMP #'&'        
            BEQ check_hex       ; Yes: parse it as a hexadecimal number

loop        setas
            LDA [BIP]           ; Get the next character
            CALL ISNUMERAL      ; Is it a numeral?
            BCC done            ; No, we're done parsing
                
            CALL MULINT10       ; Yes: multiply ARGUMENT1 by 10

            SEC                 ; Convert the ASCII code to a number
            SBC #'0'

            setal               ; Add it to ARGUMENT1
            AND #$00FF
            CLC
            ADC ARGUMENT1
            STA ARGUMENT1
            LDA ARGUMENT1+2
            ADC #0
            STA ARGUMENT1+2

            CALL INCBIP         ; And move to the next byte
            BRA loop            ; And try to process it

syntaxerr   THROW ERR_SYNTAX    ; Throw a syntax error

check_hex   CALL INCBIP         ; Skip the '&'
            LDA [BIP]           ; Check the next character
            CMP #'H'            ; Is it 'H'?
            BEQ parse_hex       ; Yes: skip it and parse hex
            CMP #'h'            ; Is it 'h'?
            BNE syntaxerr       ; No: throw an error

parse_hex   CALL INCBIP

hexloop     setas
            LDA [BIP]           ; Get the next character
            CALL ISHEX          ; Is it a numeral?
            BCC done            ; No, we're done parsing

            CALL HEX2BIN        ; Convert hex to binary

            setal
            .rept 4             ; ARGUMENT1 << 4
            ASL ARGUMENT1
            ROL ARGUMENT1+2
            .next

            AND #$00FF          ; Add binary number to ARGUMENT1
            CLC
            ADC ARGUMENT1
            STA ARGUMENT1

            CALL INCBIP         ; And move to the next byte
            BRA hexloop         ; And try to process it            

done        PLD
            PLP
            RETURN
            .pend

;
; Return the first non-whitespace character on the current line 
; that comes before the current character
;
; Inputs:
;   BIPPREV = pointer to the current character begin tokenized
;   CURLINE = pointer to the first byte of the line
;
; Returns:
;   A = the character found, 0 if none.
;
PREVCHAR    .proc
            PHP
            TRACE "PREVCHAR"

            setaxl
            LDA BIPPREV
            BEQ ret_false

            SEC
            LDA BIPPREV
            SBC CURLINE
            TAY
            setas
.if SYSTEM == SYSTEM_X816
            LDA #0                  ; assume a base id until proved otherwise
            STA @l PREVEXT
.endif

loop        LDA [CURLINE],Y
            BEQ ret_false
            CMP #CHAR_SP
            BEQ go_back
            CMP #CHAR_TAB
            BEQ go_back

.if SYSTEM == SYSTEM_X816
            ; Say which TABLE this byte's token came from, by counting
            ; the $FF escapes in front of it: none is a base id, one is
            ; a TOKENS2 sub-id, two is a TOKENS3 one. The minus rule
            ; below has to know, because the same number means a
            ; different keyword in each table.
            ;
            ; Two escapes is unambiguous: sub-id $FF of TOKENS2 is the
            ; second escape and is never allocated to a keyword, which
            ; is what the .cerror on that table holds it to.
            ;
            ; Y is balanced on every path out of this -- the INY at
            ; pc_yback undoes the one DEY that is live when it is
            ; reached.
            PHA
            CPY #1
            BCC pc_notext           ; nothing in front of it at all
            DEY
            LDA [CURLINE],Y
            CMP #TOK_EXTEND
            BNE pc_yback
            LDA #2                  ; one escape: TOKENS2
            STA @l PREVEXT
            CPY #1
            BCC pc_yback            ; no room for a second
            DEY
            LDA [CURLINE],Y
            INY
            CMP #TOK_EXTEND
            BNE pc_yback
            LDA #3                  ; two escapes: TOKENS3
            STA @l PREVEXT
pc_yback    INY
pc_notext   PLA
.endif
            TRACE_A "/PREVCHAR"
            PLP
            RETURN

go_back     DEY
            CPY #$FFFF
            BNE loop


            ; The PLP here was missing. PHP at the top pushes one byte,
            ; RTS pops two for a return address, so taking this path --
            ; which the CALLER expects to take, it tests for the 0 --
            ; jumped into hyperspace. Typing a line that begins with a
            ; minus sign was enough to do it. Guarded so that the C256
            ; build still reproduces stock; it has the same bug.
ret_false   TRACE "/PREVCHAR"
.if SYSTEM == SYSTEM_X816
            ; SEP, not decoration. This label is reached two ways: from
            ; the loop below, where A is already 8 bits, and from the
            ; "BIPPREV is zero" test at the top, where setaxl has just
            ; made it 16. The assembler only sees the last setas in
            ; program order, so it emits a TWO-byte LDA #0 -- and
            ; arriving here 16 bits wide, that instruction eats the
            ; opcode after it and execution walks off into the line.
            ;
            ; That is what actually broke a line beginning with a minus
            ; sign, and the missing PLP below only made the wreck worse.
            setas
.endif
            LDA #0
.if SYSTEM == SYSTEM_X816
            PLP
.endif
            RETURN
            .pend

;
; Convert all the keywords to tokens in a line of BASIC text
;
; Inputs:
;   CURLINE = the pointer to the beginning of the line of BASIC
;
TOKENIZE    .proc
            PHP
            PHD

            TRACE "TOKENIZE"

            setdp GLOBAL_VARS

            setaxl                  ; BIP := CURLINE
            LDA CURLINE
            STA BIP
            setas
            LDA CURLINE+2
            STA BIP+2

            CALL SKIPWS             ; Skip over whitespace

            LDA [BIP]               ; Do we have a numeral?
            CALL ISNUMERAL
            BCC mv_curline          ; No: adjust CURLINE and tokenize

            CALL PARSEINT           ; Try to parse the number
            setal                   ; LINENUM := result
            LDA ARGUMENT1
            STA LINENUM

            CALL SKIPWS

mv_curline  setal                   ; CURLINE := BIP (current position)
            LDA BIP
            STA CURLINE
            setas
            LDA BIP+2
            STA CURLINE+2

            CALL FINDREM            ; Prescan for REM to tokenize it
                                    ; this is done to keep the tokenizer from altering comments

            setas
loop        CALL TKFINDTOKEN        ; Find the next token in the line
            CMP #0                  ; Did we find a token?
            BEQ done                ; No: return

            CALL TKWRITE            ; Yes: write the token to the line
            BRA loop                ; And try again

done        PLD
            PLP
            RETURN
            .pend

;
; Prescan a line for "REM". If the keyword is found, convert it to its token.
;
; Inputs:
;   CURLINE = pointer to the bytes to tokenize
;   
FINDREM     .proc
            PHP

            setal
            LDA CURLINE             ; Point BIP to the beginning of the line
            STA BIP
            LDA CURLINE+2
            STA BIP+2

            LDX #0                  ; X will be a flag that we're at the beginning

            setas

loop        LDY #0
            CPX #0                  ; If we are at the first space on the line
            BEQ skip_delim          ; ... skip looking for a delimiter

            ; REM must be preceded by a space or a colon

            LDA [BIP],Y             ; Get the first character
            BEQ done                ; Is it null? Then we're done
            CMP #':'                ; Is it ":"
            BEQ found_delim         ; Yes: we might have a REM... look for E
            CMP #CHAR_SP
            BNE next_pos            ; No: we didn't find REM here... check next position

found_delim INY

skip_delim  LDA [BIP],Y             ; Get the first character
            BEQ done                ; Is it null? Then we're done
            CMP #'R'                ; Is it "R"
            BEQ found_R             ; Yes: we might have a REM... look for E
            CMP #'r'
            BNE next_pos            ; No: we didn't find REM here... check next position

            LDA [BIP],Y             ; Get the first character
            BEQ done                ; Is it null? Then we're done
            CMP #'R'                ; Is it "R"
            BEQ found_R             ; Yes: we might have a REM... look for E
            CMP #'r'
            BNE next_pos            ; No: we didn't find REM here... check next position

found_R     INY

            LDA [BIP],Y             ; Get the first character
            BEQ done                ; Is it null? Then we're done
            CMP #'E'                ; Is it "E"
            BEQ found_E             ; Yes: we might have a REM... look for M
            CMP #'e'
            BNE next_pos            ; No: we didn't find REM here... check next position

found_E     INY

            LDA [BIP],Y             ; Get the first character
            BEQ done                ; Is it null? Then we're done
            CMP #'M'                ; Is it "E"
            BEQ found_REM           ; Yes: we might have a REM... look for M
            CMP #'m'
            BEQ found_REM

next_pos    INX                     ; Indicate we're no longer at the first position
            CALL INCBIP             ; Move to the next byte in the string
            BRA loop

            ; We found REM... tokenize it and return
found_REM   LDA [BIP]               ; Get the current character
            CMP #':'                ; Is it the delimiter?
            BNE ret_REM             ; No: go ahead and return REM at that location

            CALL INCBIP             ; Otherwise: skip over the colon

ret_REM     LDA #3
            STA CURTOKLEN           ; Set the size

            LDA #TOK_REM            ; And the token to write

            CALL TKWRITE            ; And write the token

done        PLP
            RETURN
            .pend

;
; Find a spot in the current BASIC input line that can be replaced with a token.
;
; Inputs:
;   CURLINE = pointer to the beginning of a line of BASIC text (NUL terminated)
;
; Outputs:
;   A = the token to write to the string (0 if none found)
;   BIP = the position requiring the token
;   CURTOKLEN = the length of the token keyword found
;   
TKFINDTOKEN .proc
            PHP
            PHD
            TRACE "TKFINDTOKEN"

            setdp GLOBAL_VARS

            setas
            LDA #$7F                ; Start off looking for any size token
            STA CURTOKLEN

next_size   setxl
            CALL TKNEXTBIG          ; Find the size of the token to find
            LDA CURTOKLEN           ; Are there any keywords left?
            BNE else               
            JMP done                ; No: return to caller

else        setal                   ; Set BIP to the beginning of the line
            LDA CURLINE
            STA BIP
            setas
            LDA CURLINE+2
            STA BIP+2

            setal
            STZ BIPPREV             ; Clear BIPPREV (point to the previous character)
            STZ BIPPREV+2

            ; Check to see if there's room for the token keyword left in the string
check_len   setaxs
            LDY #0
nul_scan    LDA [BIP],Y
            BEQ next_size
            CMP #TOK_REM            ; Tokenization stops at REMarks too
            BEQ next_size

            INY
            CPY CURTOKLEN
            BCC nul_scan
            setxl

            LDA [BIP]               ; Check the current character
            CMP #CHAR_DQUOTE        ; Is it a double quote?
            BNE chk_keyword         ; No: check to see if we are at the start of a possible keyword

            CALL SKIPQUOTED         ; Yes: skip to the next double quote
            BRA go_next             ; And move on to the next character

            ; Check for keyword delimiters
            ; Tokens longer than one character need a whitespace in front of them
            ; or have to be the first thing on the line
chk_keyword LDA CURTOKLEN           ; If the token length is <=2
            CMP #3
            BLT try_match           ; ... we don't need a delimiter, go ahead and convert it

            setal
            LDA BIP                 ; Check to see if we're at the start of the line   
            CMP CURLINE
            BNE chk_delim           ; No: we need to check for a delimiters
            setas
            LDA BIP+2
            CMP CURLINE+2
            BEQ try_match           ; Yes: this can be a keyword

            ; In the middle of the line... need a non-alphanumeric character delimiter
chk_delim   TRACE "chk_delim"
            setas
            LDA [BIPPREV]           ; Get the previous character
            CALL ISVARCHAR          ; Is it a possible variable name character?
            BCS go_next             ; Yes: we can't start a keyword here

            ; There is room for the token left in the string
try_match   setas
            CALL TKSEARCH           ; Try both tables
            CMP #0                  ; Did we get one?
            BNE found               ; Yes: return it

go_next     setal
            LDA BIP                 ; Update BIPPREV as the point to the previous character
            STA BIPPREV
            setas
            LDA BIP+2
            STA BIPPREV+2

            CALL INCBIP             ; Move to the next character in the line
            BRA check_len           ; And try there

found       TRACE_A "found"
            PHA                     ; An extended token is never MINUS, and
            LDA TKEXT               ;  its sub-id could collide with one
            BEQ found_base
            PLA
            BRA done
found_base  PLA
            CMP #TOK_MINUS          ; Found a token... is it minus?
            BNE done                ; Nope: go ahead and return it

            CALL PREVCHAR           ; Get the character (or token) just before this (ignoring white space)
            CMP #0                  ; Did we get anything?
            BEQ syntax              ; No: line cannot start with minus... throw error

            ; A COMMA CANNOT END AN EXPRESSION, so a minus after one
            ; always begins a new one. Without this, every argument list
            ; with a negative in it was wrong: the test below asks "is
            ; the previous thing a TOKEN", and a comma is a plain
            ; character here -- statements compare it with LDA #',' and
            ; no id was ever spent on it -- so it fell through to
            ; BINARY minus.
            ;
            ; It was quiet because it needs an argument list to show:
            ; "PRINT A,-2" printed -4 and "PRINT (5),-2" printed -6 on
            ; every build before this one. An open parenthesis was
            ; always right, being a real token (TOK_LPAREN), which is
            ; why "MID$(s$,-1)" was the shape that failed and "(-1)" was
            ; not.
            CMP #','
            BEQ negative

            BIT #$80                ; Is it a token?
            BEQ binaryminus         ; No: leave token unchanged

            CMP #TOK_RPAREN         ; Is the token a right parenthesis?
            BEQ binaryminus         ; Yes: then this should be a binary minus operator
.if SYSTEM == SYSTEM_X816
            CALL TKPREVFN           ; a no-argument function ends in itself
            BCS binaryminus
.endif

negative    TRACE "make negative"
            LDA #TOK_NEGATIVE       ; Otherwise: this should be a unary minus (negation)
            BRA done

binaryminus LDA #TOK_MINUS          ; It's data... so token should be for binary minus

done        TRACE "/TKFINDTOKEN"
            PLD
            PLP
            RETURN

syntax      THROW ERR_SYNTAX        ; Throw a syntax error
            .pend

.if SYSTEM == SYSTEM_X816
;
; Carry set when the token byte in A (8 bits) is a FUNCTION token.
;
; A function token sitting immediately in front of a minus can only be a
; NO-ARGUMENT one: anything that takes parentheses would have ended in
; ")" and been dealt with before this is reached. So "is this a
; no-argument function" is just "is this a function", which the token
; record already says.
;
; That replaces a list of special cases -- TIMER and FRAMES -- which
; could never have been extended to the second token table, because
; there the comparison would have been against a sub-id that may well
; be the same number as some unrelated base one. PREVEXT is what tells
; the two apart.
;
; A is not preserved, and the caller does not want it back.
;
; No PHP. The answer is in the carry, and a PLP would put the caller's
; carry back over it -- the same mistake that cost an afternoon in
; X816/input_x816.s, where it made every I2C transfer look acknowledged.
;
TKPREVFN    .proc
            PHX
            PHY

            setal
            AND #$00FF
            STA @l TKPF_W
            setas
            LDA @l PREVEXT
            BEQ tpf_base
            CMP #3
            BEQ tpf_ext3
            setal                   ; a TOKENS2 sub-id: $FFxx
            LDA @l TKPF_W
            ORA #$FF00
            STA @l TKPF_W
            BRA tpf_base

tpf_ext3    setal                   ; a TOKENS3 sub-id: $FExx
            LDA @l TKPF_W
            ORA #$FE00
            STA @l TKPF_W

tpf_base    setal
            LDA @l TKPF_W
            CALL TOKTYPE            ; restores its own width, bank and page
            CMP #TOK_TY_FUNC
            BNE tpf_no

            setas
            LDA #1
            BRA tpf_out
tpf_no      setas
            LDA #0
tpf_out     STA @l TKPF_R

            PLY
            PLX
            LDA @l TKPF_R
            LSR A                   ; bit 0 into the carry
            RETURN
            .pend
.endif

;
; Look for the window's keyword in the base table, then in TOKENS2,
; then in TOKENS3.
;
; Outputs:
;   A = the id, or the SUB-id when TKEXT says which table; 0 if there
;       is no match anywhere
;   TKEXT = 0 for a base token, 2 for TOKENS2, 3 for TOKENS3
;
TKSEARCH    .proc
            PHP
            setas
            STZ TKEXT

            setal
            LDA #<>TOKENS
            STA TKTAB
            LDA #`TOKENS
            STA TKTAB+2
            setas
            CALL TKMATCH
            CMP #0
            BNE ts_done             ; Found in the base table

            setal
            LDA #<>TOKENS2
            STA TKTAB
            LDA #`TOKENS2
            STA TKTAB+2
            setas
            CALL TKMATCH
            CMP #0
            BEQ ts_three            ; Not there either: try the third

            PHA
            LDA #2
            STA TKEXT
            PLA
            BRA ts_done

ts_three    setal
            LDA #<>TOKENS3
            STA TKTAB
            LDA #`TOKENS3
            STA TKTAB+2
            setas
            CALL TKMATCH
            CMP #0
            BEQ ts_done             ; Not anywhere

            PHA
            LDA #3
            STA TKEXT
            PLA

ts_done     PLP
            RETURN
            .pend

;
; Skip to the character after the first double quote
;
; Inputs:
;   BIP = pointer to the BASIC line where we need to skip over the next quote
;
SKIPQUOTED  .proc
            PHP
            setas

loop        CALL INCBIP             ; Advance the BIP
            LDA [BIP]
            BEQ done                ; If EOL, just return
            CMP #CHAR_DQUOTE        ; Is it a double quote?
            BNE loop                ; No: keep skipping

done        PLP
            RETURN
            .pend

;
; Try to find a matching token in the list of tokens
;
; Inputs:
;   BIP = start of window in the line of BASIC text to match
;   CURTOKLEN = length of window (tokens must be of this size)
;
; Outputs:
;   A = token that matches (0 if none)
;
TKMATCH     .proc
            PHX
            PHY
            PHP
            PHD

            setdp GLOBAL_VARS

            setal
            LDA BIPPREV
            BNE check_prev
            setas
            LDA BIPPREV
            BNE check_prev

            LDA #0
            BRA save_delim

            ; Store in SIGN1 if the previous character could be part of a variable name
check_prev  setas
            LDA [BIPPREV]           ; Get the previous character
            CALL ISVARCHAR          ; Is it a possible variable name character?
            LDA #0
            ROL A
save_delim  STA SIGN1               ; SIGN1 := 1 if it is a variable name character

            setaxl
            LDA TKTAB               ; Search whichever table TKSEARCH chose
            STA INDEX
            setas
            LDA TKTAB+2
            STA INDEX+2

            LDX #$80                ; Set the initial token ID
            
token_loop  setas
            LDY #TOKEN.length
            LDA [INDEX],Y           ; Get the length of the current token
            BEQ no_match            ; Is it 0? We're out of tokens... no match found
            CMP CURTOKLEN           ; Is it the same as the size of the window?
            BNE next_token          ; No: try the next token

            setaxl
            LDY #TOKEN.name
            LDA [INDEX],Y           ; Get the pointer to the token's name
            STA SCRATCH             ; Set SCRATCH to point to the token's name
            setas
            LDA #`DATA_BLOCK
            STA SCRATCH+2

            ; If the previous character could be part of a variable name,
            ; Make sure this token starts with a special character
            LDA SIGN1               ; Is previous character a variable name character?
            BEQ cmp_keyword         ; No: we can check for this token

            LDA [SCRATCH]           ; Get the token's first character
            CALL ISVARCHAR          ; Is it a variable name character?
            BCS next_token          ; Yes: skip this token

            ; Check to see if the window contains the token's name
cmp_keyword setxs
            LDY #0
cmp_loop    LDA [BIP],Y             ; Get the character in the window
            CALL TOUPPERA           ; Convert the character to upper case for a case insensitive search
            CMP [SCRATCH],Y         ; Compare to the character in the token
            BNE next_token          ; If they don't match, try the next token
            INY                     ; Move to the next character in the window
            CPY CURTOKLEN           ; Have we checked the whole window?
            BCC cmp_loop            ; No: check this next character

            ; We found the matching token
            TXA                     ; Move the token ID to A

no_match    PLD
            PLP
            PLY
            PLX
            RETURN

next_token  setaxl                  ; Point INDEX to the next token record
            CLC
            LDA INDEX
            ADC #size(TOKEN)
            STA INDEX
            setas
            LDA INDEX+2
            ADC #0
            STA INDEX+2

            INX                     ; Increment the token ID
            BRA token_loop          ; And check that token
            .pend

;
; Given a token length in CURTOKLEN, set CURTOKLEN to
; the size of the next biggest token.
;
TKNEXTBIG   .proc
            PHP
            PHD
            PHB

            setdp GLOBAL_VARS

            setaxl                  ; Point INDEX to the first token record
            LDA #<>TOKENS
            STA INDEX
            LDA #`TOKENS
            STA INDEX+2

            STZ SCRATCH             ; Clear SCRATCH

            ; ALL THREE tables have to be walked, or a keyword whose
            ; length only occurs in one of the later ones would never be
            ; tried and the token would simply never be recognised.
            LDA #0
            STA SCRATCH2            ; SCRATCH2 = which table we are on

loop        setas
            LDY #TOKEN.length
            LDA [INDEX],Y           ; Get the length of the token
            BEQ done                ; If length is 0, we're done
            CMP CURTOKLEN           ; Is it >= CURTOKLEN?
            BGE skip                ; Yes: skip to the next token
            CMP SCRATCH             ; No: is it < SCRATCH?
            BLT skip                ; Yes: skip to the next token
            STA SCRATCH             ; No: it's our new longest token!

skip        setal                   ; Point INDEX to the next token record
            CLC
            LDA INDEX
            ADC #size(TOKEN)
            STA INDEX
            LDA INDEX+2
            ADC #0
            STA INDEX+2

            BRA loop                ; And go around for another pass

done        setal                   ; One table finished: go round again on
            LDA SCRATCH2            ;  the next, until all three are done
            BNE tnb_two
            LDA #1
            STA SCRATCH2
            LDA #<>TOKENS2
            STA INDEX
            LDA #`TOKENS2
            STA INDEX+2
            BRA loop

tnb_two     CMP #1
            BNE tnb_finish
            LDA #2
            STA SCRATCH2
            LDA #<>TOKENS3
            STA INDEX
            LDA #`TOKENS3
            STA INDEX+2
            BRA loop

tnb_finish  setas                   ; Copy the length we found to CURTOKLEN
            LDA SCRATCH
            STA CURTOKLEN

            PLB
            PLD
            PLP
            RETURN
            .pend

;
; Collapse line
; Given a position in a BASIC line, replace the first byte
; with a token and shrink the line by the size of the token's keyword
;
; Inputs:
;   A = the token to write to the line
;   BIP = the address of the byte to change
;   CURTOKLEN = the length of the token's keyword
;
TKWRITE     .proc
            PHP
            TRACE "TKWRITE"
            PHD

            setdp GLOBAL_VARS

            setas
            setxs
            LDX TKEXT               ; One byte, two for TOKENS2, three for
            BEQ tw_base             ;  TOKENS3
            CPX #3
            BEQ tw_ext3

            LDY #1                  ; $FF then the sub-id
            STA [BIP],Y
            LDA #TOK_EXTEND
            STA [BIP]
            LDA #2
            BRA tw_written

tw_ext3     LDY #2                  ; $FF $FF then the sub-id. The sub-id
            STA [BIP],Y             ;  goes down FIRST: A is holding it and
            LDA #TOK_EXTEND         ;  the escapes are about to overwrite A.
            LDY #1
            STA [BIP],Y
            STA [BIP]
            LDA #3
            BRA tw_written

tw_base     STA [BIP]               ; Write the token to the line
            LDA #1

tw_written  setal                   ; SCRATCH2 = bytes the token occupies.
            AND #$00FF              ;  Clear the high byte: it was just an
            STA SCRATCH2            ;  8-bit 1 or 2.

            CLC                     ; INDEX = BIP + those bytes
            LDA BIP
            ADC SCRATCH2
            STA INDEX
            LDA BIP+2
            ADC #0
            STA INDEX+2

            setxs
            setas
            LDA CURTOKLEN           ; Characters to close up: the keyword
            SEC                     ;  length, less what was written
            SBC SCRATCH2
            TAY

copy_down   setas
            LDA [INDEX],Y           ; Get the byte to move down
            STA [INDEX]             ; Move it down
            BEQ done                ; We've reached the end of the line

            setal                   ; INDEX++
            CLC
            LDA INDEX
            ADC #1
            STA INDEX
            LDA INDEX+2
            ADC #0
            STA INDEX+2

            BRA copy_down

done        PLD
            PLP
            RETURN
            .pend

;
; Compute the address of the token record for a given operator token
;
; Inputs:
;   A = the operator token
;
; Outputs:
;   X = the bank relative address for the operator's token record
;
; Inputs:
;   A = a 16-bit token VALUE: $00id base, $FFsub TOKENS2, $FEsub
;       TOKENS3. This is the single place that knows there are three
;       tables, which is why TOKTYPE, TOKEVAL, TOKPRECED and TOKARITY
;       have needed no change through either escape.
;
GETTOKREC   .proc
            PHP

            setaxl
            CMP #$FE00                  ; A base value is always $00xx, so
            BCC gtr_base                ;  the three ranges cannot collide
            CMP #$FF00
            BCC gtr_ext3

            AND #$007F                  ; $FFxx: TOKENS2
            ASL A
            ASL A
            ASL A
            CLC
            ADC #<>TOKENS2
            TAX
            PLP
            RETURN

gtr_ext3    AND #$007F                  ; $FExx: TOKENS3
            ASL A
            ASL A
            ASL A
            CLC
            ADC #<>TOKENS3
            TAX
            PLP
            RETURN

gtr_base    AND #$007F
            ASL A
            ASL A
            ASL A
            CLC
            ADC #<>TOKENS
            TAX                         ; X is the data-bank relative address
            PLP
            RETURN
            .pend

;
; Read the token at BIP as a 16-bit token value.
;
; Callers must be in 16-bit A: the value does not fit in eight bits, and
; that is the whole point of it.
;
; Outputs:
;   A = $00id, $FFsub for TOKENS2, $FEsub for TOKENS3
;
TOKAT       .proc
            PHP
            setaxl                      ; WIDTH FIRST, then the push. The
            PHY                         ;  other way round PHY saves at the
                                        ;  caller's index width and the PLY
                                        ;  below pops sixteen bits, which
                                        ;  unbalances the stack for every
                                        ;  caller that was in 8-bit index
                                        ;  mode -- EXECSTMT is one.
            setas
            LDA [BIP]
            CMP #TOK_EXTEND
            BEQ ta_ext
            setal
            AND #$00FF
            BRA ta_done

            ; setas, and it is NOT decoration. This is a branch TARGET,
            ; and the assembler's idea of the accumulator width here is
            ; whatever the line ABOVE left -- which is the 16-bit AND on
            ; the base path, not the 8-bit state the BEQ arrives in. So
            ; CMP #TOK_EXTEND assembled as a 16-bit immediate, the CPU
            ; read two of its three bytes and executed the third, $00,
            ; as a BRK. Every extended token in the language reset the
            ; machine. PORT.md 14, 15, 19 and now this: the width has to
            ; be re-declared at a label, not inherited past one.
ta_ext      setxl
            setas
            LDY #1
            LDA [BIP],Y                 ; the sub-id -- unless it is the
            CMP #TOK_EXTEND             ;  second escape, in which case the
            BEQ ta_ext3                 ;  one after it is
            setal
            AND #$00FF
            ORA #$FF00
            BRA ta_done

ta_ext3     setas                       ; a branch target: see the note above
            LDY #2
            LDA [BIP],Y
            setal
            AND #$00FF
            ORA #$FE00

ta_done     PLY
            PLP
            RETURN
            .pend

;
; Step BIP over the token it points at, whichever width it is.
;
TOKSKIP     .proc
            PHP
            setaxl                      ; WIDTH FIRST, then the push -- the
            PHY                         ;  same trap TOKAT records above
            setas
            LDA [BIP]
            CMP #TOK_EXTEND
            BNE ts_single
            LDY #1
            LDA [BIP],Y
            CMP #TOK_EXTEND
            BNE ts_two
            CALL INCBIP                 ; three bytes: $FF $FF sub
ts_two      CALL INCBIP
ts_single   CALL INCBIP
            setaxl
            PLY
            PLP
            RETURN
            .pend

;
; Get the precedence of a token
;
; Inputs:
;   A = the token ID
;
; Outputs:
;   A = the precedence of the token
;
TOKPRECED   .proc
            PHP
            PHB
            PHD

            setdp GLOBAL_VARS
            setdbr `TOKENS

            setas
            setxl

            CALL GETTOKREC              ; Get the address of the token record into X
            LDA #TOKEN.precedence,B,X   ; Get the precedence

            setal
            AND #$000F                  ; Mask off the type code
            
            PLD
            PLB
            PLP
            RETURN
            .pend

;
; Get the address of the token's evaluation function
;
; Inputs:
;   A = the token ID
;
; Outputs:
;   A = the address (within the code bank) of the evaluation function
;
TOKEVAL     .proc
            PHP
            PHB
            PHD

            setdp GLOBAL_VARS
            setdbr `TOKENS

            setaxl
            CALL GETTOKREC              ; Get the address of the token record into X
            LDA #TOKEN.eval,B,X         ; Get the address of the evaluation function

            PLD
            PLB
            PLP
            RETURN
            .pend

;
; Return the token type for the given token
;
; Inputs:
;   A = the token ID
;
; Outputs:
;   A = the type of the token
;
TOKTYPE     .proc
            PHP
            PHB
            PHD

            setdp GLOBAL_VARS
            setdbr `TOKENS

            setas
            setxl

            CALL GETTOKREC              ; Get the address of the token record into X
            LDA #TOKEN.precedence,B,X   ; Get the precedence

            setal
            AND #$00F0                  ; Mask off the type code
            
            PLD
            PLB
            PLP
            RETURN
            .pend

;
; Return the token arity for the given token. Only really used for operators
;
; Inputs:
;   A = the token ID
;
; Outputs:
;   A = the arity of the token (0, 1, 2)
;
TOKARITY    .proc
            PHP
            PHB
            PHD

            setdp GLOBAL_VARS
            setdbr `TOKENS

            setas
            setxl

            CALL GETTOKREC              ; Get the address of the token record into X
            LDA #TOKEN.arity,B,X        ; Get the arity

            setal
            AND #$00FF
            
            PLD
            PLB
            PLP
            RETURN
            .pend

;;;
;;; Token Table
;;;

TOK_EOL = $00
TOK_FUNC_OPEN = $01     ; A pseudo-token to push to the operator stack to mark
                        ; the left parenthesis of a function argument list

TOK_TY_OP = $00         ; The token is an operator
TOK_TY_CMD = $10        ; The token is a command (e.g. RUN, LIST, etc.)
TOK_TY_STMNT = $20      ; The token is a statement (e.g. INPUT, PRINT, DIM, etc.)
TOK_TY_FUNC = $30       ; The token is a function (e.g. SIN, COS, TAB, etc.)
TOK_TY_PUNCT = $40      ; The token is a punctuation mark (e.g. "(", ")")
TOK_TY_BYWRD = $50      ; The token is a by-word (e.g. STEP, TO, WEND, etc.)

;
; The token table
;

TOKENS      
TOK_PLUS = $80
            DEFTOK "+", TOK_TY_OP, 3, OP_PLUS, 2
TOK_MINUS = $81
            DEFTOK "-", TOK_TY_OP, 3, OP_MINUS, 2
TOK_MULT = $82
            DEFTOK "*", TOK_TY_OP, 2, OP_MULTIPLY, 2
TOK_DIVIDE = $83
            DEFTOK "/", TOK_TY_OP, 2, OP_DIVIDE, 2
TOK_MOD = $84
            DEFTOK "MOD", TOK_TY_OP, 2, OP_MOD, 2
; $85
            DEFTOK "^", TOK_TY_OP, 0, OP_POW, 2
TOK_LE = $86
            DEFTOK "<=", TOK_TY_OP, 4, OP_LTE, 2
TOK_GE = $87
            DEFTOK ">=", TOK_TY_OP, 4, OP_GTE, 2
TOK_NE = $88
            DEFTOK "<>", TOK_TY_OP, 4, OP_NE, 2
; $89
            DEFTOK "<", TOK_TY_OP, 4, OP_LT, 2
TOK_EQ = $8A
            DEFTOK "=", TOK_TY_OP, 4, OP_EQ, 2
; TOK_GT = $8B
            DEFTOK ">", TOK_TY_OP, 4, OP_GT, 2
; TOK_NOT = $8C
            DEFTOK "NOT", TOK_TY_OP, 5, OP_NOT, 1
; $8D
            DEFTOK "AND", TOK_TY_OP, 6, OP_AND, 2 
; $8E
            DEFTOK "OR", TOK_TY_OP, 7, OP_OR, 2
TOK_LPAREN = $8F
            DEFTOK "(", TOK_TY_PUNCT, $FF, 0, 0
TOK_RPAREN = $90
            DEFTOK ")", TOK_TY_PUNCT, 0, 0, 0

            ; Statements
TOK_REM = $91
            DEFTOK "REM", TOK_TY_STMNT, 0, S_REM, 0
TOK_PRINT = $92
            DEFTOK "PRINT", TOK_TY_STMNT, 0, S_PRINT, 0
TOK_LET = $93
            DEFTOK "LET", TOK_TY_STMNT, 0, S_LET, 0
; $94
            DEFTOK "GOTO", TOK_TY_STMNT, 0, S_GOTO, 0
TOK_END = $95
            DEFTOK "END", TOK_TY_STMNT, 0, S_END, 0
TOK_IF = $96
            DEFTOK "IF", TOK_TY_STMNT, 0, S_IF, 0
TOK_THEN = $97
            DEFTOK "THEN", TOK_TY_BYWRD, 0, 0, 0
; ELSE was a BYWRD with no handler and nothing referenced it: the only
; form of IF was "IF x THEN <line>". It is a statement now, and it can
; be, because reaching it AT ALL means a branch ran to completion.
TOK_ELSE = $98
            DEFTOK "ELSE", TOK_TY_STMNT, 0, S_ELSE, 0
; $99
            DEFTOK "GOSUB", TOK_TY_STMNT, 0, S_GOSUB, 0
; $9A
            DEFTOK "RETURN", TOK_TY_STMNT, 0, S_RETURN, 0
TOK_FOR = $9B
            DEFTOK "FOR", TOK_TY_STMNT, 0, S_FOR, 0
TOK_TO = $9C
            DEFTOK "TO", TOK_TY_BYWRD, 0, 0, 0
TOK_STEP = $9D
            DEFTOK "STEP", TOK_TY_BYWRD, 0, 0, 0
TOK_NEXT = $9E
            DEFTOK "NEXT", TOK_TY_STMNT, 0, S_NEXT, 0
TOK_DO = $9F
            DEFTOK "DO", TOK_TY_STMNT, 0, S_DO, 0
TOK_LOOP = $A0
            DEFTOK "LOOP", TOK_TY_STMNT, 0, S_LOOP, 0
; $A1
            DEFTOK "WHILE", TOK_TY_BYWRD, 0, 0, 0
; $A2
            DEFTOK "UNTIL", TOK_TY_BYWRD, 0, 0, 0
; $A3
            DEFTOK "EXIT", TOK_TY_STMNT, 0, S_EXIT, 0
; $A4
            DEFTOK "CLR", TOK_TY_STMNT, 0, S_CLR, 0
; $A5
            DEFTOK "STOP", TOK_TY_STMNT, 0, S_STOP, 0
; $A6
            DEFTOK "POKE", TOK_TY_STMNT, 0, S_POKE, 0
; $A7
            DEFTOK "POKEW", TOK_TY_STMNT, 0, S_POKEW, 0
; $A8
            DEFTOK "POKEL", TOK_TY_STMNT, 0, S_POKEL, 0
; $A9
            DEFTOK "CLS", TOK_TY_STMNT, 0, S_CLS, 0
; $AA
            DEFTOK "READ", TOK_TY_STMNT, 0, S_READ, 0
TOK_DATA = $AB
            DEFTOK "DATA", TOK_TY_STMNT, 0, S_DATA, 0
; $AC
            DEFTOK "RESTORE", TOK_TY_STMNT, 0, S_RESTORE, 0
; $AD
            DEFTOK "DIM", TOK_TY_STMNT, 0, S_DIM, 0
; $AE
            DEFTOK "CALL", TOK_TY_STMNT, 0, S_CALL, 0

            ; Functions

TOK_NEGATIVE = $AF
            DEFTOK "-", TOK_TY_OP, 0, OP_NEGATIVE, 1
; $B0
            DEFTOK "LEN", TOK_TY_FUNC, 0, FN_LEN, 0
; $B1
            DEFTOK "PEEK", TOK_TY_FUNC, 0, FN_PEEK, 0
; $B2
            DEFTOK "PEEKW", TOK_TY_FUNC, 0, FN_PEEKW, 0
; $B3
            DEFTOK "PEEKL", TOK_TY_FUNC, 0, FN_PEEKL, 0
; $B4
            DEFTOK "CHR$", TOK_TY_FUNC, 0, FN_CHR, 0
; $B5
            DEFTOK "ASC", TOK_TY_FUNC, 0, FN_ASC, 0
; $B6
            DEFTOK "SPC", TOK_TY_FUNC, 0, FN_SPC, 0
; $B7
            DEFTOK "TAB", TOK_TY_FUNC, 0, FN_TAB, 0
; $B8
            DEFTOK "ABS", TOK_TY_FUNC, 0, FN_ABS, 0
; $B9
            DEFTOK "SGN", TOK_TY_FUNC, 0, FN_SGN, 0
; $BA
            DEFTOK "HEX$", TOK_TY_FUNC, 0, FN_HEX, 0
; $BB
            DEFTOK "DEC", TOK_TY_FUNC, 0, FN_DEC, 0
; $BC
            DEFTOK "STR$", TOK_TY_FUNC, 0, FN_STR, 0
; $BD
            DEFTOK "VAL", TOK_TY_FUNC, 0, FN_VAL, 0
; $BE
            DEFTOK "LEFT$", TOK_TY_FUNC, 0, FN_LEFT, 0
; $BF
            DEFTOK "RIGHT$", TOK_TY_FUNC, 0, FN_RIGHT, 0
; $C0
            DEFTOK "MID$", TOK_TY_FUNC, 0, FN_MID, 0

            ; Commands

; $C1
            DEFTOK "RUN", TOK_TY_CMD, 0, CMD_RUN, 0
; $C2
            DEFTOK "NEW", TOK_TY_CMD, 0, CMD_NEW, 0
; $C3
            DEFTOK "LOAD", TOK_TY_CMD, 0, CMD_LOAD, 0
; $C4
            DEFTOK "LIST", TOK_TY_CMD, 0, CMD_LIST, 0
; $C5
            DEFTOK "DIR", TOK_TY_CMD, 0, CMD_DIR, 0
; $C6
            DEFTOK "BLOAD", TOK_TY_STMNT, 0, S_BLOAD, 0
; $C7
.if SYSTEM == SYSTEM_X816
; A STATEMENT here, not a command: with an explicit load address BRUN is
; a load and a JSL that comes back, so there is no reason a program
; cannot use it. One DEFTOK either way, so the ids below do not move.
            DEFTOK "BRUN", TOK_TY_STMNT, 0, CMD_BRUN, 0
.else
            DEFTOK "BRUN", TOK_TY_CMD, 0, CMD_BRUN, 0
.endif
; $C8
            DEFTOK "BSAVE", TOK_TY_STMNT, 0, S_BSAVE, 0
; $C9
            DEFTOK "DEL", TOK_TY_STMNT, 0, S_DEL, 0
; $CA
            DEFTOK "SAVE", TOK_TY_CMD, 0, CMD_SAVE, 0
; $CB
            DEFTOK "RENAME", TOK_TY_STMNT, 0, S_RENAME, 0
; $CC
            DEFTOK "COPY", TOK_TY_STMNT, 0, S_COPY, 0
; $CD
            ; The monitor is not built on the X816, but the keyword stays
            ; and CMD_MONITOR is a stub there that refuses -- see
            ; X816/statements_x816.s.
            ;
            ; An EMPTY name here would have been a disaster. TKNEXTBIG
            ; walks the table until it reads a length of zero, so a
            ; zero-length entry is a TERMINATOR: every keyword after
            ; MONITOR would have quietly stopped existing.
            DEFTOK "MONITOR", TOK_TY_CMD, 0, CMD_MONITOR, 0

; $CE
            DEFTOK "GET", TOK_TY_STMNT, 0, S_GET, 0
; $CF
            DEFTOK "INPUT", TOK_TY_STMNT, 0, S_INPUT, 0
; $D0
            DEFTOK "SETBORDER", TOK_TY_STMNT, 0, S_SETBORDER, 0
; $D1
            DEFTOK "TEXTCOLOR", TOK_TY_STMNT, 0, S_TEXTCOLOR, 0
; $D2
            DEFTOK "SETBGCOLOR", TOK_TY_STMNT, 0, S_SETBGCOLOR, 0
; $D3
            DEFTOK "SETDATE", TOK_TY_STMNT, 0, S_SETDATE, 0
; $D4
            DEFTOK "GETDATE$", TOK_TY_FUNC, 0, F_GETDATE, 0
; $D5
            DEFTOK "SETTIME", TOK_TY_STMNT, 0, S_SETTIME, 0
; $D6
            DEFTOK "GETTIME$", TOK_TY_FUNC, 0, F_GETTIME, 0
; $D7
            DEFTOK "GRAPHICS", TOK_TY_STMNT, 0, S_GRAPHICS, 0
; $D8
            DEFTOK "SETCOLOR", TOK_TY_STMNT, 0, S_SETCOLOR, 0
; $D9
            DEFTOK "BITMAP", TOK_TY_STMNT, 0, S_BITMAP, 0
; $DA
            DEFTOK "CLRBITMAP", TOK_TY_STMNT, 0, S_CLRBITMAP, 0
; $DB
            DEFTOK "PLOT", TOK_TY_STMNT, 0, S_PLOT, 0
; $DC
            DEFTOK "LINE", TOK_TY_STMNT, 0, S_LINE, 0
; $DD
            DEFTOK "FILL", TOK_TY_STMNT, 0, S_FILL, 0
; $DE
            DEFTOK "SPRITE", TOK_TY_STMNT, 0, S_SPRITE, 0
; $DF
            DEFTOK "SPRITEAT", TOK_TY_STMNT, 0, S_SPRITEAT, 0
; $E0
            DEFTOK "SPRITESHOW", TOK_TY_STMNT, 0, S_SPRITESHOW, 0
; $E1
            DEFTOK "TILESET", TOK_TY_STMNT, 0, S_TILESET, 0
; $E2
            DEFTOK "TILEMAP", TOK_TY_STMNT, 0, S_TILEMAP, 0
; $E3
            DEFTOK "TILESHOW", TOK_TY_STMNT, 0, S_TILESHOW, 0
; $E4
            DEFTOK "TILEAT", TOK_TY_STMNT, 0, S_TILEAT, 0
; $E5
            DEFTOK "MEMCOPY", TOK_TY_STMNT, 0, S_MEMCOPY, 0             ; Token for MEMCOPY statement
TOK_LINEAR = $E6
            DEFTOK "LINEAR", TOK_TY_BYWRD, 0, 0, 0                      ; E6 - Keyword for MEMCOPY statement
TOK_RECT = $E7
; RECT was a BY-WORD for MEMCOPY and is now the rectangle statement.
; The tokenizer searches the base table BEFORE the extended one, so a
; name in both is shadowed by the base entry and a second DEFTOK in
; TOKENS2 could never be reached -- "RECT 0,0,10,10" tokenized to this
; bare keyword and reported a syntax error.
;
; MEMCOPY is a stub that throws (help/MEMORY.TXT), so nothing wants the
; by-word today. When it is built it should compare this token by ID
; rather than by TYPE, which is what a keyword doing two jobs costs and
; is cheaper than spending a second id on the same five letters.
; ...on the X816. The C256 keeps the by-word, because S_RECT lives in
; the X816 tree and the base table is unconditional -- one entry either
; way, so no id moves.
.if SYSTEM == SYSTEM_X816
            DEFTOK "RECT", TOK_TY_STMNT, 0, S_RECT, 0                      ; E7
.else
            DEFTOK "RECT", TOK_TY_BYWRD, 0, 0, 0                            ; E7
.endif
; $E8
            DEFTOK "LOCATE", TOK_TY_STMNT, 0, S_LOCATE, 0               ; Token for LOCATE statement
; $E9
            DEFTOK "INT", TOK_TY_FUNC, 0, FN_INT, 0
; $EA
            DEFTOK "RND", TOK_TY_FUNC, 0, FN_RND, 0
; $EB
            DEFTOK "SIN", TOK_TY_FUNC, 0, FN_SIN, 0
; $EC
            DEFTOK "COS", TOK_TY_FUNC, 0, FN_COS, 0
; $ED
            DEFTOK "TAN", TOK_TY_FUNC, 0, FN_TAN, 0
; $EF
            DEFTOK "LN", TOK_TY_FUNC, 0, FN_LN, 0
; $F0
            DEFTOK "ACOS", TOK_TY_FUNC, 0, FN_ACOS, 0
; $F2 
            DEFTOK "ASIN", TOK_TY_FUNC, 0, FN_ASIN, 0
; $F3 
            DEFTOK "ATAN", TOK_TY_FUNC, 0, FN_ATAN, 0
; $F4 
            DEFTOK "EXP", TOK_TY_FUNC, 0, FN_EXP, 0
; $F5
            DEFTOK "SQR", TOK_TY_FUNC, 0, FN_SQR, 0
; $F6
            DEFTOK "INKEY", TOK_TY_FUNC, 0, FN_INKEY, 0

; The SuperBasic string layer (superbasic.s). Portable, so unguarded:
; nothing in it touches hardware and any target gets it.
;
; Three of them, and they are THE LAST THREE TOKENS -- see the .cerror
; at the end of the table.
            DEFTOK "INSTR", TOK_TY_FUNC, 0, FN_INSTR, 0
            DEFTOK "UCASE$", TOK_TY_FUNC, 0, FN_UCASE, 0
            DEFTOK "TRIM$", TOK_TY_FUNC, 0, FN_TRIM, 0

.if SYSTEM == SYSTEM_X816
; Directory navigation. New keywords rather than ports: the C256 kernel
; had no working directory, so BASIC816 never had tokens for these. They
; go at the END of the table on purpose -- token IDs are assigned by
; position from $80 up, so appending leaves every existing one where it
; was and only this platform sees the additions.
            DEFTOK "CD", TOK_TY_STMNT, 0, S_CD, 0
            DEFTOK "PWD", TOK_TY_STMNT, 0, S_PWD, 0
            DEFTOK "MKDIR", TOK_TY_STMNT, 0, S_MKDIR, 0
            DEFTOK "RMDIR", TOK_TY_STMNT, 0, S_RMDIR, 0
; Timing. TIMER and FRAMES take no argument at all -- see the note in
; TKFINDTOKEN about what that costs. Their ids are derived from the
; table rather than written down: token ids run from $80 in table order,
; so this stays right no matter what is inserted above.
TOK_TIMER = $80 + (* - TOKENS) / SIZE(TOKEN)
            DEFTOK "TIMER", TOK_TY_FUNC, 0, FN_TIMER, 0
TOK_FRAMES = $80 + (* - TOKENS) / SIZE(TOKEN)
            DEFTOK "FRAMES", TOK_TY_FUNC, 0, FN_FRAMES, 0
            DEFTOK "WAIT", TOK_TY_STMNT, 0, S_WAIT, 0
.endif

; A token is a byte with bit 7 set, so ids run $80-$FF and there are
; exactly 128 of them. This build now uses every one. Anything further --
; and help/ still lists sprites, sound, graphics and the rest, all
; wanting keywords -- needs a two-byte scheme: one id reserved as an
; escape, whose successor selects from a second table. Every consumer of
; an id would have to learn it: TOKTYPE, TOKEVAL, TOKPRECED, TOKARITY,
; the "is it a token" tests in eval.s and statements.s, and LIST.
;
; Fail here, plainly, rather than in whatever expression first computes
; an id above 255.
; 127, not 128: $FF is TOK_EXTEND, the escape into the table below.
.cerror (* - TOKENS) / SIZE(TOKEN) > 127, "Base token table full: $80-$FE is 127, and $FF is the escape"

            .word 0, 0, 0, 0

;
; The extended table. Reached as $FF <sub-id>, sub-ids running from $80
; exactly as the base ids do -- see the note by TOK_EXTEND.
;
; VSYNC was the 128th token and is here because something had to be:
; freeing $FF for the escape cost one slot. It is also the proof that
; the scheme carries a real statement and not just a spare id.
;
TOKENS2
.if SYSTEM == SYSTEM_X816
            DEFTOK "VSYNC", TOK_TY_STMNT, 0, S_VSYNC, 0
.endif

.if SYSTEM == SYSTEM_X816
; Video. The first feature group to be written since the escape existed,
; and the reason it was worth writing.
            DEFTOK "VPOKE", TOK_TY_STMNT, 0, S_VPOKE, 0
            DEFTOK "VPEEK", TOK_TY_FUNC, 0, FN_VPEEK, 0
            DEFTOK "BORDER", TOK_TY_STMNT, 0, S_BORDER, 0
            DEFTOK "SCROLLX", TOK_TY_STMNT, 0, S_SCROLLX, 0
            DEFTOK "SCROLLY", TOK_TY_STMNT, 0, S_SCROLLY, 0
            DEFTOK "PAL", TOK_TY_STMNT, 0, S_PAL, 0
            DEFTOK "SOUND", TOK_TY_STMNT, 0, S_SOUND, 0
            DEFTOK "SPRITEIMG", TOK_TY_STMNT, 0, S_SPRITEIMG, 0
            DEFTOK "SPRITESIZE", TOK_TY_STMNT, 0, S_SPRITESIZE, 0

; Record I/O. PRINT # and INPUT # need no keywords of their own: the
; ordinary statements look for the "#" themselves, which is both the
; real BASIC spelling and one fewer token spent.
            DEFTOK "OPEN", TOK_TY_STMNT, 0, S_OPEN, 0
            DEFTOK "CLOSE", TOK_TY_STMNT, 0, S_CLOSE, 0
            DEFTOK "EOF", TOK_TY_FUNC, 0, FN_EOF, 0

; Audio. SOUND (the PSG) is above; these are the other two chips.
            DEFTOK "PCMVOL", TOK_TY_STMNT, 0, S_PCMVOL, 0
            DEFTOK "PCMRATE", TOK_TY_STMNT, 0, S_PCMRATE, 0
            DEFTOK "PCMMODE", TOK_TY_STMNT, 0, S_PCMMODE, 0
            DEFTOK "PCMRESET", TOK_TY_STMNT, 0, S_PCMRESET, 0
            DEFTOK "PCMOUT", TOK_TY_STMNT, 0, S_PCMOUT, 0
            DEFTOK "YMPOKE", TOK_TY_STMNT, 0, S_YMPOKE, 0
            DEFTOK "FMINIT", TOK_TY_STMNT, 0, S_FMINIT, 0
            DEFTOK "FMNOTE", TOK_TY_STMNT, 0, S_FMNOTE, 0
            DEFTOK "FMOFF", TOK_TY_STMNT, 0, S_FMOFF, 0
            DEFTOK "FMVOL", TOK_TY_STMNT, 0, S_FMVOL, 0
            DEFTOK "FMPAN", TOK_TY_STMNT, 0, S_FMPAN, 0

; Input. MOUSE takes an index rather than being three no-argument
; functions, for the reason set out below.
            DEFTOK "JOY", TOK_TY_FUNC, 0, FN_JOY, 0
            DEFTOK "I2CPEEK", TOK_TY_FUNC, 0, FN_I2CPEEK, 0
            DEFTOK "MOUSE", TOK_TY_FUNC, 0, FN_MOUSE, 0
            DEFTOK "MOUSEAT", TOK_TY_STMNT, 0, S_MOUSEAT, 0
; Three functions that take no parentheses. They were blocked until the
; minus rule stopped comparing against a list of base ids and started
; asking the token's TYPE instead -- see TKPREVFN above. Without that,
; "LOCATE CURSORX-1,CURSORY" tokenized the minus as a NEGATION and the
; line came out as two operands with no operator between them.
            DEFTOK "CURSORX", TOK_TY_FUNC, 0, FN_CURSORX, 0
            DEFTOK "CURSORY", TOK_TY_FUNC, 0, FN_CURSORY, 0
            DEFTOK "PCMFREE", TOK_TY_FUNC, 0, FN_PCMFREE, 0

; The font. CHARSETAT takes no parentheses either, and is what makes
; CHARSET safe to use from a program: save it, point elsewhere, put it
; back.
            DEFTOK "CHARSET", TOK_TY_STMNT, 0, S_CHARSET, 0
            DEFTOK "CHARSETAT", TOK_TY_FUNC, 0, FN_CHARSETAT, 0
            DEFTOK "GLYPH", TOK_TY_STMNT, 0, S_GLYPH, 0
            DEFTOK "FONTCOPY", TOK_TY_STMNT, 0, S_FONTCOPY, 0
            DEFTOK "LAYERMODE", TOK_TY_STMNT, 0, S_LAYERMODE, 0

; Bitmap graphics on VERA2, whose framebuffer is ordinary memory. PLOT,
; LINE and CLRBITMAP are BASIC816 keywords that have thrown since phase
; 1 because they drove VICKY registers.
            DEFTOK "GRAPHICSAT", TOK_TY_FUNC, 0, FN_GRAPHICSAT, 0
            DEFTOK "POINT", TOK_TY_FUNC, 0, FN_POINT, 0
            DEFTOK "PAL2", TOK_TY_STMNT, 0, S_PAL2, 0
.endif

.if SYSTEM == SYSTEM_X816
; Interrupts. IRQ is the machine-code hook; the three ON* keywords run a
; BASIC line and are DEFERRED to the statement boundary -- see the header
; of X816/irq_x816.s for why that is the design and what it costs.
            DEFTOK "IRQ", TOK_TY_STMNT, 0, S_IRQ, 0
            DEFTOK "ONVSYNC", TOK_TY_STMNT, 0, S_ONVSYNC, 0
            DEFTOK "ONRASTER", TOK_TY_STMNT, 0, S_ONRASTER, 0
            DEFTOK "ONCOLLISION", TOK_TY_STMNT, 0, S_ONCOLLISION, 0
            DEFTOK "RETIRQ", TOK_TY_STMNT, 0, S_RETIRQ, 0

; Reading VRAM back, and moving it to and from the card. What the
; palette, sprite and tile pages were all missing, and all missing for
; the same two reasons -- see X816/vramio_x816.s.
;
; PALGET, SPRITEGET and TILEGET are FUNCTIONS and take parentheses, so
; none of them needs anything from the no-argument rule. SPRITEGET takes
; an index for which coordinate it means, exactly as MOUSE() does.
            DEFTOK "PALGET", TOK_TY_FUNC, 0, FN_PALGET, 0
            DEFTOK "PALLOAD", TOK_TY_STMNT, 0, S_PALLOAD, 0
            DEFTOK "PALSAVE", TOK_TY_STMNT, 0, S_PALSAVE, 0
            DEFTOK "SPRITEGET", TOK_TY_FUNC, 0, FN_SPRITEGET, 0
            DEFTOK "SPRITELOAD", TOK_TY_STMNT, 0, S_SPRITELOAD, 0
            DEFTOK "SPRITESAVE", TOK_TY_STMNT, 0, S_SPRITESAVE, 0
            DEFTOK "TILEGET", TOK_TY_FUNC, 0, FN_TILEGET, 0
            DEFTOK "TILEATTR", TOK_TY_STMNT, 0, S_TILEATTR, 0
            DEFTOK "TMAPLOAD", TOK_TY_STMNT, 0, S_TMAPLOAD, 0
            DEFTOK "TMAPSAVE", TOK_TY_STMNT, 0, S_TMAPSAVE, 0
            DEFTOK "TILELOAD", TOK_TY_STMNT, 0, S_TILELOAD, 0
            DEFTOK "TILESAVE", TOK_TY_STMNT, 0, S_TILESAVE, 0

; Controllers and the mouse. MX, MY, MB and MWHEEL take NO PARENTHESES,
; which is what help/MOUSE.TXT always wanted and could not have until
; TKPREVFN started asking a token's TYPE instead of comparing ids -- see
; the note beside CURSORX. MOUSE(n) stays: programs use it.
;
; MOUSEON, not "MOUSE on" as the page asks: a keyword is one token with
; one type, and MOUSE is already a function.
            DEFTOK "JOYSCAN", TOK_TY_STMNT, 0, S_JOYSCAN, 0
            DEFTOK "JOYHIT", TOK_TY_FUNC, 0, FN_JOYHIT, 0
            DEFTOK "JOYX", TOK_TY_FUNC, 0, FN_JOYX, 0
            DEFTOK "JOYY", TOK_TY_FUNC, 0, FN_JOYY, 0
            DEFTOK "JOYFIRE", TOK_TY_FUNC, 0, FN_JOYFIRE, 0
            DEFTOK "I2CPOKE", TOK_TY_STMNT, 0, S_I2CPOKE, 0
            DEFTOK "MOUSEON", TOK_TY_STMNT, 0, S_MOUSEON, 0
            DEFTOK "MWHEEL", TOK_TY_FUNC, 0, FN_MWHEEL, 0
            DEFTOK "MX", TOK_TY_FUNC, 0, FN_MX, 0
            DEFTOK "MY", TOK_TY_FUNC, 0, FN_MY, 0
            DEFTOK "MB", TOK_TY_FUNC, 0, FN_MB, 0

; Audio. PCMFULL and PCMEMPTY take no parentheses, like PCMFREE beside
; them. YMPEEK is a SHADOW of what YMPOKE wrote -- the chip answers no
; reads at all -- so it needs one, and takes it.
            DEFTOK "YMPEEK", TOK_TY_FUNC, 0, FN_YMPEEK, 0
            DEFTOK "PCMCTRL", TOK_TY_STMNT, 0, S_PCMCTRL, 0
            DEFTOK "PCMFULL", TOK_TY_FUNC, 0, FN_PCMFULL, 0
            DEFTOK "PCMEMPTY", TOK_TY_FUNC, 0, FN_PCMEMPTY, 0
            DEFTOK "PCMPLAY", TOK_TY_STMNT, 0, S_PCMPLAY, 0
            DEFTOK "FMINST", TOK_TY_STMNT, 0, S_FMINST, 0
            DEFTOK "FMLOAD", TOK_TY_STMNT, 0, S_FMLOAD, 0
            DEFTOK "PLAY", TOK_TY_STMNT, 0, S_PLAY, 0

; Volume envelopes over the PSG. ENV arms a voice and ENVOFF lets a note
; go; SOUND's volume becomes the peak. Two keywords and not three: ENV
; with all four arguments zero disarms, which is spelled out in
; X816/psgenv_x816.s and costs no sub-id.
            DEFTOK "ENV", TOK_TY_STMNT, 0, S_ENV, 0
            DEFTOK "ENVOFF", TOK_TY_STMNT, 0, S_ENVOFF, 0

; IMA ADPCM: a quarter the file for the same sound. One keyword, because
; the decoded audio goes to a fixed buffer and is handed straight to the
; feeder -- a decode-to-an-address form would need a second keyword just
; to report how long the answer was.
            DEFTOK "ADPCMPLAY", TOK_TY_STMNT, 0, S_ADPCMPLAY, 0

; The machine itself. FRE takes no parentheses, like TIMER and FRAMES.
; QUIT has no second spelling: help/SYSTEM.TXT lists "QUIT / SYSTEM" and
; a second name costs a sub-id, which PORT.md 29 established is the
; ceiling on finishing these pages.
            DEFTOK "QUIT", TOK_TY_STMNT, 0, S_QUIT, 0
            DEFTOK "TURBO", TOK_TY_STMNT, 0, S_TURBO, 0
            DEFTOK "FRE", TOK_TY_FUNC, 0, FN_FRE, 0

; Fast game maths (help/ADVANCED.TXT). Integer, table-driven, and the
; angle is a BYTE that wraps -- 0 east, 64 south, 128 west, 192 north,
; which is the convention that makes a step of (COS8(a), SIN8(a)) move
; in direction a on a screen whose y grows downwards.
            DEFTOK "SIN8", TOK_TY_FUNC, 0, FN_SIN8, 0
            DEFTOK "COS8", TOK_TY_FUNC, 0, FN_COS8, 0
            DEFTOK "ATAN2", TOK_TY_FUNC, 0, FN_ATAN2, 0
            DEFTOK "LERP", TOK_TY_FUNC, 0, FN_LERP, 0
            DEFTOK "CLAMP", TOK_TY_FUNC, 0, FN_CLAMP, 0
            DEFTOK "RNDSEED", TOK_TY_STMNT, 0, S_RNDSEED, 0
; MIN and MAX are three letters, the shortest a keyword can be and
; still be written into a line as a two-byte extended token.
            DEFTOK "MIN", TOK_TY_FUNC, 0, FN_MIN, 0
            DEFTOK "MAX", TOK_TY_FUNC, 0, FN_MAX, 0

; Shapes on the bitmap. The colour is OPTIONAL on every one of them --
; GCOLOR sets the pen they fall back on -- and outline and filled are
; separate keywords rather than a mode argument, which is the answer
; help/GRAPHIC.TXT had already chosen for itself by listing CIRCLE and
; FCIRCLE beside each other.
            DEFTOK "FRECT", TOK_TY_STMNT, 0, S_FRECT, 0
            DEFTOK "CIRCLE", TOK_TY_STMNT, 0, S_CIRCLE, 0
            DEFTOK "FCIRCLE", TOK_TY_STMNT, 0, S_FCIRCLE, 0
            DEFTOK "GCOLOR", TOK_TY_STMNT, 0, S_GCOLOR, 0
.endif

; ENDIF closes the block form of IF. Portable -- it is language, not
; platform -- and in the extended table because the base one is full.
; Its id is computed rather than written down, so it stays right whatever
; is added above it, and the two-byte form costs nothing here: the block
; scanner reads it through TOKAT, which handles the escape.
TOK_ENDIF = $FF00 | ($80 + (* - TOKENS2) / SIZE(TOKEN))
            DEFTOK "ENDIF", TOK_TY_STMNT, 0, S_ENDIF, 0

; Named procedures. DEFPROC defines, PROC calls: a tokenizer that matches
; keywords anywhere in a line cannot glue a keyword to a name, so BBC
; BASIC's PROCname is not available and two keywords are.
TOK_DEFPROC = $FF00 | ($80 + (* - TOKENS2) / SIZE(TOKEN))
            DEFTOK "DEFPROC", TOK_TY_STMNT, 0, S_DEFPROC, 0
TOK_ENDPROC = $FF00 | ($80 + (* - TOKENS2) / SIZE(TOKEN))
            DEFTOK "ENDPROC", TOK_TY_STMNT, 0, S_ENDPROC, 0
            DEFTOK "PROC", TOK_TY_STMNT, 0, S_PROC, 0
            DEFTOK "LOCAL", TOK_TY_STMNT, 0, S_LOCAL, 0

; A place to jump to that is not a number. GOTO, GOSUB and THEN all take
; one, through the same search PROC uses for its DEFPROC.
TOK_LABEL = $FF00 | ($80 + (* - TOKENS2) / SIZE(TOKEN))
            DEFTOK "LABEL", TOK_TY_STMNT, 0, S_LABEL, 0

; A COMMAND, not a statement: numbering lines as they are typed is only
; meaningful at the prompt.
            DEFTOK "AUTO", TOK_TY_CMD, 0, CMD_AUTO, 0

.if SYSTEM == SYSTEM_X816
; Record I/O: where a channel is, and moving it. Guarded, because the
; channel layer is -- OPEN, CLOSE and EOF are X816-only for the same
; reason, and an unguarded token here pointed the C256 build at handlers
; that do not exist in it.
            DEFTOK "SEEK", TOK_TY_STMNT, 0, S_SEEKCH, 0
            DEFTOK "LOC", TOK_TY_FUNC, 0, FN_LOC, 0
            DEFTOK "LINPUT", TOK_TY_STMNT, 0, S_LINPUTCH, 0
.endif

; The three string functions that would not fit before. Portable, like
; the rest of the SuperBasic string layer.
            DEFTOK "LCASE$", TOK_TY_FUNC, 0, FN_LCASE, 0
            DEFTOK "STRING$", TOK_TY_FUNC, 0, FN_STRINGS, 0
            DEFTOK "SPACE$", TOK_TY_FUNC, 0, FN_SPACES, 0
            DEFTOK "BIN$", TOK_TY_FUNC, 0, FN_BIN, 0

; 127, not 128. Sub-ids run $80 + index, so an index of 127 would be
; sub-id $FF -- and $FF is now the SECOND ESCAPE, the one that selects
; from TOKENS3. Allocating it to a keyword would make every three-byte
; token read as that keyword followed by rubbish.
.cerror (* - TOKENS2) / SIZE(TOKEN) > 127, "TOKENS2 full: sub-ids are $80-$FE, because $FF is the escape into TOKENS3"

            .word 0, 0, 0, 0

;
; The third table. Reached as $FF $FF <sub-id>, sub-ids running from $80
; exactly as the other two do -- see the note by TOK_EXTEND.
;
; EMPTY ON PURPOSE, for now. The mechanism is here because the counting
; said it had to be: 43 of the 48 items still on the help pages want a
; keyword that does not exist, and TOKENS2 had 37 sub-ids left. Building
; it before the next feature group means the group that needs it does not
; also have to carry it -- and it means the escape can be proved on its
; own, with one keyword moved into it and nothing else changing, rather
; than being debugged underneath a page of new statements.
;
; VER is that keyword. It is a real one-line function, it is the first
; item on help/SYSTEM.TXT, and putting it here rather than in the 37
; remaining slots of TOKENS2 is what makes the third table something the
; test suite can see. The same trick VSYNC did for TOKENS2 (PORT.md 12).
;
; ANYTHING PUT HERE NEEDS A KEYWORD OF AT LEAST THREE CHARACTERS, and
; DEFTOK3 is what refuses a shorter one -- see the note by TOK_EXTEND for
; what TKWRITE does with a two-letter keyword written as three bytes.
;
TOKENS3
.if SYSTEM == SYSTEM_X816
            DEFTOK3 "VER", TOK_TY_FUNC, 0, FN_VER, 0
.endif

.cerror (* - TOKENS3) / SIZE(TOKEN) > 128, "TOKENS3 full: sub-ids are $80-$FF"

            .word 0, 0, 0, 0

;;;
;;; The SuperBasic layer -- what this dialect adds to BASIC816.
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; PORTABLE ON PURPOSE. Nothing here touches hardware, so it lives in
;;; the shared core rather than in src/X816/ and any future target gets
;;; it for free (PORT.md section 8). The platform-specific additions --
;;; CD, TIMER and friends -- are in src/X816/ and their tokens are
;;; guarded; these are not.
;;;
;;; So far: three of the string functions BASIC816 lacks. Without INSTR,
;;; searching a string means a FOR loop over MID$, which is the sort of
;;; thing that stops a beginner writing an ordinary program.
;;;
;;; THREE, and not the six that were written, because THE TOKEN TABLE IS
;;; FULL. A token is a byte with bit 7 set, so there are exactly 128 and
;;; this build was already using 125. LCASE$, STRING$ and SPACE$ were
;;; written, did not fit, and were taken back out; they are in the
;;; history of this file. Most of what help/ still lists is in the same
;;; position, because sprites, sound and graphics all want keywords.
;;;
;;; A returned string is a TEMPSTRING, and TEMPSTRING hands out 256-byte
;;; pages, so every result here is capped at 255 characters. Going past
;;; it would walk into the next temporary or the heap.
;;;

SB_MAXSTR = 255

.section globals
SB_I        .word ?             ; a working index
SB_J        .word ?             ; a second one
SB_P        .dword ?            ; a pointer into the middle of a string
SB_K        .word ?             ; a third index, for the one function that
                        ;  walks three strings at once
SB_L        .word ?             ; a fourth, for SPLIT: the separator length
SB_SRC      .dword ?            ; SPLIT's source string
SB_SEP      .dword ?            ; the separator, for SPLIT and JOIN$
SB_ARR      .dword ?            ; the string array either of them is given
.send

;
; Evaluate an expression and insist it is a string.
;
; EVERY HELPER HERE BRACKETS ITSELF IN PHP/PLP, and that is not
; decoration. Without it this one returned with A eight bits wide, while
; the assembler -- which cannot see through a JSR -- went on emitting
; sixteen-bit code for the caller. In INSTR that made two PHAs push two
; bytes where the matching PLAs popped four, and the function returned
; into nothing. Restore the caller's width on the way out.
;
SB_ARGSTR   .proc
            PHP
            CALL EVALEXPR
            setas
            LDA ARGTYPE1
            CMP #TYPE_STRING
            BNE sb_notstr
            PLP
            RETURN
sb_notstr   THROW ERR_TYPE
            .pend

;
; Evaluate an expression and insist it is an integer.
;
SB_ARGINT   .proc
            PHP
            CALL EVALEXPR
            CALL ASS_ARG1_INT
            PLP
            RETURN
            .pend

;
; Step over the comma between two arguments.
;
SB_COMMA    .proc
            PHP
            CALL SKIPWS
            setas
            LDA [BIP]
            CMP #','
            BNE sb_nocomma
            CALL INCBIP
            PLP
            RETURN
sb_nocomma  THROW ERR_SYNTAX
            .pend

;
; Return the temporary string being built as this function's result.
; Y holds the length; the terminator is written here.
;
SB_RETSTR   .proc
            PHP
            setas
            LDA #0
            STA [STRPTR],Y
            setal
            LDA STRPTR
            STA ARGUMENT1
            LDA STRPTR+2
            STA ARGUMENT1+2
            setas
            LDA #TYPE_STRING
            STA ARGTYPE1
            PLP
            RETURN
            .pend

;
; UCASE$(s) -- upper case.
;
; Only a-z and A-Z move. CP437's accented letters are left alone: their
; upper and lower forms are not a fixed distance apart in the code page,
; so shifting by 32 would turn them into unrelated glyphs.
;
FN_UCASE    .proc
            FN_START "FN_UCASE"
            PHP
            setaxl

            CALL SB_ARGSTR
            CALL TEMPSTRING

            setxl
            setas
            LDY #0
uc_loop     CPY #SB_MAXSTR
            BEQ uc_done
            LDA [ARGUMENT1],Y
            BEQ uc_done
            CMP #'a'
            BLT uc_store
            CMP #'z'+1
            BGE uc_store
            SEC
            SBC #32
uc_store    STA [STRPTR],Y
            INY
            BRA uc_loop

uc_done     CALL SB_RETSTR
            FN_END
            PLP
            RETURN
            .pend

;
; TRIM$(s) -- drop leading and trailing spaces.
;
; INPUT hands back exactly what was typed, so comparing it against
; anything usually wants this first.
;
FN_TRIM     .proc
            FN_START "FN_TRIM"
            PHP
            setaxl

            CALL SB_ARGSTR

            setxl
            setas
            LDY #0                  ; first character that is not a space
tr_lead     LDA [ARGUMENT1],Y
            BEQ tr_empty
            CMP #' '
            BNE tr_first
            INY
            BRA tr_lead

tr_first    STY SB_I
tr_scan     LDA [ARGUMENT1],Y       ; walk to the terminator
            BEQ tr_trail
            INY
            BRA tr_scan

tr_trail    CPY SB_I                ; back over the trailing spaces
            BEQ tr_copy
            DEY
            LDA [ARGUMENT1],Y
            CMP #' '
            BEQ tr_trail
            INY                     ; one past the last kept character

            ; Point SB_P at the first kept character so source and
            ; destination share one index: [dp],Y is the only indirect
            ; long mode there is, so two independent indices would need
            ; two pointers anyway.
tr_copy     STY SB_J
            setal
            LDA SB_I
            CLC
            ADC ARGUMENT1
            STA SB_P
            LDA ARGUMENT1+2
            ADC #0
            STA SB_P+2

            LDA SB_J                ; SB_J becomes the length
            SEC
            SBC SB_I
            CMP #SB_MAXSTR+1
            BLT tr_fits
            LDA #SB_MAXSTR
tr_fits     STA SB_J

            CALL TEMPSTRING
            setxl
            setas
            LDY #0
tr_move     CPY SB_J
            BEQ tr_end
            LDA [SB_P],Y
            STA [STRPTR],Y
            INY
            BRA tr_move

tr_end      CALL SB_RETSTR
            FN_END
            PLP
            RETURN

tr_empty    CALL TEMPSTRING         ; all spaces, or empty: return ""
            setxl
            LDY #0
            CALL SB_RETSTR
            FN_END
            PLP
            RETURN
            .pend

;
; INSTR(haystack, needle) -- where one string appears inside another.
;
; ZERO-BASED, and -1 when it is not there. Most BASICs return a 1-based
; position with 0 for absent, but MID$ counts from zero on this one, so
; a 1-based INSTR could not be handed straight to it. The pairing is the
; point: MID$(s$, INSTR(s$, f$), n) has to mean what it looks like.
;
; An empty needle is found at 0, which is what a search for nothing
; should say.
;
FN_INSTR    .proc
            FN_START "FN_INSTR"
            PHP
            setaxl

            CALL SB_ARGSTR          ; the haystack
            LDA ARGUMENT1+2
            PHA
            LDA ARGUMENT1
            PHA

            CALL SB_COMMA
            CALL SB_ARGSTR          ; the needle
            setal
            LDA ARGUMENT1
            STA ARGUMENT2
            LDA ARGUMENT1+2
            STA ARGUMENT2+2
            PLA
            STA ARGUMENT1
            PLA
            STA ARGUMENT1+2

            setxl
            setas
            LDY #0                  ; Y = where the attempt starts

in_outer    setal                   ; SB_P = haystack + Y
            TYA
            CLC
            ADC ARGUMENT1
            STA SB_P
            LDA ARGUMENT1+2
            ADC #0
            STA SB_P+2
            setas

            PHY
            LDY #0
in_inner    LDA [ARGUMENT2],Y       ; needle exhausted: it matched
            BEQ in_found
            CMP [SB_P],Y
            BNE in_advance
            INY
            BRA in_inner

in_advance  PLY
            LDA [ARGUMENT1],Y       ; haystack exhausted: it is not there
            BEQ in_absent
            INY
            BRA in_outer

in_found    PLY
            setal
            TYA
            STA ARGUMENT1
            STZ ARGUMENT1+2
            BRA in_return

in_absent   setal
            LDA #$FFFF              ; -1
            STA ARGUMENT1
            STA ARGUMENT1+2

in_return   setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1
            setal

            FN_END
            PLP
            RETURN
            .pend

;
; LCASE$(s) -- lower case. The mirror of UCASE$, same caveat about the
; accented letters.
;
FN_LCASE    .proc
            FN_START "FN_LCASE"
            PHP
            setaxl

            CALL SB_ARGSTR
            CALL TEMPSTRING

            setxl
            setas
            LDY #0
lc_loop     CPY #SB_MAXSTR
            BEQ lc_done
            LDA [ARGUMENT1],Y
            BEQ lc_done
            CMP #'A'
            BLT lc_store
            CMP #'Z'+1
            BGE lc_store
            CLC
            ADC #32
lc_store    STA [STRPTR],Y
            INY
            BRA lc_loop

lc_done     CALL SB_RETSTR
            FN_END
            PLP
            RETURN
            .pend

;
; STRING$(n, c) -- n copies of the first character of c.
; SPACE$(n)     -- n spaces, the common case of it.
;
FN_STRINGS  .proc
            FN_START "FN_STRINGS"
            PHP
            setaxl

            CALL SB_ARGINT              ; how many
            setal
            LDA ARGUMENT1
            STA SB_I

            CALL SB_COMMA
            CALL SB_ARGSTR              ; of what
            setas
            LDA [ARGUMENT1]
            STA SB_J

            CALL SB_FILL

            FN_END
            PLP
            RETURN
            .pend

;
; Append the character in A (8-bit) to the answer being built.
;
RP_PUTC     .proc
            PHP
            setaxl
            PHY

            PHA                         ; A is holding the character and the
            LDA SB_I                    ;  index has to go through it, so the
            TAY                         ;  character goes on the stack for as
            PLA                         ;  long as that takes
            setas
            STA [STRPTR],Y

            setaxl
            LDA SB_I
            INC A
            STA SB_I

            PLY
            PLP
            RETURN
            .pend

;
; REPLACE$(s$, old$, new$) -- every occurrence of old$ in s$ replaced.
;
; THREE strings alive at once, which is one more than anything else on
; this page has needed, and [ptr] addressing lives in the direct page:
; ARGUMENT1 is the source, ARGUMENT2 the needle, MTEMP the replacement
; and SB_P walks the source. STRPTR is the answer. Nothing here streams
; a file through MTEMP, so borrowing it is safe -- and it is loaded
; after the last EVALEXPR, never before.
;
; AN EMPTY old$ MATCHES NOTHING and the source comes back unchanged. The
; alternative is a match at every position and a loop that never
; advances; "insert between every character" is not what anybody means
; by replacing nothing.
;
; The answer stops at 255 characters like every other string here, and
; this is the one function where that is easy to reach: the result can
; GROW, so REPLACE$("aaa","a","xxxx") is twelve characters out of three.
;
FN_REPLACE  .proc
            FN_START "FN_REPLACE"
            PHP
            setaxl

            CALL SB_ARGSTR              ; the source
            LDA ARGUMENT1+2
            PHA
            LDA ARGUMENT1
            PHA

            CALL SB_COMMA
            CALL SB_ARGSTR              ; what to look for
            setal
            LDA ARGUMENT1
            STA ARGUMENT2
            LDA ARGUMENT1+2
            STA ARGUMENT2+2

            CALL SB_COMMA
            CALL SB_ARGSTR              ; what to put there
            setal
            LDA ARGUMENT1
            STA MTEMP
            LDA ARGUMENT1+2
            STA MTEMP+2

            PLA                         ; and the source back
            STA ARGUMENT1
            PLA
            STA ARGUMENT1+2

            CALL TEMPSTRING

            setaxl
            LDA #0
            STA SB_I                    ; how much of the answer is built
            STA SB_J                    ; and how far into the source we are

rp_loop     setaxl                      ; SB_P = source + SB_J
            LDA SB_J
            CLC
            ADC ARGUMENT1
            STA SB_P
            LDA ARGUMENT1+2
            ADC #0
            STA SB_P+2

            setxl
            setas
            LDA [SB_P]                  ; end of the source?
            BEQ rp_done

            LDA [ARGUMENT2]             ; an empty needle matches nothing, or
            BEQ rp_copy1                ;  nothing would ever advance

            LDY #0                      ; does it match right here?
rp_match    LDA [ARGUMENT2],Y
            BEQ rp_hit                  ; needle exhausted: it does
            CMP [SB_P],Y
            BNE rp_copy1
            INY
            BRA rp_match

            ; ---- a hit: out goes the replacement ----
rp_hit      setaxl
            LDA #0
            STA SB_K
rp_put      setaxl
            LDA SB_I
            CMP #SB_MAXSTR
            BCS rp_skip                 ; no room left: stop copying, but
                                        ;  still step over the needle
            setxl
            LDY SB_K
            setas
            LDA [MTEMP],Y
            BEQ rp_skip
            CALL RP_PUTC
            setaxl
            LDA SB_K
            INC A
            STA SB_K
            BRA rp_put

rp_skip     setxl                       ; and step the source past the needle
            setas
            LDY #0
rp_skipl    LDA [ARGUMENT2],Y
            BEQ rp_skipped
            INY
            BRA rp_skipl
rp_skipped  setaxl
            TYA
            CLC
            ADC SB_J
            STA SB_J
            BRA rp_loop

            ; ---- no hit: one character of the source goes out ----
rp_copy1    setaxl
            LDA SB_I
            CMP #SB_MAXSTR
            BCS rp_done
            setxl
            setas
            LDA [SB_P]
            CALL RP_PUTC
            setaxl
            LDA SB_J
            INC A
            STA SB_J
            BRL rp_loop         ; the function is wider than a branch

rp_done     setaxl
            LDY SB_I
            CALL SB_RETSTR

            FN_END
            PLP
            RETURN
            .pend

;
; BIN$(n) -- the binary form of an integer, shortest that says it.
;
; Built BACKWARDS from the end of the temporary string and returned as
; a pointer into it, which is how HEX$ has always worked here: the
; number of digits is not known until the last one is written, and
; walking down from the end costs nothing that walking up and reversing
; would not cost twice.
;
; SHORTEST, not padded. HEX$ emits whole BYTES -- HEX$(5) is "05" --
; because a hex digit is half a byte and pairs of them are what a
; program pokes. A bit is not a byte, and BIN$(5) padded to eight would
; be "00000101" for a number whose whole interest is that it is 101.
; BIN$(0) is "0": the loop writes a digit before it tests, so zero is
; one digit rather than none.
;
; Negative numbers come out in two's complement, all 32 bits of them,
; which is what the machine holds and what somebody poking bits wants
; to see.
;
FN_BIN      .proc
            FN_START "FN_BIN"
            PHP

            CALL EVALEXPR
            CALL ASS_ARG1_INT
            CALL TEMPSTRING

            setaxs
            LDY #$FF                ; terminate it, then fill downwards
            LDA #0
            STA [STRPTR],Y
            DEY

bn_loop     setas
            LDA ARGUMENT1
            AND #1
            CLC
            ADC #'0'
            STA [STRPTR],Y
            DEY

            setal                   ; value >>= 1, all 32 bits of it
            LSR ARGUMENT1+2
            ROR ARGUMENT1

            LDA ARGUMENT1           ; anything left to say?
            ORA ARGUMENT1+2
            BNE bn_loop

            setaxs                  ; the first character written, which is
            TYA                     ;  where the answer starts. SEC before
            SEC                     ;  ADC is the +1 -- Y is one below it.
            ADC STRPTR
            STA ARGUMENT1
            LDA STRPTR+1
            STA ARGUMENT1+1
            LDA STRPTR+2
            STA ARGUMENT1+2
            LDA STRPTR+3
            STA ARGUMENT1+3

            LDA #TYPE_STRING
            STA ARGTYPE1

            PLP
            FN_END
            RETURN
            .pend

FN_SPACES   .proc
            FN_START "FN_SPACES"
            PHP
            setaxl

            CALL SB_ARGINT
            setal
            LDA ARGUMENT1
            STA SB_I
            setas
            LDA #' '
            STA SB_J

            CALL SB_FILL

            FN_END
            PLP
            RETURN
            .pend

;
; Build a string of SB_I copies of the character in SB_J.
; A negative count gives an empty string and an oversized one is
; clamped, rather than either being refused.
;
SB_FILL     .proc
            PHP
            setal
            LDA SB_I
            BPL sf_positive
            LDA #0
            STA SB_I
sf_positive LDA SB_I
            CMP #SB_MAXSTR+1
            BLT sf_room
            LDA #SB_MAXSTR
            STA SB_I

sf_room     CALL TEMPSTRING
            setxl
            setas
            LDY #0
sf_loop     CPY SB_I
            BEQ sf_done
            LDA SB_J
            STA [STRPTR],Y
            INY
            BRA sf_loop

sf_done     CALL SB_RETSTR
            PLP
            RETURN
            .pend

;;;
;;; SPLIT and JOIN$ -- a string and a string array, in both directions.
;;;
;;; BOTH ARE FUNCTIONS, and that is the decision worth writing down.
;;; The obvious shape is a statement -- SPLIT a$, ",", w$(), n -- but
;;; then the piece count has to come back through a variable named as a
;;; fourth argument, which means parsing a name, parking it across the
;;; whole split, and assigning to it at the end. As functions each one
;;; answers the thing the caller actually wanted:
;;;
;;;     N = SPLIT(A$, ",", W$())
;;;     PRINT JOIN$(W$(), ", ", N)
;;;
;;; A function parses its own arguments from BIP (that is what
;;; SB_ARGSTR and SB_COMMA are), so an array argument costs a function
;;; no more than it would cost a statement.
;;;
;;; THE ARRAY IS WRITTEN AS w$() WITH NOTHING BETWEEN THE BRACKETS. It
;;; is the whole array being passed, not a cell of it, and the brackets
;;; are what tell VAR_FINDNAME to look for an array rather than a
;;; scalar of the same name -- BASIC keeps A$ and A$() apart, so the
;;; brackets are not decoration.
;;;

;
; The array argument: a name, empty brackets, and a one-dimensional
; string array behind them.
;
; Outputs:
;   SB_ARR = the array's heap block
;   SB_J   = how many cells it has
;
SB_ARRARG   .proc
            PHP
            setaxl

            CALL VAR_FINDNAME           ; VAR_FINDNAME sets the "array of"
            BCC sa_syntax               ;  bit itself when a "(" follows

            setas
            LDA TOFINDTYPE
            CMP #(TYPE_STRING | $80)    ; A string ARRAY and nothing else
            BNE sa_type

            LDA #TOK_LPAREN
            CALL EXPECT_TOK
            LDA #TOK_RPAREN
            CALL EXPECT_TOK             ; Empty brackets: the whole array

            CALL VAR_FIND               ; INDEX = the binding
            BCC sa_notfound

            setal
            LDY #BINDING.VALUE
            LDA [INDEX],Y
            STA SB_ARR
            setas
            INY
            INY
            LDA [INDEX],Y
            STA SB_ARR+2

            setas                       ; One dimension, and how big it is.
            LDA [SB_ARR]                ; A two-dimensional array is refused
            CMP #1                      ;  rather than treated as flat: the
            BNE sa_dim                  ;  answer would be right by accident
            LDY #1
            LDA [SB_ARR],Y
            setal
            AND #$00FF
            STA SB_J

            PLP
            RETURN

sa_syntax   THROW ERR_SYNTAX
sa_type     THROW ERR_TYPE
sa_notfound THROW ERR_NOTFOUND
sa_dim      THROW ERR_ARGUMENT
            .pend

;
; Store the piece that starts at SB_I and runs for MCOUNT characters
; into cell SB_K, and count it.
;
; THE PIECE IS COPIED TO THE HEAP. STRSUBSTR answers a TEMPSTRING, and
; a temporary is exactly what an array cell must not hold: STRPTR is
; reset at the next statement boundary and the page is handed out
; again, so the array would be full of pointers to whatever the next
; PRINT built. STRCPY makes it a heap object and HEAP_ADDREF gives the
; array the reference it is now holding.
;
SB_PIECE    .proc
            PHP
            setaxl

            LDA SB_SRC                  ; The slice of the source
            STA ARGUMENT1
            LDA SB_SRC+2
            STA ARGUMENT1+2
            LDA SB_I
            STA ARGUMENT2
            STZ ARGUMENT2+2
            CALL STRSUBSTR

            CALL STRCPY                 ; ... on the heap, where it survives
            CALL HEAP_GETHED
            CALL HEAP_ADDREF

            setas
            LDA #TYPE_STRING
            STA ARGTYPE1

            setal                       ; The cell it goes in
            LDA SB_ARR
            STA CURRBLOCK
            LDA SB_ARR+2
            STA CURRBLOCK+2
            setas
            LDA #1                      ; One index, and it is SB_K
            STA @l ARRIDXBUF
            setal
            LDA SB_K
            STA @l ARRIDXBUF+1
            CALL ARR_SET

            setal
            LDA SB_K
            INC A
            STA SB_K

            PLP
            RETURN
            .pend

;
; SPLIT(s$, sep$, arr$()) -- cut a string on a separator, into a string
; array, and answer how many pieces there were.
;
;     N = SPLIT("10,20,30", ",", W$())
;
; THE SEPARATOR IS A WHOLE STRING, not a set of characters: SPLIT(s$,
; ", ", w$()) cuts on comma-space and leaves a bare comma alone. A set
; would be the other reasonable choice and is not this one, because
; "cut this line where this text appears" is the thing a beginner's
; program is doing when it parses input.
;
; EMPTY PIECES ARE PIECES. "a,,b" is three, the middle one empty, and
; "," is two empty ones. Dropping them would make the count depend on
; the data in a way no caller can predict, and a program reading a CSV
; line needs the blank field to stay in its column.
;
; AN EMPTY SEPARATOR CUTS NOTHING and the whole string comes back as
; one piece, which is the same rule REPLACE$ follows for an empty
; needle and for the same reason: a match at every position is a loop
; that never advances.
;
; IT STOPS WHEN THE ARRAY IS FULL rather than throwing. The count comes
; back so the caller can see it filled -- N = the array size means
; there was probably more -- and a program that guessed its DIM too
; small gets a short answer instead of a stopped program. The pieces it
; did store are the first ones, in order.
;
FN_SPLIT    .proc
            FN_START "FN_SPLIT"
            PHP
            setaxl

            CALL SB_ARGSTR              ; The string to cut
            LDA ARGUMENT1
            STA SB_SRC
            LDA ARGUMENT1+2
            STA SB_SRC+2

            CALL SB_COMMA
            CALL SB_ARGSTR              ; The separator
            LDA ARGUMENT1
            STA SB_SEP
            LDA ARGUMENT1+2
            STA SB_SEP+2

            CALL SB_COMMA
            CALL SB_ARRARG              ; SB_ARR, SB_J = its size

            setxl                       ; How long the separator is
            setas
            LDY #0
sp_slen     LDA [SB_SEP],Y
            BEQ sp_slend
            INY
            BRA sp_slen
sp_slend    setal
            TYA
            STA SB_L

            STZ SB_I                    ; The first piece starts at 0
            STZ SB_K                    ;  and none are stored yet

sp_loop     setal
            LDA SB_K
            CMP SB_J
            BGE sp_done                 ; The array is full

            LDA SB_L
            BEQ sp_tail                 ; Nothing to cut on: one piece

            setxl                       ; Look for the separator from SB_I
            LDA SB_I
            TAY

sp_try      setal                       ; SB_P = the source at Y
            TYA
            CLC
            ADC SB_SRC
            STA SB_P
            LDA SB_SRC+2
            ADC #0
            STA SB_P+2

            setas
            PHY
            LDY #0
sp_match    LDA [SB_SEP],Y              ; Separator exhausted: it matched
            BEQ sp_hit
            CMP [SB_P],Y
            BNE sp_next
            INY
            BRA sp_match

sp_next     PLY
            LDA [SB_P]                  ; Source exhausted: no more of them
            BEQ sp_tail
            INY
            BRA sp_try

sp_hit      PLY                         ; Y = where the separator starts
            setal
            TYA
            SEC
            SBC SB_I
            STA MCOUNT                  ; The piece is what lies before it
            TYA
            CLC
            ADC SB_L                    ; The next one starts after it, and
            PHA                         ;  SB_PIECE is about to use Y
            CALL SB_PIECE
            setal
            PLA
            STA SB_I
            BRA sp_loop

            ; The last piece: everything left, however long that is.
sp_tail     setal
            LDA SB_I
            TAY
            setas
sp_tlen     LDA [SB_SRC],Y
            BEQ sp_tlend
            INY
            BRA sp_tlen
sp_tlend    setal
            TYA
            SEC
            SBC SB_I
            STA MCOUNT
            CALL SB_PIECE

sp_done     setal
            LDA SB_K                    ; The answer is how many there were
            STA ARGUMENT1
            STZ ARGUMENT1+2
            setas
            LDA #TYPE_INTEGER
            STA ARGTYPE1
            setal

            FN_END
            PLP
            RETURN
            .pend

;
; Append the NUL-terminated string at SB_P to the answer being built,
; stopping at SB_MAXSTR characters.
;
; Inputs:
;   Y = how much is already there
;
; Outputs:
;   Y = how much there is now
;
; SB_P IS CONSUMED: it walks rather than being indexed, because
; [dp],Y is the only long-indirect this processor has and Y is already
; the answer's length. A caller reloads it before the next call.
;
SB_APPEND   .proc
            PHP
ap_loop     setxl
            CPY #SB_MAXSTR
            BGE ap_done                 ; Full: what is left is dropped
            setas
            LDA [SB_P]
            BEQ ap_done                 ; The source ran out
            STA [STRPTR],Y
            setxl
            INY
            setal                       ; Step the source pointer, carrying
            INC SB_P                    ;  into its bank byte
            BNE ap_loop
            INC SB_P+2
            BRA ap_loop

ap_done     PLP
            RETURN
            .pend

;
; JOIN$(arr$(), sep$, n) -- the first n cells of a string array, glued
; back together with a separator between them.
;
;     PRINT JOIN$(W$(), ", ", N)
;
; THE COUNT IS AN ARGUMENT because an array does not know how much of
; itself is in use. DIM W$(20) and SPLIT filling three of them leaves
; seventeen empty cells, and joining all twenty would answer three
; words followed by seventeen separators. N is what SPLIT just handed
; back, which is what makes the pair read as a round trip.
;
; The answer is a temporary string and stops at 255 characters like
; every other string function here.
;
FN_JOIN     .proc
            FN_START "FN_JOIN"
            PHP
            setaxl

            CALL SB_ARRARG              ; SB_ARR, SB_J = its size
            CALL SB_COMMA
            CALL SB_ARGSTR              ; The separator
            LDA ARGUMENT1
            STA SB_SEP
            LDA ARGUMENT1+2
            STA SB_SEP+2

            CALL SB_COMMA
            CALL SB_ARGINT              ; How many cells to take
            setal
            LDA ARGUMENT1+2
            BEQ jn_small
            BMI jn_none                 ; NEGATIVE joins nothing, rather
            BRA jn_range                ;  than wrapping round to 65535

jn_small    LDA ARGUMENT1
            CMP SB_J
            BEQ jn_ok                   ; All of it is allowed
            BGE jn_range                ; More than there is, is not
jn_ok       STA SB_I
            BRA jn_build

jn_none     LDA #0
            STA SB_I

jn_build    CALL TEMPSTRING
            setxl
            LDY #0                      ; Y = the length so far
            setal
            STZ SB_K                    ; SB_K = the cell being read

jn_loop     setal
            LDA SB_K
            CMP SB_I
            BGE jn_done

            LDA SB_K                    ; Before every cell but the first,
            BEQ jn_cell                 ;  the separator goes in. Its own
            LDA SB_SEP                  ;  load, because the compare above
            STA SB_P                    ;  left the flags of a different
            LDA SB_SEP+2                ;  question
            STA SB_P+2
            CALL SB_APPEND

jn_cell     setal                       ; Read the cell
            LDA SB_ARR
            STA CURRBLOCK
            LDA SB_ARR+2
            STA CURRBLOCK+2
            setas
            LDA #1
            STA @l ARRIDXBUF
            setal
            LDA SB_K
            STA @l ARRIDXBUF+1
            PHY                         ; ARR_REF has its own use for Y
            CALL ARR_REF
            setaxl
            PLY

            LDA ARGUMENT1               ; ... and append it
            STA SB_P
            LDA ARGUMENT1+2
            STA SB_P+2
            CALL SB_APPEND

            setal
            LDA SB_K
            INC A
            STA SB_K
            BRA jn_loop

jn_done     CALL SB_RETSTR              ; Y is the length; it terminates it
            FN_END
            PLP
            RETURN

jn_range    THROW ERR_RANGE
            .pend

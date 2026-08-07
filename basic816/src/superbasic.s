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

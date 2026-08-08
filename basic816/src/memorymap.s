;;;
;;; Layout the memory map of the BASIC interpreter
;;;

;
; Define the memory blocks
;

.if SYSTEM == SYSTEM_C64
.include "CBM/mmap_cbm.s"
.elsif SYSTEM == SYSTEM_C256
.include "C256/mmap_c256.s"
.elsif SYSTEM == SYSTEM_X816
.include "X816/mmap_x816.s"
.endif

VBRK = $00FFE6          ; Vector for the native-mode BRK vector 

;
; Set up global memory labels and variables
;

.section data
DATA_BLOCK = *
.send

.section globals
GLOBAL_VARS = *
BIP         .dword ?    ; Pointer to the current byte in the current BASIC program
BIPPREV     .dword ?    ; Pointer to the previous bytein the current BASIC program
INDEX       .dword ?    ; A temporary pointer
SCRATCH     .dword ?    ; A temporary scratch variable
SCRATCH2    .dword ?    ; A temporary scratch variable
            .word  ?	; Need a few more bits for BCD conversion
STRPTR      .dword ?    ; A temporary pointer for strings
CURLINE     .dword ?    ; Pointer to the current input line needing tokenization
CURTOKLEN   .byte ?     ; Length of the text of the current token
ARGUMENTSP  .word ?     ; Pointer to the top of the argument stack
OPERATORSP  .word ?     ; Pointer to the top of the operator stack
ARGUMENT1   .dword ?    ; Argument 1 for expression calculations
ARGTYPE1    .byte ?     ; Type code for argument 1 (integer, float, string)
SIGN1       .byte ?     ; Temporary sign marker for argument 1
ARGUMENT2   .dword ?    ; Argument 2 for expression calculations
ARGTYPE2    .byte ?     ; Type code for argument 2 (integer, float, string)
SIGN2       .byte ?     ; Temporary sign marker for argument 1
JMP16PTR    .word ?     ; Pointer for 16-bit indirect jumps (within BASIC816's code base)
GOSUBDEPTH  .word ?     ; Number of GOSUBs on the stack
RETURNSP    .word ?     ; Pointer to the top of the return stack
SKIPNEST    .byte ?     ; Flag to indicate if token seeking should respect nesting (MSB set if so)
NESTING     .byte ?     ; Counter of the depth of lexical nesting for FOR/NEXT, DO/LOOP
TARGETTOK   .byte ?     ; When searching for a token, TARGETTOK is the token to find
DATABIP     .dword ?    ; Pointer to the next data element for READ statements
DATALINE    .dword ?    ; Pointer to the current line for a DATA statement
SAVEBIP     .dword ?    ; Spot to save BIP temporarily
SAVELINE    .dword ?    ; Spot to save CURLINE temporarily

; What is left of this block on the X816 is NOT the monitor's -- the
; monitor is not built there (basic816.s). These are the general scratch
; that commands.s, dos.s, floats.s, listing.s, repl.s and statements.s
; borrowed from it over the years, and they keep their names because
; renaming 700 access sites would be a much larger change than the one
; that removed the monitor.
MONITOR_VARS = *
.if SYSTEM != SYSTEM_X816
MCMDADDR    .long ?     ;3 Bytes Address of the current line of text being processed by the command parser. Can be in display memory or a variable in memory. MONITOR will parse up to MTEXTLEN characters or to a null character.
MCMP_TEXT   .long ?     ;3 Bytes Address of symbol being evaluated for COMPARE routine
MCMP_LEN    .word ?     ;2 Bytes Length of symbol being evaluated for COMPARE routine
MCMD        .long ?     ;3 Bytes Address of the current command/function string
MCMD_LEN    .word ?     ;2 Bytes Length of the current command/function string
.endif
MARG1       .dword ?    ;4 Bytes First command argument. May be data or address, depending on command
MARG2       .dword ?    ;4 Bytes First command argument. May be data or address, depending on command. Data is 32-bit number. Address is 24-bit address and 8-bit length.
MARG3       .dword ?    ;4 Bytes First command argument. May be data or address, depending on command. Data is 32-bit number. Address is 24-bit address and 8-bit length.
MARG4       .dword ?    ;4 Bytes First command argument. May be data or address, depending on command. Data is 32-bit number. Address is 24-bit address and 8-bit length.
MARG5       .dword ?    ;4 Bytes First command argument. May be data or address, depending on command. Data is 32-bit number. Address is 24-bit address and 8-bit length.
MARG6       .dword ?    ;4 Bytes First command argument. May be data or address, depending on command. Data is 32-bit number. Address is 24-bit address and 8-bit length.
.if SYSTEM != SYSTEM_X816
MARG7       .dword ?    ;4 Bytes First command argument. May be data or address, depending on command. Data is 32-bit number. Address is 24-bit address and 8-bit length.
MARG8       .dword ?    ;4 Bytes First command argument. May be data or address, depending on command. Data is 32-bit number. Address is 24-bit address and 8-bit length.
MARG9       .dword ?    ;4 Bytes First command argument.
MARG_LEN    .byte ?     ;1 Byte count of the number of arguments passed
.endif
MCURSOR     .dword ?    ;4 Bytes Pointer to the current memory location for disassembly, memory dump, etc.
.if SYSTEM != SYSTEM_X816
MLINEBUF    .fill 17    ;17 Byte buffer for dumping memory
.endif                  ; on the X816 it is out of the direct page entirely
                        ;  (X816/mmap_x816.s): 17 bytes is a BUFFER, and a
                        ;  buffer has no business in a 256-byte page. Only
                        ;  the assembler ever dereferenced it, and that is
                        ;  gone.
MCOUNT      .long ?     ;2 Byte counter
MTEMP       .dword ?    ;4 Bytes of temporary space
.if SYSTEM != SYSTEM_X816
MCPUSTAT    .byte ?     ;1 Byte to represent what the disassembler thinks the processor MX bits are
MADDR_MODE  .byte ?     ;1 Byte address mode found by the assembler
MPARSEDNUM  .dword ?    ;4 Bytes to store a parsed number
MMNEMONIC   .word ?     ;2 Byte address of mnemonic found by the assembler
.endif
PROCNAME    .dword ?    ;4 Bytes - the name at a call site, kept while the
                        ; arguments are evaluated and the header is found.
                        ; THE ONLY one of the new SuperBasic variables in
                        ; the direct page, because it is the only one
                        ; DEREFERENCED -- [PROCNAME],Y compares it against
                        ; a header. The rest are in `variables` below: the
                        ; C256 still builds the monitor and its direct page
                        ; has no 25 bytes to spare, and this layer is
                        ; portable, so it cannot want them.
MTEMPPTR    .dword ?    ;4 Byte temporary pointer
MJUMPINST   .byte ?     ;1 Byte JSL opcode
MJUMPADDR   .long ?     ;3 Byte address for JSL
.if SYSTEM == SYSTEM_X816
PCM_PTR     .dword ?    ;4 Bytes - the PCM feeder's next sample byte.
                        ; Here and not in bank 0 with the rest of the audio
                        ; state because an INTERRUPT HANDLER dereferences
                        ; it, and [ptr] addressing exists only in the
                        ; direct page. It cannot be MTEMP: that is shared
                        ; scratch, and a TILELOAD streaming through it
                        ; while a sample plays would send the feeder into
                        ; the tilemap. Costs 4 of the 54 bytes freed in
                        ; PORT.md section 19.
.endif
.send

;
; The SuperBasic layer's state (statements.s).
;
; NOT the direct page. None of it is dereferenced -- these are counters,
; token ids and one parked value -- and the direct page is 256 bytes that
; both targets are short of; the C256 still builds the monitor and had
; nothing like 25 bytes free. Every access below is written @l, because
; this section lands in bank $01 on the X816 and the data bank is $00.
;
.section variables
IFTRUE      .byte ?     ;1 Byte - an IF condition, kept across the THEN check
; What SKIPBLOCK is looking for. BLKALT is a SECOND token that also ends
; the scan (ELSE, for an IF); with no second one it is set equal to
; BLKCLOSE, which makes the test harmless rather than needing a "none"
; value that a real token id might one day collide with.
BLKOPEN     .word ?     ;2 Bytes - the token that goes one level deeper
BLKCLOSE    .word ?     ;2 Bytes - the token that ends the block
BLKALT      .word ?     ;2 Bytes - and the other one that ends it
PROCLOCALS  .word ?     ;2 Bytes - locals saved by the frame now running
PROCDEPTH   .word ?     ;2 Bytes - open PROC frames, so a stray ENDPROC shows
PROCVAL     .dword ?    ;4 Bytes - one argument, held while the parameter it
PROCVALT    .byte ?     ;1 Byte  - belongs to has its old value saved
PROCHDR     .dword ?    ;4 Bytes - the header's parameter list, returned to
                        ; once per parameter: they bind LAST FIRST, because
                        ; that is the order the argument stack gives them up
PROCARGN    .word ?     ;2 Bytes - how many arguments the call passed
PROCIDX     .word ?     ;2 Bytes - which parameter is being bound, 1-based
PROCCH      .byte ?     ;1 Byte  - one character, while two names compare
NAMETOK     .word ?     ;2 Bytes - which header NAME_FIND is looking for:
                        ; DEFPROC for a call, LABEL for a GOTO
AUTO_ON     .byte ?     ;1 Byte  - AUTO is numbering the lines
AUTO_NEXT   .word ?     ;2 Bytes - the number it will offer next
AUTO_STEP   .word ?     ;2 Bytes - and by how much it goes up
.send

MANTISSA1 = ARGUMENT1
EXPONENT1 = ARGUMENT1+3

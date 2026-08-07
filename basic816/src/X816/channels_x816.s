;;;
;;; Record I/O: OPEN, CLOSE, PRINT#, INPUT#, EOF
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The kernel filesystem is block oriented -- K_FS_READ and K_FS_WRITE
;;; move N bytes between a handle and an address. BASIC wants a stream:
;;; one character at a time, a line at a time. This file is the buffer
;;; layer between the two, and it is the whole of the work. Four
;;; channels, a 256-byte buffer each, filled and flushed a block at a
;;; time so that PRINT #1,X in a loop is not one SD transaction per
;;; character.
;;;
;;; Almost nothing here formats or parses anything, because it does not
;;; have to. BASIC816 already routes every character PRINT emits through
;;; IPRINTC, which consults a device bitmask (bios.s, BCONSOLE) -- so
;;; PRINT #1 sets a new bit in that mask, calls the ordinary S_PRINT,
;;; and every bit of existing formatting for strings, integers, floats,
;;; commas, semicolons and TAB comes along untouched. INPUT #1 is the
;;; mirror image: it fills IOBUF from the channel instead of from the
;;; keyboard and then lets the ordinary S_INPUT parse it.
;;;
;;; Getting that for nothing is the reason the two statements are about
;;; thirty lines each rather than three hundred.
;;;

.section globals
CHN_P       .dword ?            ; the selected channel record
CHN_B       .dword ?            ; the selected channel buffer
.send

CHN_COUNT   = 4                 ; channels 1-4
CHN_BUFSZ   = 256

;
; Fields of a channel record. CHN_TAB is in mmap_x816.s.
;
CHN_HANDLE  = 0                 ; word - kernel file handle, 0 = closed
CHN_MODE    = 2                 ; word - KFS_READ or KFS_WRITE
CHN_CNT     = 4                 ; word - bytes live in the buffer
CHN_POS     = 6                 ; word - read cursor into the buffer
CHN_EOF     = 8                 ; word - nonzero once the file has run out

;
; CHN_P := the record for channel ARGUMENT1, CHN_B := its buffer.
;
; Throws if the number is not 1 to CHN_COUNT. Channel 0 is deliberately
; not a channel: on the C64 it is the screen, and a beginner who types
; PRINT #0 should be told it is wrong rather than have it silently work.
;
CHN_REC         .proc
                PHP
                setal
                LDA ARGUMENT1
                BEQ chr_bad
                CMP #CHN_COUNT+1
                BCS chr_bad

                DEC A                   ; records are 16 bytes
                PHA
                .rept 4
                ASL A
                .next
                CLC
                ADC #<>CHN_TAB
                STA @l CHN_P
                LDA #`CHN_TAB
                STA @l CHN_P+2

                PLA                     ; buffers are 256 bytes
                XBA
                CLC
                ADC #<>CHN_BUF
                STA @l CHN_B
                LDA #`CHN_BUF
                STA @l CHN_B+2

                PLP
                RETURN

chr_bad         PLP
                THROW ERR_ARGUMENT
                .pend

;
; Point FS_BLK at this channel's buffer with CHN_CNT bytes.
;
CHN_BLOCK       .proc
                PHP
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHY

                LDY #CHN_HANDLE
                LDA [CHN_P],Y
                STA @l FS_BLK_H

                LDA @l CHN_B
                STA @l FS_BLK_A
                LDA @l CHN_B+2
                AND #$00FF
                STA @l FS_BLK_A+2

                LDY #CHN_CNT
                LDA [CHN_P],Y
                STA @l FS_BLK_N
                LDA #0
                STA @l FS_BLK_N+2

                PLY
                PLP
                RETURN
                .pend

;
; Refill a read channel. Sets CHN_EOF when the kernel returns nothing.
;
; K_FS_READ gives back the count actually read, so a short block at the
; end of a file is ordinary rather than an error -- which is why nothing
; here has to ask K_FS_SIZE how long the file was.
;
CHN_FILL        .proc
                PHP
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHX
                PHY

                LDY #CHN_CNT            ; ask for a whole buffer
                LDA #CHN_BUFSZ
                STA [CHN_P],Y
                CALL CHN_BLOCK

                LDA #<>FS_BLK
                LDX #`FS_BLK
                JSL KERN_FS_READ
                BCS cfl_end             ; a failed read is an ended file

                CMP #0
                BEQ cfl_end

                LDY #CHN_CNT            ; C = bytes actually read
                STA [CHN_P],Y
                LDA #0
                LDY #CHN_POS
                STA [CHN_P],Y

                PLY
                PLX
                PLP
                RETURN

cfl_end         LDA #0
                LDY #CHN_CNT
                STA [CHN_P],Y
                LDY #CHN_POS
                STA [CHN_P],Y
                LDA #1
                LDY #CHN_EOF
                STA [CHN_P],Y

                PLY
                PLX
                PLP
                RETURN
                .pend

;
; Write out whatever a write channel has accumulated, and empty it.
;
CHN_FLUSH       .proc
                PHP
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHX
                PHY

                LDY #CHN_CNT
                LDA [CHN_P],Y
                BEQ cfs_done            ; nothing waiting

                CALL CHN_BLOCK
                LDA #<>FS_BLK
                LDX #`FS_BLK
                JSL KERN_FS_WRITE

                setal
                LDA #0
                LDY #CHN_CNT
                STA [CHN_P],Y

cfs_done        PLY
                PLX
                PLP
                RETURN
                .pend

;
; Next byte of a read channel in A (8 bits). Carry set at end of file.
;
CHN_GETB        .proc
                PHP
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHY

                LDY #CHN_POS
                LDA [CHN_P],Y
                PHA
                LDY #CHN_CNT
                LDA [CHN_P],Y
                STA @l CHN_W
                PLA
                CMP @l CHN_W
                BCC cgb_have            ; still something in the buffer

                LDY #CHN_EOF            ; buffer dry: refill unless ended
                LDA [CHN_P],Y
                BNE cgb_eof
                CALL CHN_FILL
                LDY #CHN_CNT
                LDA [CHN_P],Y
                BEQ cgb_eof

cgb_have        setal
                LDY #CHN_POS
                LDA [CHN_P],Y
                TAY
                setas
                LDA [CHN_B],Y           ; the byte itself
                STA @l CHN_W

                setal
                TYA
                INC A
                LDY #CHN_POS
                STA [CHN_P],Y

                setas
                LDA @l CHN_W
                PLY
                PLP
                CLC
                RETURN

cgb_eof         PLY
                PLP
                SEC
                RETURN
                .pend

;
; Append the byte in A (8 bits) to a write channel, flushing when full.
;
CHN_PUTB        .proc
                PHP
                PHY
                setas
                STA @l CHN_W
                setaxl

                LDY #CHN_CNT
                LDA [CHN_P],Y
                TAY
                setas
                LDA @l CHN_W
                STA [CHN_B],Y

                setal
                TYA
                INC A
                LDY #CHN_CNT
                STA [CHN_P],Y

                CMP #CHN_BUFSZ
                BCC cpb_done
                CALL CHN_FLUSH

cpb_done        PLY
                PLP
                RETURN
                .pend

;
; The sink IPRINTC calls when DEV_CHANNEL is set in BCONSOLE.
;
; Byte in A, 8-bit. CHN_P and CHN_B already point at the channel PRINT #
; selected, so this does not re-derive them -- it is called once per
; character and the arithmetic in CHN_REC would dominate.
;
CHN_PUTC        .proc
                PHP
                PHY
                setas
                STA @l CHN_W
                setxl

                setal                   ; a read channel swallows output
                LDY #CHN_MODE
                LDA [CHN_P],Y
                CMP #KFS_WRITE
                BNE cpc_done

                setas
                LDA @l CHN_W
                CALL CHN_PUTB

cpc_done        PLY
                PLP
                RETURN
                .pend

;
; Close one channel: flush anything pending, then hand the handle back.
;
CHN_SHUT        .proc
                PHP
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHY

                LDY #CHN_HANDLE
                LDA [CHN_P],Y
                BEQ csh_done            ; already closed: not an error

                LDY #CHN_MODE
                LDA [CHN_P],Y
                CMP #KFS_WRITE
                BNE csh_close
                CALL CHN_FLUSH

csh_close       setal
                LDY #CHN_HANDLE
                LDA [CHN_P],Y
                JSL KERN_FS_CLOSE

                setal
                LDA #0
                LDY #CHN_HANDLE
                STA [CHN_P],Y
                LDY #CHN_CNT
                STA [CHN_P],Y
                LDY #CHN_POS
                STA [CHN_P],Y
                LDY #CHN_EOF
                STA [CHN_P],Y

csh_done        PLY
                PLP
                RETURN
                .pend

;
; Stop redirecting, whatever happened.
;
; A THROW inside a redirected PRINT # or INPUT # skips the restore at the
; end of the statement and leaves the console writing into a file, which
; looks exactly like a machine that has died. The REPL calls this every
; time it is ready for a line, so an error un-wedges the console by
; itself.
;
; It does NOT close anything: the channels have to survive between lines
; typed at the prompt, or OPEN #1 on one line and PRINT #1 on the next
; could never work.
;
CHN_UNHOOK      .proc
                PHP
                setas
                LDA @l BCONSOLE
                AND #$FF-DEV_CHANNEL
                ORA #DEV_SCREEN
                STA @l BCONSOLE
                PLP
                RETURN
                .pend

;
; Shut every channel. NEW, RUN and an error all go through here: a
; program that stops early must not leave a write channel holding the
; last few characters it printed, because they would never reach the
; card and the file would be silently short.
;
CHN_SHUTALL     .proc
                PHP
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHX

                LDX #1
csa_loop        setal
                TXA
                STA ARGUMENT1
                PHX
                CALL CHN_REC
                CALL CHN_SHUT
                PLX
                INX
                CPX #CHN_COUNT+1
                BCC csa_loop

                setas                   ; and stop redirecting
                LDA @l BCONSOLE
                AND #$FF-DEV_CHANNEL
                ORA #DEV_SCREEN
                STA @l BCONSOLE

                PLX
                PLP
                RETURN
                .pend

;
; Parse "#n" and leave the channel selected in CHN_P / CHN_B.
;
CHN_ARGNUM      .proc
                PHP
                setas
                LDA #'#'
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT
                CALL CHN_REC
                PLP
                RETURN
                .pend

;
; Throw unless the selected channel is open in mode A (8-bit).
;
CHN_NEED        .proc
                PHP
                PHY
                setas
                STA @l CHN_W        ; the compare below is 16-bit, so the
                LDA #0              ;  high byte has to be cleared: leaving
                STA @l CHN_W+1      ;  it stale made every mode look wrong
                setaxl

                LDY #CHN_HANDLE
                LDA [CHN_P],Y
                BEQ cnd_bad

                LDY #CHN_MODE
                LDA [CHN_P],Y
                CMP @l CHN_W
                BNE cnd_bad

                PLY
                PLP
                RETURN

cnd_bad         PLY
                PLP
                THROW ERR_ARGUMENT
                .pend

;
; OPEN #n, "path", "R" | "W"
;
; The mode is a string rather than a bare R or W because a bare R would
; tokenize as a variable. Only its first letter is read, so "READ" and
; "WRITE" work too.
;
; Opening a channel that is already open closes it first. That is not
; politeness: without it a program edited and re-run leaks a kernel
; handle every time round.
;
S_OPEN          .proc
                PHP
                TRACE "S_OPEN"
                setaxl

                CALL CHN_ARGNUM
                CALL CHN_SHUT           ; re-OPEN is a close and an open

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; the path
                CALL ASS_ARG1_STR
                CALL COPY2PATHBUF       ; NUL-terminated, where the kernel wants it

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; the mode
                CALL ASS_ARG1_STR

                setas                   ; first letter, upper-cased
                LDA [ARGUMENT1]
                AND #$DF
                CMP #'W'
                BEQ sop_write
                CMP #'R'
                BNE sop_bad
                setal
                LDY #KFS_READ
                BRA sop_do
sop_write       setal
                LDY #KFS_WRITE

sop_do          setal                   ; Record the mode BEFORE the call. The
                TYA                     ;  kernel is not obliged to preserve Y
                PHY                     ;  and does not, so reading it back
                LDY #CHN_MODE           ;  afterwards recorded whatever K_FS_OPEN
                STA [CHN_P],Y           ;  happened to leave -- every channel
                PLY                     ;  looked like a read channel.

                LDA #`DOS_PATH_BUFF     ; C:X = path; LDX has no long mode
                TAX
                LDA #<>DOS_PATH_BUFF
                JSL KERN_FS_OPEN
                BCS sop_fail

                setal                   ; C = handle
                LDY #CHN_HANDLE
                STA [CHN_P],Y
                LDA #0
                LDY #CHN_CNT
                STA [CHN_P],Y
                LDY #CHN_POS
                STA [CHN_P],Y
                LDY #CHN_EOF
                STA [CHN_P],Y

                PLP
                RETURN

sop_bad         PLP
                THROW ERR_ARGUMENT
sop_fail        PLP
                THROW ERR_NOFILE
                .pend

;
; CLOSE #n, or CLOSE on its own to shut every channel.
;
S_CLOSE         .proc
                PHP
                TRACE "S_CLOSE"
                setaxl

                setas
                CALL PEEK_TOK
                CMP #'#'
                BEQ scl_one

                CALL CHN_SHUTALL        ; bare CLOSE
                PLP
                RETURN

scl_one         setal
                CALL CHN_ARGNUM
                CALL CHN_SHUT

                PLP
                RETURN
                .pend

;
; PRINT #n, ... -- the ordinary PRINT with its output redirected.
;
; S_PRINT is not reimplemented here. The device bitmask is switched to
; the channel, S_PRINT runs, and the mask is put back; every format
; PRINT knows is therefore available on a file, including PRINT #1,A;B
; and the comma columns.
;
; The mask is restored through the error path as well, because a THROW
; inside S_PRINT would otherwise leave the console writing into a file
; and the machine apparently dead.
;
S_PRINTCH       .proc
                PHP
                TRACE "S_PRINTCH"
                setaxl

                CALL CHN_ARGNUM
                setas
                LDA #KFS_WRITE
                CALL CHN_NEED

                setas
                LDA #','
                CALL EXPECT_TOK

                setas                   ; redirect
                LDA @l BCONSOLE
                STA @l CHN_SAVE
                LDA #DEV_CHANNEL
                STA @l BCONSOLE

                setal
                CALL S_PRINT

                setas                   ; and back
                LDA @l CHN_SAVE
                STA @l BCONSOLE

                PLP
                RETURN
                .pend

;
; Read one line from the selected channel into IOBUF.
;
; Lines end with CR, LF or CRLF, so a file written on any of the three
; platforms a user might have prepared it on reads back the same. A last
; line with no terminator at all is still a line.
;
; Returns carry set if there was nothing left to read.
;
CHN_GETLINE     .proc
                PHP
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHX
                PHY

                LDX #0
cgl_loop        setas
                CALL CHN_GETB
                BCS cgl_eof

                CMP #CHAR_CR
                BEQ cgl_eol
                CMP #CHAR_LF
                BEQ cgl_eol

                STA @l IOBUF,X
                INX
                CPX #255
                BCC cgl_loop

cgl_eol         setas                   ; swallow the LF of a CRLF pair
                CMP #CHAR_CR
                BNE cgl_term
                PHX
                CALL CHN_GETB
                BCS cgl_unpush
                CMP #CHAR_LF
                BEQ cgl_drop
                CALL CHN_UNGET
cgl_drop        PLX
                BRA cgl_term
cgl_unpush      PLX

cgl_term        setas
                LDA #0
                STA @l IOBUF,X

                PLY
                PLX
                PLP
                CLC
                RETURN

cgl_eof         CPX #0                  ; a partial last line still counts
                BNE cgl_term

                setas
                LDA #0
                STA @l IOBUF
                PLY
                PLX
                PLP
                SEC
                RETURN
                .pend

;
; Put one byte back. Only ever used to unread the character after a CR.
;
CHN_UNGET       .proc
                PHP
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHY
                LDY #CHN_POS
                LDA [CHN_P],Y
                BEQ cug_done
                DEC A
                STA [CHN_P],Y
cug_done        PLY
                PLP
                RETURN
                .pend

;
; INPUT #n, var [, var...]
;
; Like PRINT #, this borrows the whole of the ordinary statement. The
; device mask is switched to the channel and S_INPUT runs: IINPUTLINE
; sees the mask and fills IOBUF from the file rather than the keyboard,
; and every per-type conversion S_INPUT already has -- PARSEINT for an
; integer, PARSENUM for a float, a copy for a string -- happens with no
; idea where the line came from.
;
; S_INPUT calls INPUTLINE once per variable, so INPUT #1,A,B reads TWO
; lines. That is a value to a line, which is also what PRINT # writes.
;
; The "? " prompt and the echoed CR are emitted as usual and land on
; CHN_PUTC, which discards them because the channel is open for reading.
; Suppressing the prompt costs nothing and needs no flag.
;
S_INPUTCH       .proc
                PHP
                TRACE "S_INPUTCH"
                setaxl

                CALL CHN_ARGNUM
                setas
                LDA #KFS_READ
                CALL CHN_NEED

                setas
                LDA #','
                CALL EXPECT_TOK

                setas                   ; redirect
                LDA @l BCONSOLE
                STA @l CHN_SAVE
                LDA #DEV_CHANNEL
                STA @l BCONSOLE

                setal
                CALL S_INPUT

                setas                   ; and back
                LDA @l CHN_SAVE
                STA @l BCONSOLE

                PLP
                RETURN
                .pend

;
; EOF(n) -- true once a read channel has run out.
;
; True BEFORE the failing read, not after: the test is "is the buffer dry
; and the file ended", and a dry buffer is refilled here to find out. So
; the classic WHILE NOT EOF(1) ... INPUT #1 loop reads every line and
; stops, rather than processing one phantom empty line at the end.
;
FN_EOF          .proc
                FN_START "FN_EOF"       ; a function parses its own parentheses
                PHP                     ;  and evaluates its own argument
                PHY
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                CALL CHN_REC

                LDY #CHN_HANDLE
                LDA [CHN_P],Y
                BEQ feo_true            ; a closed channel is at its end

                LDY #CHN_POS            ; anything still buffered?
                LDA [CHN_P],Y
                STA @l CHN_W
                LDY #CHN_CNT
                LDA [CHN_P],Y
                CMP @l CHN_W
                BNE feo_false

                LDY #CHN_EOF
                LDA [CHN_P],Y
                BNE feo_true

                CALL CHN_FILL           ; dry: try to refill and see
                LDY #CHN_CNT
                LDA [CHN_P],Y
                BEQ feo_true

feo_false       setal
                LDA #0
                STA ARGUMENT1
                STA ARGUMENT1+2
                BRA feo_type

feo_true        setal
                LDA #$FFFF
                STA ARGUMENT1
                STA ARGUMENT1+2

feo_type        setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                PLY
                FN_END
                PLP
                RETURN
                .pend

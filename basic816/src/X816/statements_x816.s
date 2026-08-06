;;;
;;; X816-specific statements
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The token table (tokens.s) is unconditional, so every statement the
;;; C256 layer provided must exist here. Console statements are real
;;; (bound to the kernel); C256 video-hardware statements (sprites,
;;; tiles, bitmap) throw ERR_ARGUMENT until a VERA feature pass gives
;;; them X816 semantics.
;;;

;
; TEXTCOLOR fg, bg -- set the console text colors (0-15 each)
;
S_TEXTCOLOR     .proc
                PHP
                TRACE "S_TEXTCOLOR"

                CALL EVALEXPR       ; Get the foreground index
                CALL ASS_ARG1_BYTE  ; Assert that the result is a byte value

                setas
                LDA ARGUMENT1
                AND #$0F
                PHA                 ; Save the foreground color

                LDA #','            ; Check for the comma separator
                CALL EXPECT_TOK

                CALL EVALEXPR       ; Get the background index
                CALL ASS_ARG1_BYTE

                setaxl
                LDA ARGUMENT1       ; X = background
                AND #$000F
                TAX
                PLA                 ; C = foreground (8-bit push above)
                AND #$00FF
                JSL KERN_CON_COLOR

                PLP
                RETURN
                .pend

;
; LOCATE col, row -- position the cursor on the 80x60 console
;
S_LOCATE        .proc
                PHP
                TRACE "S_LOCATE"

                setaxl

                CALL EVALEXPR               ; Get the column
                CALL ASS_ARG1_BYTE          ; Make sure the value is a byte
                LDA ARGUMENT1
                PHA                         ; Save it for later

                LDA #','                    ; Check for the comma separator
                CALL EXPECT_TOK

                CALL EVALEXPR               ; Get the row
                CALL ASS_ARG1_BYTE          ; Make sure the value is a byte

                LDY ARGUMENT1               ; Y = the row
                PLX                         ; X = the column
                CALL CURSORXY

                PLP
                RETURN
                .pend

;
; Statements with no X816 implementation yet: report a bad argument
; rather than doing nothing silently. THROW aborts the statement, so
; there is no need to consume the argument list.
;
S_SETTIME       .proc
                THROW ERR_ARGUMENT
                .pend

S_SETDATE       .proc
                THROW ERR_ARGUMENT
                .pend

S_SETBGCOLOR    .proc
                THROW ERR_ARGUMENT
                .pend

S_SETBORDER     .proc
                THROW ERR_ARGUMENT
                .pend

S_SETCOLOR      .proc
                THROW ERR_ARGUMENT
                .pend

S_GRAPHICS      .proc
                THROW ERR_ARGUMENT
                .pend

S_BITMAP        .proc
                THROW ERR_ARGUMENT
                .pend

S_CLRBITMAP     .proc
                THROW ERR_ARGUMENT
                .pend

S_PLOT          .proc
                THROW ERR_ARGUMENT
                .pend

S_LINE          .proc
                THROW ERR_ARGUMENT
                .pend

S_FILL          .proc
                THROW ERR_ARGUMENT
                .pend

S_SPRITE        .proc
                THROW ERR_ARGUMENT
                .pend

S_SPRITEAT      .proc
                THROW ERR_ARGUMENT
                .pend

S_SPRITESHOW    .proc
                THROW ERR_ARGUMENT
                .pend

S_TILESET       .proc
                THROW ERR_ARGUMENT
                .pend

S_TILEMAP       .proc
                THROW ERR_ARGUMENT
                .pend

S_TILESHOW      .proc
                THROW ERR_ARGUMENT
                .pend

S_TILEAT        .proc
                THROW ERR_ARGUMENT
                .pend

S_MEMCOPY       .proc
                THROW ERR_ARGUMENT
                .pend

;;;
;;; Directory navigation -- CD, PWD, MKDIR, RMDIR.
;;;
;;; New keywords, not ports: BASIC816 has no tokens for these because the
;;; C256 kernel it targeted had no working directory. The X816 kernel has
;;; carried all four calls from the start, so each of these is a handful
;;; of instructions over K_FS_CHDIR / GETCWD / MKDIR / RMDIR. Their
;;; tokens are added at the END of the table in tokens.s, guarded to this
;;; platform, so no existing token ID moves.
;;;
;;; The working directory belongs to the kernel, not to BASIC, so it is
;;; shared with the shell and it persists across a QUIT. Every relative
;;; path -- LOAD, SAVE, DIR, DEL -- resolves against it.
;;;

;
; Evaluate a path argument and leave it in C:X for a kernel call.
; BASIC816 strings are already NUL-terminated in memory, so the string
; pointer is handed over as-is rather than copied to a buffer.
;
PATHARG         .proc
                CALL SKIPWS
                CALL EVALEXPR
                CALL ASS_ARG1_STR
                setaxl
                LDA ARGUMENT1+2         ; LDX has no long addressing mode,
                TAX                     ;  so the bank goes through A
                LDA ARGUMENT1
                RETURN
                .pend

;
; CD <path> -- change the working directory
;
S_CD            .proc
                PHP
                TRACE "S_CD"
                setaxl

                CALL PATHARG
                JSL KERN_FS_CHDIR
                BCS cd_failed

                PLP
                RETURN

cd_failed       THROW ERR_DIRECTORY
                .pend

;
; MKDIR <path> -- create a directory
;
S_MKDIR         .proc
                PHP
                TRACE "S_MKDIR"
                setaxl

                CALL PATHARG
                JSL KERN_FS_MKDIR
                BCS mkdir_failed

                PLP
                RETURN

mkdir_failed    THROW ERR_DIRECTORY
                .pend

;
; RMDIR <path> -- remove an empty directory
;
S_RMDIR         .proc
                PHP
                TRACE "S_RMDIR"
                setaxl

                CALL PATHARG
                JSL KERN_FS_RMDIR
                BCS rmdir_failed

                PLP
                RETURN

rmdir_failed    THROW ERR_DIRECTORY
                .pend

;
; PWD -- print the working directory
;
; Takes no argument. DOS_PATH_BUFF is the scratch: it is 256 bytes and
; the kernel's paths cap at 80, and nothing else is using it between
; statements.
;
S_PWD           .proc
                PHP
                PHB
                TRACE "S_PWD"
                setaxl

                LDA #`DOS_PATH_BUFF     ; C:X = the buffer to fill
                TAX
                LDA #<>DOS_PATH_BUFF
                JSL KERN_FS_GETCWD
                BCS pwd_failed

                setdbr `DOS_PATH_BUFF   ; PRINTS takes the bank in B
                LDX #<>DOS_PATH_BUFF
                CALL PRINTS
                CALL PRINTCR

                PLB
                PLP
                RETURN

pwd_failed      THROW ERR_DIRECTORY
                .pend

;
; RENAME <old>, <new> -- rename a file
;
; The portable S_RENAME is guarded out for this platform (dos.s). It works
; by raw directory surgery: read the on-disk entry, edit the 8.3 name in
; place, write the sector back. The X816 kernel owns the FAT and hands
; out no sectors, so that approach cannot be made to work here -- but it
; has a rename call, which the C256 kernel did not.
;
; K_FS_RENAME takes a parameter block: a 24-bit pointer to the existing
; path, then a 24-bit pointer to the NEW BARE NAME. The second is not a
; path: renaming across directories means writing the entry somewhere
; else, which is a different operation.
;
S_RENAME        .proc
                PHP
                TRACE "S_RENAME"
                setaxl

                CALL SKIPWS
                CALL EVALEXPR               ; The existing name
                CALL ASS_ARG1_STR
                setal
                LDA ARGUMENT1
                STA @l FS_BLK
                LDA ARGUMENT1+2
                AND #$00FF
                STA @l FS_BLK+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal

                CALL EVALEXPR               ; The new name
                CALL ASS_ARG1_STR
                setal
                LDA ARGUMENT1
                STA @l FS_BLK+4
                LDA ARGUMENT1+2
                AND #$00FF
                STA @l FS_BLK+6

                LDA #`FS_BLK
                TAX
                LDA #<>FS_BLK
                JSL KERN_FS_RENAME
                BCS rename_failed

                PLP
                RETURN

rename_failed   THROW ERR_FILENOTFOUND
                .pend

;
; WAIT <milliseconds> -- pause.
;
; Reads the hardware millisecond counter rather than counting loop
; iterations, so the delay is the same at 8 MHz and at 14 MHz. Ctrl-C
; still gets you out: the break check runs every pass, which is what
; stops WAIT 100000 from wedging the machine for two minutes.
;
S_WAIT          .proc
                PHP
                TRACE "S_WAIT"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                setaxl
                LDA ARGUMENT1
                STA @l WAIT_N
                LDA ARGUMENT1+2
                STA @l WAIT_N+2

                JSL KERN_TIME_GET           ; target = now + interval
                CLC
                ADC @l WAIT_N
                STA @l WAIT_T
                TXA
                ADC @l WAIT_N+2
                STA @l WAIT_T+2

wait_loop       JSL FK_TESTBREAK
                BCS wait_break
                JSL KERN_TIME_GET
                SEC                         ; now - target, 32-bit
                SBC @l WAIT_T
                TXA
                SBC @l WAIT_T+2
                BCC wait_loop               ; still short of it

                PLP
                RETURN

wait_break      THROW ERR_BREAK
                .pend

;
; VSYNC -- wait for the start of the next frame.
;
; What makes flicker-free animation possible from BASIC: draw, VSYNC,
; draw. The frame counter is kept by the kernel's VSYNC interrupt, so
; this depends on interrupts being enabled -- see PORT.md section 4.
;
S_VSYNC         .proc
                PHP
                TRACE "S_VSYNC"
                setaxl

                JSL KERN_IRQ_FRAMES         ; the frame we are on now
                STA @l WAIT_N

vsync_loop      JSL FK_TESTBREAK
                BCS vsync_break
                JSL KERN_IRQ_FRAMES
                CMP @l WAIT_N
                BEQ vsync_loop

                PLP
                RETURN

vsync_break     THROW ERR_BREAK
                .pend

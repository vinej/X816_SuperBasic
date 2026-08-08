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

                setas               ; The PHA above ran in 8-bit mode and
                PLA                 ;  pushed ONE byte. Pulling it back with
                setal               ;  a 16-bit accumulator took TWO, and the
                AND #$00FF          ;  return address went with it -- so
                                    ;  TEXTCOLOR hung the machine every time
                                    ;  it was used.
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

S_BITMAP        .proc
                THROW ERR_ARGUMENT
                .pend

S_FILL          .proc
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

;;;
;;; Video: VRAM, the border and hardware scrolling.
;;;
;;; VERA's 128 KB is NOT in the CPU address space. It is reached through
;;; a port: an address in $9F20-$9F22, then reads or writes at $9F23.
;;; Data port 0 is used throughout, which is the same reasoning
;;; SCRCOPYLINE relies on -- the kernel's cursor interrupt uses port 1
;;; and restores what it touches, so port 0 is ours.
;;;

;
; VPOKE addr, value -- write a byte of VRAM.
;
; The address is 17 bits: bit 16 goes in the low bit of ADDR_H, whose
; upper nibble is the auto-increment and is left at zero here. A
; statement that set an increment would be lying about being a poke.
;
S_VPOKE         .proc
                PHP
                TRACE "S_VPOKE"
                setaxl

                CALL EVALEXPR               ; The VRAM address
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l VID_A
                LDA ARGUMENT1+2
                STA @l VID_A+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal

                CALL EVALEXPR               ; The byte
                CALL ASS_ARG1_BYTE

                setas
                LDA #0
                STA @l VERA_CTRL            ; Data port 0, DCSEL 0
                LDA @l VID_A
                STA @l VERA_ADDR_L
                LDA @l VID_A+1
                STA @l VERA_ADDR_M
                LDA @l VID_A+2
                AND #$01                    ; Bit 16, no auto-increment
                STA @l VERA_ADDR_H
                LDA ARGUMENT1
                STA @l VERA_DATA0

                PLP
                RETURN
                .pend

;
; BORDER c -- the colour around the display.
;
S_BORDER        .proc
                PHP
                TRACE "S_BORDER"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setas
                LDA #0                      ; DCSEL 0: the composer block
                STA @l VERA_CTRL
                LDA ARGUMENT1
                STA @l VERA_DC_BORDER

                PLP
                RETURN
                .pend

;
; SCROLLX n / SCROLLY n -- hardware scroll of the console layer, 0-4095.
;
; Free smooth scrolling: the display is offset by the hardware and
; nothing is redrawn. Only the LOW NIBBLE of the high byte is the
; scroll, so it is a read-modify-write -- clobbering the rest would
; disturb the layer.
;
S_SCROLLX       .proc
                PHP
                TRACE "S_SCROLLX"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT

                setas
                LDA #0
                STA @l VERA_CTRL
                LDA ARGUMENT1
                STA @l VERA_L0_HSCR_L
                LDA @l VERA_L0_HSCR_H
                AND #$F0                    ; keep what is not ours
                STA @l VID_A
                LDA ARGUMENT1+1
                AND #$0F
                ORA @l VID_A
                STA @l VERA_L0_HSCR_H

                PLP
                RETURN
                .pend

S_SCROLLY       .proc
                PHP
                TRACE "S_SCROLLY"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT

                setas
                LDA #0
                STA @l VERA_CTRL
                LDA ARGUMENT1
                STA @l VERA_L0_VSCR_L
                LDA @l VERA_L0_VSCR_H
                AND #$F0
                STA @l VID_A
                LDA ARGUMENT1+1
                AND #$0F
                ORA @l VID_A
                STA @l VERA_L0_VSCR_H

                PLP
                RETURN
                .pend

;
; PAL index, rgb -- set one of VERA's 256 palette entries.
;
; The palette is not a register block: it is VRAM, at $1FA00, two bytes
; an entry, little-endian. So this is a VPOKE in disguise, and the only
; reason it deserves a keyword is that working the address out by hand
; is exactly the sort of arithmetic a beginner's BASIC should absorb.
;
; The colour is 12-bit $0RGB. Entry 0 is the background.
;
; ADDR_H carries the auto-increment in its upper nibble; 1 there steps
; the address after each write, so the two bytes go out back to back.
;
S_PAL           .proc
                PHP
                TRACE "S_PAL"
                setaxl

                CALL EVALEXPR               ; Which entry
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                AND #$00FF
                ASL A                       ; Two bytes an entry
                CLC
                ADC #<>VERA_PALETTE
                STA @l VID_A

                setas
                LDA #','
                CALL EXPECT_TOK
                setal

                CALL EVALEXPR               ; The colour
                CALL ASS_ARG1_INT

                setas
                LDA #0
                STA @l VERA_CTRL            ; Data port 0, DCSEL 0
                LDA @l VID_A
                STA @l VERA_ADDR_L
                LDA @l VID_A+1
                STA @l VERA_ADDR_M
                LDA #$11                    ; Bit 16 set, auto-increment 1
                STA @l VERA_ADDR_H
                LDA ARGUMENT1               ; Green and blue
                STA @l VERA_DATA0
                LDA ARGUMENT1+1             ; Red
                AND #$0F
                STA @l VERA_DATA0

                PLP
                RETURN
                .pend

;
; SOUND voice, hz, volume -- play a tone on one of VERA's 16 PSG voices.
;
; The PSG is VRAM as well, at $1F9C0, four bytes a voice:
;
;   +0/+1  frequency, 16-bit
;   +2     bit 7 right, bit 6 left, bits 0-5 volume (0-63)
;   +3     bits 6-7 waveform, bits 0-5 pulse width
;
; The frequency register is not Hz. VERA steps a 17-bit phase by this
; value at 48828.125 Hz, so the register is Hz * 2^17 / 48828.125, or
; Hz * 2.68435456 -- and 440 Hz comes out as 1181. That multiply is done
; with the float engine rather than a scaled integer: the code is
; already there, already tested, and this is not a hot path.
;
; A voice keeps playing until it is silenced, so SOUND v,0,0 is how a
; note ends. Waveform is pulse at 50%, which is the one that sounds like
; something on every note; choosing others can come later.
;
S_SOUND         .proc
                PHP
                TRACE "S_SOUND"
                setaxl

                CALL EVALEXPR               ; Which voice, 0-15
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                AND #$000F
                ASL A                       ; Four bytes a voice
                ASL A
                CLC
                ADC #<>VERA_PSG
                STA @l VID_A

                setas
                LDA #','
                CALL EXPECT_TOK
                setal

                CALL EVALEXPR               ; Frequency, in Hz
                CALL ASS_ARG1_INT
                CALL ITOF
                setal
                LDA #<>FC_PSGHZ             ; * 2.68435456
                STA ARGUMENT2
                LDA #(FC_PSGHZ) >> 16
                STA ARGUMENT2+2
                setas
                LDA #TYPE_FLOAT
                STA ARGTYPE2
                setal
                CALL OP_FP_MUL
                CALL FTOI
                LDA ARGUMENT1
                STA @l VID_A+4              ; keep the register value

                setas
                LDA #','
                CALL EXPECT_TOK
                setal

                CALL EVALEXPR               ; Volume, 0-63
                CALL ASS_ARG1_BYTE

                setas
                LDA #0
                STA @l VERA_CTRL            ; Data port 0, DCSEL 0
                LDA @l VID_A
                STA @l VERA_ADDR_L
                LDA @l VID_A+1
                STA @l VERA_ADDR_M
                LDA #$11                    ; Bit 16, auto-increment 1
                STA @l VERA_ADDR_H

                LDA @l VID_A+4              ; frequency, low then high
                STA @l VERA_DATA0
                LDA @l VID_A+5
                STA @l VERA_DATA0
                LDA ARGUMENT1               ; volume, both channels
                AND #$3F
                ORA #$C0
                STA @l VERA_DATA0
                LDA #$20                    ; pulse, 50% duty
                STA @l VERA_DATA0

                PLP
                RETURN
                .pend

.include "X816/sprites_x816.s"

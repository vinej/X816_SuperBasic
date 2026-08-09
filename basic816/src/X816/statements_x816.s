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

                setas
                LDA ARGUMENT1       ; Park the background: the shadow below
                AND #$0F            ;  needs it after the pull, and the pull
                STA @l VID_A        ;  is what puts the foreground in A

                setaxl
                LDA @l VID_A        ; X = background
                AND #$000F
                TAX

                setas               ; The PHA above ran in 8-bit mode and
                PLA                 ;  pushed ONE byte. Pulling it back with
                setal               ;  a 16-bit accumulator took TWO, and the
                AND #$00FF          ;  return address went with it -- so
                                    ;  TEXTCOLOR hung the machine every time
                                    ;  it was used.
                STA @l VID_A+2      ; the foreground, kept across the shadow

                setas               ; The shadow, in CURCOLOR's C256 layout:
                LDA @l VID_A+2      ;  foreground high, background low. This
                .rept 4             ;  statement is the only one that knows
                ASL A               ;  BOTH halves, so it is the one that has
                .next               ;  to keep it -- SETBGCOLOR sets half and
                ORA @l VID_A        ;  reads the other half from here, the
                STA @l CURCOLOR     ;  kernel having no way to be asked.

                setal
                LDA @l VID_A+2      ; C = foreground
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

; SETBGCOLOR and SETBORDER are real now -- further down this file, with
; TEXTCOLOR and BORDER, which are what they are each half of.

; SETCOLOR is real now -- X816/vramio_x816.s, beside the rest of the
; palette. It stayed a stub here for as long as PAL was the only way to
; write an entry.

; BITMAP is real now -- X816/shapes_x816.s, with the rest of the
; bitmap statements. Its token was spent by BASIC816 long ago, so
; implementing it cost none.

S_FILL          .proc
                THROW ERR_ARGUMENT
                .pend

;
; MEMCOPY src,dst,len -- a block copy anywhere in the 16 MB.
;
; The source is read through MTEMP, which is the only [ptr] this file
; can have -- the direct page is one page and full (PORT.md 19) -- so
; the DESTINATION uses the same trick the bitmap code does: its bank
; goes into DBR and the store is a plain absolute-indexed one.
;
; The bank is set ONCE and again only when the destination offset wraps,
; so a 64 KB run costs one bank switch and not 65,536 of them. The
; source needs no such care: INC on a 32-bit pointer carries into its
; bank by itself.
;
; FORWARD, one byte at a time. Two consequences worth stating rather
; than discovering:
;
; OVERLAP IS NOT HANDLED. Copying a region on top of itself works when
; the destination is BELOW the source and scrambles it when the
; destination is above and closer than len -- the classic memmove
; problem. Going backwards in that case is four more instructions and
; is not done, because a block move that silently chose a direction
; would be worse than one that says which it uses.
;
; IT IS NOT THE BLITTER. help/MEMORY.TXT says this would be the place
; to use hardware fill or blit, and VERAFX is where those live; this is
; the CPU doing it, which works everywhere including on itself.
;
S_MEMCOPY       .proc
                PHP
                TRACE "S_MEMCOPY"
                PHB
                setaxl

                CALL EVALEXPR               ; source
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l MC_S
                LDA ARGUMENT1+2
                STA @l MC_S+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; destination
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l MC_D
                LDA ARGUMENT1+2
                STA @l MC_D+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; length
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l MC_N
                LDA ARGUMENT1+2
                STA @l MC_N+2

                setal                       ; MTEMP is the source cursor, and
                LDA @l MC_S                 ;  it is set AFTER the last
                STA MTEMP                   ;  EVALEXPR: it is shared scratch
                LDA @l MC_S+2               ;  and an expression can stream
                STA MTEMP+2                 ;  a loaded file through it

mc_bank         setaxl                      ; the destination bank into DBR
                LDA @l MC_D+2
                setas
                PHA
                PLB
                setaxl
                LDA @l MC_D                 ; and its offset into X. LDX has
                TAX                         ;  no long addressing mode, which
                                            ;  is why the bank went through A
                                            ;  above as well.

mc_loop         LDA @l MC_N                 ; anything left?
                ORA @l MC_N+2
                BEQ mc_done

                setas
                LDA [MTEMP]
                STA @w 0,X
                setal

                INC MTEMP                   ; the source carries into its own
                BNE mc_count                ;  bank
                INC MTEMP+2

mc_count        LDA @l MC_N                 ; one fewer, 32-bit
                BNE mc_low
                LDA @l MC_N+2
                DEC A
                STA @l MC_N+2
                LDA #$FFFF
                STA @l MC_N
                BRA mc_next
mc_low          DEC A
                STA @l MC_N

mc_next         INX                         ; and the destination. X wrapping
                BNE mc_loop                 ;  to 0 is the bank boundary, and
                                            ;  the only time DBR has to move
                LDA @l MC_D+2
                INC A
                STA @l MC_D+2
                LDA #0
                STA @l MC_D
                BRA mc_bank

mc_done         PLB
                PLP
                RETURN
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

wait_loop       CALL ENV_POLL               ; a note releasing across a WAIT
                                            ;  has to keep moving, or the
                                            ;  whole fade happens in the one
                                            ;  step after it
                JSL FK_TESTBREAK
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

vsync_loop      CALL ENV_POLL               ; the same reason as WAIT, and the
                                            ;  loop a game actually sits in
                JSL FK_TESTBREAK
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
; QUIT -- hand the machine back to the shell.
;
; Until now the only way out of SuperBasic was to reset the machine,
; which is a poor answer on a computer whose whole boot story is "the
; shell runs an ordinary program" (HELP SYSTEM).
;
; K_EXIT does not return on success, so nothing follows the call. The
; RETURN below is for the failure the kernel is entitled to report and
; which nothing here can do anything about.
;
; ONE NAME, not two. help/SYSTEM.TXT lists "QUIT / SYSTEM" and only QUIT
; is taken: a second spelling costs a token, and PORT.md 29 spent an
; afternoon establishing that tokens are the ceiling on finishing these
; pages while bytes are not. SETBORDER below is kept as a second name
; only because its token was spent by BASIC816 before this port existed.
;
S_QUIT          .proc
                PHP
                TRACE "S_QUIT"
                setaxl

                LDA #0                      ; exit status
                JSL KERN_EXIT

                PLP
                RETURN
                .pend

;
; TURBO n -- 0 for 8 MHz, anything else for 14 MHz.
;
; SYSCTL bit 2 (MEMORY_MAP.md). It is a CLOCK ENABLE and not a clock
; switch, so it may be flipped at any moment: nothing glitches and no
; reset is needed. Bit 0 is the boot-ROM overlay and bit 1 reads the
; CPU's live E flag, so this is a read-modify-write and not a store --
; putting a whole byte here would drop the overlay bit on a machine that
; still had it.
;
; Reading it back gives the EFFECTIVE speed, which is this bit ORed with
; the MiSTer OSD's own Turbo setting. So TURBO 0 does not guarantee
; 8 MHz: it releases the software half of the decision. A program that
; needs to know should read $9F80 rather than remember what it wrote.
;
S_TURBO         .proc
                PHP
                TRACE "S_TURBO"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setas
                LDA @l SYSCTL
                AND #$FB                    ; everything but bit 2
                STA @l VID_A
                LDA ARGUMENT1
                BEQ tb_slow
                LDA #$04
                ORA @l VID_A
                BRA tb_put
tb_slow         LDA @l VID_A
tb_put          STA @l SYSCTL

                PLP
                RETURN
                .pend

;
; SETBORDER c -- the colour around the display.
;
; THE SAME STATEMENT AS BORDER, under the name BASIC816 gave it, and
; that is worth being plain about: help/AUDIOPCM.TXT removed PCMPUT for
; being one page asking twice for one thing. This is two PAGES asking
; once each -- CONSOLE has always listed SETBORDER and VIDEO lists
; BORDER -- and, more to the point, SETBORDER's token is a BASE one
; spent by BASIC816 long before this port existed. Keeping it costs
; nothing today; the base slot is there to reclaim on the day the base
; table needs one back, and SAVE writes ASCII rather than tokens, so
; reclaiming it would not spoil anybody's stored program.
;
; NOT the C256's SETBORDER, which took a visibility flag and an RGB
; triple. VERA's border is one byte: an index into the 256-colour
; palette, the same numbers PAL writes.
;
S_SETBORDER     .proc
                JMP S_BORDER        ; a tail call: S_BORDER's RTS returns
                .pend               ;  straight to our caller

;
; SETBGCOLOR c -- the background of everything printed from now on, 0-15.
;
; TEXTCOLOR's second argument on its own, which is exactly what
; help/CONSOLE.TXT asked for and exactly why it needed a shadow. The
; kernel takes the pair together (K_CON_COLOR, foreground in C and
; background in X) and offers no call to ask what they currently are --
; there is no K_CON_GETCOLOR -- so setting half of a pair means
; remembering the other half. TEXTCOLOR keeps CURCOLOR for that, and
; INITIO seeds it with what the kernel's console actually boots at.
;
; Text already on the screen keeps the background it was drawn with,
; like TEXTCOLOR and for the same reason: the attribute is a pen, not a
; property of the screen.
;
S_SETBGCOLOR    .proc
                PHP
                TRACE "S_SETBGCOLOR"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setas
                LDA ARGUMENT1
                AND #$0F                    ; the new background
                STA @l VID_A
                LDA @l CURCOLOR
                AND #$F0                    ; the foreground stays exactly
                ORA @l VID_A                ;  where it was
                STA @l CURCOLOR

                setaxl
                LDA @l VID_A                ; X = background
                AND #$000F
                TAX
                LDA @l CURCOLOR             ; C = foreground. The 16-bit read
                AND #$00F0                  ;  takes CTRL_DOWN beside it, so
                .rept 4                     ;  the mask is not decoration.
                LSR A
                .next
                JSL KERN_CON_COLOR

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
                STA @l ENV_SV               ; kept for the envelope below.
                                            ;  Safe across the two EVALEXPRs
                                            ;  that follow: nothing an
                                            ;  expression can reach writes it,
                                            ;  because the only other writer
                                            ;  is a STATEMENT.
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

                ; ---- an armed voice does not get the volume it was given
                ;
                ; It gets ZERO, and the volume becomes the PEAK the frame
                ; tick walks up to (X816/psgenv_x816.s). A voice with no
                ; envelope falls straight through and this statement is
                ; what it always was.
                ;
                ; VOLUME 0 STILL STOPS IT DEAD, envelope or not. SOUND
                ; v,0,0 is how every program written against this BASIC
                ; ends a note, help/AUDIOFM.TXT says so in as many words,
                ; and quietly turning it into a release would break all of
                ; them to save ENVOFF one line.
                setaxl
                LDA @l ENV_SV
                .rept 4                     ; the record index is voice*16
                ASL A
                .next
                STA @l ENV_P
                TAX
                setas
                LDA @l ENV_TAB+11,X         ; armed?
                BEQ snd_write
                setal
                LDA ARGUMENT1
                BEQ snd_stop

                setas
                LDA ARGUMENT1
                AND #$3F
                STA @l ENV_TAB+1,X          ; the peak
                STA @l AUD_T                ; and again, for the compare
                LDA @l ENV_TAB+10,X         ; the sustain level
                CMP @l AUD_T
                BCC snd_dtgt                ; below the peak: it is the target
                LDA @l AUD_T                ; at or above it: the decay must
                                            ;  not run UPHILL, so it stops
                                            ;  where the attack ended
snd_dtgt        STA @l ENV_TAB+13,X
                LDA #$C0                    ; both channels, as this statement
                STA @l ENV_TAB+12,X         ;  has always written them
                LDA #1                      ; attack
                STA @l ENV_TAB,X
                setal
                LDA #0
                STA @l ENV_TAB+2,X          ; from silence
                STA ARGUMENT1               ; ...which is what gets written
                BRA snd_write

snd_stop        setas
                LDA #0
                STA @l ENV_TAB,X            ; phase off

snd_write       setas
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

                ; A zero-frame attack has to be audible NOW rather than at
                ; the next frame, or ENV v,0,0,63,0 -- the degenerate
                ; envelope that should behave exactly like plain SOUND --
                ; would start every note a frame late and silent.
                setaxl
                LDA @l ENV_P
                TAX
                setas
                LDA @l ENV_TAB,X
                CMP #1                      ; did the block above trigger it?
                BNE snd_done
                CALL ENV_STEPV
snd_done
                PLP
                RETURN
                .pend

.include "X816/sprites_x816.s"

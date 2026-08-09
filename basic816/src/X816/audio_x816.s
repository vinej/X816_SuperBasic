;;;
;;; PCM sample playback and the YM2151 FM chip
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; Two entirely separate sound chips, kept in one file because both are
;;; register protocols rather than the VRAM pokes the PSG turned out to
;;; be (SOUND, in statements_x816.s).
;;;
;;; VERA PCM is three registers at $9F3B-$9F3D: a control byte, a rate,
;;; and a FIFO you push samples into. Both the control byte and the rate
;;; read back, which is why the checks for this can assert on something.
;;;
;;; The YM2151 is two registers at $9F40/$9F41 -- an address latch and a
;;; data port -- and NOTHING reads back. Its status register returns
;;; timer and busy flags, never a register value. So the FM statements
;;; here can be shown to write, but not to have written correctly; the
;;; note tables below were computed rather than guessed for that reason.
;;;

VERA_AUDIO_CTRL = $9F3B     ; volume 3:0, 16-bit 5, stereo 4, FIFO ctl 7:6
VERA_AUDIO_RATE = $9F3C     ; 0 = stopped, 128 = 48.8 kHz
VERA_AUDIO_DATA = $9F3D     ; write-only FIFO

YM_ADDR         = $9F40
YM_DATA         = $9F41

;
; PCMVOL v -- output volume, 0 to 15.
;
; Read-modify-write: the same byte carries the sample format, and a
; program that sets the volume has usually already set the format.
;
S_PCMVOL        .proc
                PHP
                TRACE "S_PCMVOL"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setas
                LDA @l VERA_AUDIO_CTRL
                AND #$F0                ; keep format, drop the old volume
                STA @l VID_A
                LDA ARGUMENT1
                AND #$0F
                ORA @l VID_A
                STA @l VERA_AUDIO_CTRL

                PLP
                RETURN
                .pend

;
; PCMRATE n -- sample rate, 0 to 128.
;
; The step is 25000000/(512*128) Hz, about 381.5 Hz, so 128 is roughly
; 48.8 kHz and 0 stops playback without disturbing anything else. A
; value above 128 is read by the hardware as 256-n, which is a wrap
; rather than a clamp, so it is refused here instead.
;
S_PCMRATE       .proc
                PHP
                TRACE "S_PCMRATE"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                AND #$00FF
                CMP #129
                BCS pcr_bad

                setas
                LDA ARGUMENT1
                STA @l VERA_AUDIO_RATE

                PLP
                RETURN

pcr_bad         PLP
                THROW ERR_ARGUMENT
                .pend

;
; PCMMODE bits, stereo -- 8 or 16 bit, 0 mono or 1 stereo.
;
S_PCMMODE       .proc
                PHP
                TRACE "S_PCMMODE"
                setaxl

                CALL EVALEXPR           ; sample width
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                AND #$00FF
                CMP #16
                BEQ pcm_16
                CMP #8
                BNE pcm_bad
                LDA #0
                BRA pcm_keep
pcm_16          LDA #$20                ; bit 5
pcm_keep        STA @l VID_A

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; mono or stereo
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                AND #$0001
                BEQ pcm_mono
                LDA #$10                ; bit 4
                ORA @l VID_A
                STA @l VID_A
pcm_mono
                setas
                LDA @l VERA_AUDIO_CTRL
                AND #$0F                ; keep the volume
                ORA @l VID_A
                STA @l VERA_AUDIO_CTRL

                PLP
                RETURN

pcm_bad         PLP
                THROW ERR_ARGUMENT
                .pend

;
; PCMRESET -- empty the FIFO and silence the channel.
;
; Bit 7 alone resets. Bits 7 and 6 together mean LOOP on this hardware,
; not "reset harder", so the two must never be set at once here.
;
S_PCMRESET      .proc
                PHP
                TRACE "S_PCMRESET"
                CALL PCM_STOP           ; and stop the feeder, if PCMPLAY
                                        ;  started one. Emptying the FIFO
                                        ;  under a handler that is refilling
                                        ;  it does nothing you can hear.
                setas
                LDA @l VERA_AUDIO_CTRL
                AND #$3F
                ORA #$80
                STA @l VERA_AUDIO_CTRL
                LDA #0
                STA @l VERA_AUDIO_RATE
                PLP
                RETURN
                .pend

;
; PCMOUT b -- push one sample byte into the FIFO.
;
; The FIFO is 4096 bytes and silently drops writes when it is full, so a
; program feeding it faster than the rate drains it loses samples with
; no indication. PCMFREE is how to avoid that.
;
S_PCMOUT        .proc
                PHP
                TRACE "S_PCMOUT"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                setas
                LDA ARGUMENT1
                STA @l VERA_AUDIO_DATA

                PLP
                RETURN
                .pend

;
; PCMFREE -- 1 while the FIFO has room, 0 when it is full.
;
; Takes no argument, so it is spelled without parentheses. The hardware
; reports full and empty rather than a level, which is enough for the
; only loop that matters: WHILE PCMFREE ... PCMOUT ... WEND.
;
FN_PCMFREE      .proc
                PHP
                setaxl

                setas
                LDA @l VERA_AUDIO_CTRL
                AND #$80                ; bit 7: FIFO full
                BEQ pfr_room

                setal
                LDA #0
                BRA pfr_ret
pfr_room        setal
                LDA #1
pfr_ret         STA ARGUMENT1
                STZ ARGUMENT1+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                PLP
                RETURN
                .pend

;
; PCMFULL / PCMEMPTY -- the two bits the hardware reports.
;
; PCMEMPTY is the one a feeder actually wants and PCMFULL is the one it
; is tempting to use: by the time the FIFO is EMPTY the sound has already
; stopped, so a loop that waits for empty before topping up is a loop
; that clicks. Wait for not-full instead. Both are here because the
; hardware reports both and guessing which one somebody needs is not this
; layer's job.
;
FN_PCMFULL      .proc
                PHP
                setaxl
                setas
                LDA @l VERA_AUDIO_CTRL
                AND #$80                ; bit 7: full
                BRA pcm_flag
                .pend

FN_PCMEMPTY     .proc
                PHP
                setaxl
                setas
                LDA @l VERA_AUDIO_CTRL
                AND #$40                ; bit 6: empty
                ; falls into the shared tail
                .pend

;
; Shared by the two above: a non-zero A is true, and true is -1.
;
pcm_flag        BEQ pcm_false
                setal
                LDA #$FFFF
                STA ARGUMENT1
                STA ARGUMENT1+2
                BRA pcm_ftype
pcm_false       setal
                LDA #0
                STA ARGUMENT1
                STZ ARGUMENT1+2
pcm_ftype       setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                PLP
                RETURN

;
; PCMCTRL n -- the control byte at $9F3B, written whole.
;
; Volume 3:0, stereo 4, 16-bit 5, and bit 7 resets the FIFO. The escape
; hatch under PCMVOL and PCMMODE, which read-modify-write this same byte
; so that setting one does not clear the other.
;
; BIT 6 IS REFUSED. On this hardware bits 7 and 6 together mean LOOP, not
; "reset harder", and a program that meant to reset and set both gets a
; FIFO that repeats forever instead. The two bits are readable as full
; and empty, which is where the confusion comes from: they do not mean
; the same thing in both directions.
;
S_PCMCTRL       .proc
                PHP
                TRACE "S_PCMCTRL"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setas
                LDA ARGUMENT1
                AND #$C0
                CMP #$C0
                BEQ pc_bad

                LDA ARGUMENT1
                STA @l VERA_AUDIO_CTRL

                PLP
                RETURN
pc_bad          THROW ERR_ARGUMENT
                .pend

;;;
;;; PCMPLAY -- a sample fed to the FIFO by an interrupt
;;;
;;; The statement most people want, and the one that could not be written
;;; until IRQ existed. What makes it different from the WHILE PCMFREE
;;; loop on the help page is that the program CARRIES ON: the refill runs
;;; off KIRQ_AFLOW, VERA's "the FIFO is running low" interrupt.
;;;
;;; It has to be machine code and it has to be here rather than a
;;; deferred BASIC handler, for the reason help/SYSTEM.TXT gives: a FIFO
;;; that must be refilled before it empties cannot wait for the
;;; interpreter to finish the statement it is on.
;;;
;;; STREAMING, honestly: the whole sample is read into SDRAM first and
;;; the interrupt feeds from THERE. Reading the card at interrupt time is
;;; not an option -- the kernel's file calls are not re-entrant, and an
;;; SD transfer freezes the CPU for its whole length, which would stop
;;; the very interrupt doing the reading.
;;;

;
; The handler. Reached by JSL with D = $0000, DBR = $00 and 16-bit
; registers, and must leave by RTL. A, X and Y are free -- the kernel
; dispatcher saved the interrupted code's.
;
; It must not enable interrupts and it does not: nothing here is a kernel
; call.
;
PCM_FEED        .proc
                PHD                     ; the sample pointer is a direct-page
                setal                   ;  variable, because [ptr] is the
                PHA                     ;  only way to read across banks and
                LDA #<>GLOBAL_VARS      ;  that mode exists nowhere else.
                TCD                     ;  D arrives as 0 and has to be put
                PLA                     ;  back before the RTL.
                .dpage GLOBAL_VARS

pf_loop         setal
                LDA @l PCM_LEN          ; anything left?
                ORA @l PCM_LEN+2
                BEQ pf_done

                setas
                LDA @l VERA_AUDIO_CTRL
                AND #$80                ; full? then this refill is finished
                BNE pf_out

                setas
                LDA [PCM_PTR]
                STA @l VERA_AUDIO_DATA

                setal
                INC PCM_PTR             ; 16-bit, so the bank only moves when
                BNE pf_count            ;  the low word wraps
                INC PCM_PTR+2

pf_count        LDA @l PCM_LEN
                BNE pf_low
                LDA @l PCM_LEN+2
                DEC A
                STA @l PCM_LEN+2
                LDA #$FFFF
                STA @l PCM_LEN
                BRA pf_loop
pf_low          DEC A
                STA @l PCM_LEN
                BRA pf_loop

                ; The sample ran out. Switch the source off from in here:
                ; AFLOW cannot be acknowledged -- refilling the FIFO is the
                ; acknowledgement -- so a handler that returns without
                ; either refilling or disabling it is called again
                ; immediately, forever.
pf_done         setas
                LDA @l VERA_IEN
                AND #$F7                ; ~AFLOW, keeping IRQLINE's ninth bit
                STA @l VERA_IEN
                LDA #0
                STA @l PCM_ON

pf_out          setal
                PLD
                .dpage GLOBAL_VARS
                RTL
                .pend

;
; Stop the feeder: disable the source and give the slot back.
;
; Safe to call when nothing is playing, which is why PCMRESET can call it
; unconditionally.
;
PCM_STOP        .proc
                PHP
                setaxl
                PHX
                PHY

                setas
                LDA @l PCM_ON
                BEQ ps_done

                setas                   ; the source first, then the slot:
                LDA @l VERA_IEN         ;  the other order leaves a moment
                AND #$F7                ;  where an AFLOW can arrive with no
                STA @l VERA_IEN         ;  handler behind it
                LDA #0
                STA @l PCM_ON

                setal
                LDA #0
                STA @l PCM_LEN
                STA @l PCM_LEN+2

                setaxl                  ; installing 0 clears the slot
                LDX #0
                LDY #0
                LDA #KIRQ_AFLOW
                JSL KERN_IRQ_SET

ps_done         PLY
                PLX
                PLP
                RETURN
                .pend

;
; PCMPLAY file$ -- play a raw sample off the card, in the background.
;
; The sample is raw: no header, no rate, no channel count. PCMRATE and
; PCMMODE say how to play it, because the file does not.
;
S_PCMPLAY       .proc
                PHP
                TRACE "S_PCMPLAY"
                setaxl

                CALL PCM_STOP           ; whatever was playing, is not now

                CALL EVALEXPR
                CALL ASS_ARG1_STR
                CALL SETFILEDESC
                CALL VIO_LOAD           ; the staging buffer, and VIO_N

                setal                   ; the feeder reads from there
                LDA #<>VIO_STAGE
                STA PCM_PTR
                LDA #`VIO_STAGE
                STA PCM_PTR+2
                LDA @l VIO_N
                STA @l PCM_LEN
                LDA @l VIO_N+2
                STA @l PCM_LEN+2

                LDA @l VIO_N            ; an empty file is not a sample
                ORA @l VIO_N+2
                BEQ pp_done

                setas
                LDA #1
                STA @l PCM_ON

                setaxl                  ; the handler, THEN the source: a
                LDY #`PCM_FEED          ;  source that asserts with nothing
                LDX #<>PCM_FEED         ;  installed is switched off by the
                LDA #KIRQ_AFLOW         ;  kernel's stuck-source defence
                JSL KERN_IRQ_SET
                BCS pp_bad

                CALL PCM_FEED_NOW       ; prime it: AFLOW only fires once the
                                        ;  FIFO has drained, and an empty
                                        ;  FIFO never drains
                setas
                LDA @l VERA_IEN
                ORA #$08                ; AFLOW on
                STA @l VERA_IEN

pp_done         PLP
                RETURN
pp_bad          PLP
                THROW ERR_ARGUMENT
                .pend

;
; Fill the FIFO once from BASIC, by calling the handler the long way
; round. It is written to be reached by JSL with D = 0, so that is how it
; is reached.
;
PCM_FEED_NOW    .proc
                PHP
                PHD
                setal
                LDA #0                  ; the environment the handler is
                TCD                     ;  documented to run in
                .dpage 0
                JSL PCM_FEED
                PLD
                .dpage GLOBAL_VARS
                PLP
                RETURN
                .pend

;;;
;;; YM2151
;;;
;;; Eight FM channels. Writing a register is: put the number in $9F40,
;;; the value in $9F41. The chip is busy for a while afterwards, and the
;;; emulator does not enforce it, but real hardware does -- so every
;;; write here goes through YM_POKE, which is the one place a wait would
;;; have to be added.
;;;

;
; Write A (8-bit) to YM register X (8-bit).
;
YM_POKE         .proc
                PHP
                setas
                STA @l VID_A+1
                TXA
                STA @l YM_ADDR
                LDA @l VID_A+1
                STA @l YM_DATA

                ; And remember it, because the chip will not. There is no
                ; register readback in the hardware at all, so YMPEEK can
                ; only be a shadow -- and a shadow is worth nothing unless
                ; EVERY write passes through here, which is why FMINIT,
                ; FMNOTE, FMVOL and the rest all call this rather than
                ; touching $9F40 themselves.
                setaxl
                PHX                     ; the caller built X in 8-bit mode,
                TXA                     ;  so its high byte can be whatever
                AND #$00FF              ;  the hidden accumulator half held
                TAX
                setas
                LDA @l VID_A+1
                STA @l YM_SHADOW,X
                setaxl
                PLX

                PLP
                RETURN
                .pend

;
; YMPEEK(reg) -- what was last written to a YM2151 register.
;
; A SHADOW, not a probe. The chip answers writes only: its status
; register returns the busy flag and the two timer flags and nothing
; else, so there is no way to ask it what it holds. A register nothing
; has written since the machine came up reads 0 here, which is what the
; shadow was cleared to and not what the chip contains.
;
FN_YMPEEK       .proc
                FN_START "FN_YMPEEK"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setaxl
                LDA ARGUMENT1
                AND #$00FF
                TAX
                setas
                LDA @l YM_SHADOW,X

                setal
                AND #$00FF
                STA ARGUMENT1
                STZ ARGUMENT1+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

;
; YMPOKE reg, value -- the escape hatch, for everything below that has
; no keyword. Every FM statement here is a shorthand for some of these.
;
S_YMPOKE        .proc
                PHP
                TRACE "S_YMPOKE"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                STA @l VID_A+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setas                   ; LDX has no long addressing mode,
                LDA @l VID_A+2          ;  so the register number goes via A
                TAX
                LDA ARGUMENT1
                CALL YM_POKE

                PLP
                RETURN
                .pend

;
; FMINIT -- silence every channel and load one usable instrument on all
; eight, so that FMNOTE makes a sound before anything is configured.
;
; Without this the chip powers up with every operator at zero output
; level and total silence, which reads as "FM is broken" rather than
; "FM needs an instrument".
;
; The patch is a plain two-operator sound: modulator M1 feeding carrier
; C1, algorithm 7 so all four operators are carriers, a fast attack and
; a medium decay. It is not a good instrument. It is an audible one.
;
S_FMINIT        .proc
                PHP
                TRACE "S_FMINIT"
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHX
                PHY

                setas
                LDX #$01                ; test/LFO reset
                LDA #$00
                CALL YM_POKE
                LDX #$0F                ; noise off
                LDA #$00
                CALL YM_POKE

                LDY #0                  ; for each of the eight channels
fmi_chan        setas
                TYA                     ; $20+ch: right+left on, algorithm 7
                CLC
                ADC #$20
                TAX
                LDA #$C7
                CALL YM_POKE

                TYA                     ; $38+ch: no PMS/AMS
                CLC
                ADC #$38
                TAX
                LDA #$00
                CALL YM_POKE

                ; The operator registers are laid out channel-by-channel
                ; within each block of 32: register $40+op*8+ch. All four
                ; operators get the same settings here.
                PHY
                LDA #0
                STA @l VID_A+3          ; operator counter
fmi_op          setas
                LDA @l VID_A+3
                .rept 3
                ASL A
                .next
                STA @l VID_A+4          ; op*8

                TYA                     ; $40 detune/multiple
                CLC
                ADC @l VID_A+4
                CLC
                ADC #$40
                TAX
                LDA #$01                ; multiple 1, no detune
                CALL YM_POKE

                TYA                     ; $60 total level: 0 is loudest
                CLC
                ADC @l VID_A+4
                CLC
                ADC #$60
                TAX
                LDA #$1B
                CALL YM_POKE

                TYA                     ; $80 attack rate
                CLC
                ADC @l VID_A+4
                CLC
                ADC #$80
                TAX
                LDA #$1F                ; as fast as it goes
                CALL YM_POKE

                TYA                     ; $A0 first decay
                CLC
                ADC @l VID_A+4
                CLC
                ADC #$A0
                TAX
                LDA #$0D
                CALL YM_POKE

                TYA                     ; $C0 second decay
                CLC
                ADC @l VID_A+4
                CLC
                ADC #$C0
                TAX
                LDA #$00                ; none: hold until key off
                CALL YM_POKE

                TYA                     ; $E0 sustain level / release
                CLC
                ADC @l VID_A+4
                CLC
                ADC #$E0
                TAX
                LDA #$1F                ; quick release
                CALL YM_POKE

                setas
                LDA @l VID_A+3
                INC A
                STA @l VID_A+3
                CMP #4
                BCC fmi_op
                PLY

                setal
                INY
                CPY #8
                BCS fmi_alldone
                BRL fmi_chan            ; six operator writes a channel puts
                                        ;  this well out of BCC range
fmi_alldone
                PLY
                PLX
                PLP
                RETURN
                .pend

;
; Note number to the YM2151's key code.
;
; The chip does not take semitones. It takes an octave in bits 6:4 and a
; note in bits 3:0, and the note field SKIPS the values 3, 7, 11 and 15
; -- it counts 0,1,2, 4,5,6, 8,9,10, 12,13,14, twelve usable codes out
; of sixteen. Getting that wrong transposes everything above D by a
; semitone, which is the sort of bug that sounds like bad tuning rather
; than bad code, so the twelve codes are a table and not arithmetic.
;
YM_KEYCODE      .byte $0E,$00,$01,$02,$04,$05,$06,$08,$09,$0A,$0C,$0D

;
; FMNOTE ch, note -- key a note on. Note 0 is C in the lowest octave and
; every 12 is an octave; 48 is somewhere near middle C.
;
S_FMNOTE        .proc
                PHP
                TRACE "S_FMNOTE"
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHX

                CALL EVALEXPR           ; channel
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                AND #$0007
                STA @l VID_A+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; note
                CALL ASS_ARG1_BYTE

                LDA ARGUMENT1           ; octave = note/12, degree = note MOD 12
                AND #$00FF
                LDX #0
fmn_oct         CMP #12
                BCC fmn_have
                SEC
                SBC #12
                INX
                CPX #8
                BCC fmn_oct
                DEX                     ; clamp rather than wrap round
                CLC
                ADC #12

fmn_have        PHX                     ; A = degree 0-11
                TAX
                setas
                LDA @l YM_KEYCODE,X
                STA @l VID_A+5
                setal
                PLA                     ; the octave back
                .rept 4
                ASL A
                .next
                setas
                ORA @l VID_A+5
                STA @l VID_A+5

                setas                   ; key off first, or a note already
                LDX #$08                ;  sounding will not retrigger
                LDA @l VID_A+2          ; $08: channel, no operator bits
                CALL YM_POKE

                setas                   ; $28+ch: octave and note
                LDA @l VID_A+2
                CLC
                ADC #$28
                TAX
                LDA @l VID_A+5
                CALL YM_POKE

                setas                   ; $30+ch: no fine detune
                LDA @l VID_A+2
                CLC
                ADC #$30
                TAX
                LDA #$00
                CALL YM_POKE

                setas                   ; $08: all four operators on
                LDX #$08
                LDA @l VID_A+2
                ORA #$78
                CALL YM_POKE

                PLX
                PLP
                RETURN
                .pend

;
; FMOFF ch -- key off. A note held is a note that keeps playing.
;
S_FMOFF         .proc
                PHP
                TRACE "S_FMOFF"
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHX

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setas
                LDX #$08
                LDA ARGUMENT1
                AND #$07                ; operator bits clear = release
                CALL YM_POKE

                PLX
                PLP
                RETURN
                .pend

;
; FMVOL ch, vol -- channel volume 0 to 127, loudest at 127.
;
; The chip has no volume: it has a total-level attenuation per operator,
; where 0 is loudest and 127 is silent. So this inverts, and it applies
; the value only to the operators that are carriers -- with algorithm 7
; that is all four. Writing it to a modulator instead would change the
; timbre rather than the loudness, which is the classic FM mistake.
;
; A later raw YMPOKE at a $60-$7F register overrides this until the next
; FMVOL, because nothing shadows the value.
;
S_FMVOL         .proc
                PHP
                TRACE "S_FMVOL"
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHX

                CALL EVALEXPR           ; channel
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                AND #$0007
                STA @l VID_A+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; volume
                CALL ASS_ARG1_BYTE

                setas
                LDA ARGUMENT1           ; attenuation = 127 - volume
                CMP #128
                BCC fmv_ok
                LDA #127
fmv_ok          STA @l VID_A+4
                LDA #127
                SEC
                SBC @l VID_A+4
                STA @l VID_A+4

                LDA #0
                STA @l VID_A+3
fmv_op          setas                   ; $60 + op*8 + ch, all four operators
                LDA @l VID_A+3
                .rept 3
                ASL A
                .next
                CLC
                ADC @l VID_A+2
                CLC
                ADC #$60
                TAX
                LDA @l VID_A+4
                CALL YM_POKE

                setas
                LDA @l VID_A+3
                INC A
                STA @l VID_A+3
                CMP #4
                BCC fmv_op

                PLX
                PLP
                RETURN
                .pend

;
; FMPAN ch, lr -- 1 left, 2 right, 3 both.
;
; Register $20+ch also carries the algorithm and feedback, so this is a
; read-modify-write of a value the chip will not give back. FMINIT set
; it to $C7 and this keeps the low six bits of whatever FMINIT chose.
;
S_FMPAN         .proc
                PHP
                TRACE "S_FMPAN"
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHX

                CALL EVALEXPR           ; channel
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                AND #$0007
                STA @l VID_A+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; which side
                CALL ASS_ARG1_BYTE

                setas
                LDA ARGUMENT1
                AND #$03
                BNE fmp_ok
                LDA #$03                ; 0 would be inaudible: read it as both
fmp_ok          .rept 6
                ASL A
                .next
                ORA #$07                ; algorithm 7, as FMINIT set it
                STA @l VID_A+4

                LDA @l VID_A+2
                CLC
                ADC #$20
                TAX
                LDA @l VID_A+4
                CALL YM_POKE

                PLX
                PLP
                RETURN
                .pend

;;;
;;; Instruments
;;;
;;; A patch is 32 bytes: the two per-channel registers, then six values
;;; for each of the four operators. The chip wants them scattered across
;;; register blocks $40, $60, $80, $A0, $C0 and $E0, each indexed by
;;; operator*8 + channel -- so a patch is a table and applying one is a
;;; loop rather than a run of pokes.
;;;
;;;   +0       $20  right/left, feedback, connection
;;;   +1       $38  PMS/AMS
;;;   +2..+5   $40  detune 1 and multiple, per operator
;;;   +6..+9   $60  total level -- 0 is LOUDEST
;;;   +10..+13 $80  key scale and attack rate
;;;   +14..+17 $A0  AM enable and first decay rate
;;;   +18..+21 $C0  detune 2 and second decay rate
;;;   +22..+25 $E0  first decay level and release rate
;;;   +26..+31 spare, so the stride is a shift
;;;
;;; THESE ARE SERVICEABLE, NOT CURATED, and saying so is the honest
;;; version. Patch 0 is byte for byte what FMINIT writes; the other seven
;;; were made by moving one thing at a time away from it -- brighter,
;;; duller, slower to start, quicker to stop. NOTHING HERE HAS BEEN
;;; HEARD: this file has no way to listen, and giving a sound a name
;;; nobody has checked would be worse than admitting that. What can be
;;; said is that they differ from each other, which is the least an
;;; instrument set has to do before anybody can improve it.
;;;
;;; FMINIT is deliberately NOT rewritten to load patch 0 through this
;;; path. It is a verified statement and it emits exactly these bytes
;;; already; sharing the code would be tidier and would put a working
;;; thing at risk to get there.
;;;

FM_PATCH_SIZE   = 32

fm_builtin
                ; 0: the FMINIT sound -- algorithm 7, all four operators
                ;    carriers, fast attack, medium decay.
                .byte $C7, $00
                .byte $01, $01, $01, $01
                .byte $1B, $1B, $1B, $1B
                .byte $1F, $1F, $1F, $1F
                .byte $0D, $0D, $0D, $0D
                .byte $00, $00, $00, $00
                .byte $1F, $1F, $1F, $1F
                .byte 0,0,0,0,0,0
                ; 1: quieter, slower to decay -- it holds.
                .byte $C7, $00
                .byte $01, $01, $02, $02
                .byte $20, $20, $24, $24
                .byte $1F, $1F, $1F, $1F
                .byte $04, $04, $04, $04
                .byte $00, $00, $00, $00
                .byte $0F, $0F, $0F, $0F
                .byte 0,0,0,0,0,0
                ; 2: fast decay, no sustain -- it plucks.
                .byte $C7, $00
                .byte $01, $01, $01, $02
                .byte $18, $18, $20, $20
                .byte $1F, $1F, $1F, $1F
                .byte $12, $12, $12, $12
                .byte $08, $08, $08, $08
                .byte $FF, $FF, $FF, $FF
                .byte 0,0,0,0,0,0
                ; 3: operators an octave apart -- hollow.
                .byte $C7, $00
                .byte $01, $02, $01, $02
                .byte $1B, $28, $1B, $28
                .byte $1F, $1F, $1F, $1F
                .byte $0A, $0A, $0A, $0A
                .byte $00, $00, $00, $00
                .byte $1F, $1F, $1F, $1F
                .byte 0,0,0,0,0,0
                ; 4: slow attack -- it swells rather than starts.
                .byte $C7, $00
                .byte $01, $01, $01, $01
                .byte $1B, $1B, $1B, $1B
                .byte $0C, $0C, $0C, $0C
                .byte $06, $06, $06, $06
                .byte $00, $00, $00, $00
                .byte $0A, $0A, $0A, $0A
                .byte 0,0,0,0,0,0
                ; 5: high multiples -- metallic.
                .byte $C7, $00
                .byte $04, $08, $01, $02
                .byte $20, $2C, $1B, $24
                .byte $1F, $1F, $1F, $1F
                .byte $10, $10, $0C, $0C
                .byte $00, $00, $00, $00
                .byte $2F, $2F, $2F, $2F
                .byte 0,0,0,0,0,0
                ; 6: detuned against itself -- thicker, a little sour.
                .byte $C7, $00
                .byte $11, $21, $01, $31
                .byte $1B, $1E, $1B, $1E
                .byte $1F, $1F, $1F, $1F
                .byte $0D, $0D, $0D, $0D
                .byte $00, $00, $00, $00
                .byte $1F, $1F, $1F, $1F
                .byte 0,0,0,0,0,0
                ; 7: very short, very bright -- a blip for games.
                .byte $C7, $00
                .byte $02, $04, $01, $01
                .byte $14, $18, $14, $18
                .byte $1F, $1F, $1F, $1F
                .byte $1F, $1F, $1F, $1F
                .byte $0F, $0F, $0F, $0F
                .byte $FF, $FF, $FF, $FF
                .byte 0,0,0,0,0,0

;
; Make sure FM_BANK holds something.
;
; The built-ins live in code and the working bank lives in RAM, so that
; FMLOAD can replace one without the others going anywhere.
;
FM_ENSURE       .proc
                PHP
                setaxl
                PHX

                setas
                LDA @l FM_BANKED
                BNE fe_done

                setaxl
                LDX #0
fe_copy         setas
                LDA @l fm_builtin,X
                STA @l FM_BANK,X
                setaxl
                INX
                CPX #8*FM_PATCH_SIZE
                BCC fe_copy

                setas
                LDA #1
                STA @l FM_BANKED

fe_done         setaxl
                PLX
                PLP
                RETURN
                .pend

;
; Apply the patch at FM_BANK + VID_A+6 to channel VID_A+2.
;
; VID_A+6 holds the patch base as a WORD, so VID_A+7 is its high byte
; and CANNOT also be the scratch the patch byte passes through -- the
; first operator write put a patch byte over the top half of the base
; and every index after it was garbage. $20 still got the right value,
; because that write happens before the scratch is first used, which is
; exactly the shape that makes it look like the LOOP is wrong.
FM_APPLY        .proc
                PHP
                setaxl
                PHX
                PHY

                setaxl                  ; the two the CHANNEL owns
                LDA @l VID_A+6
                TAX
                setas
                LDA @l FM_BANK,X
                STA @l AUD_T+14
                LDA @l VID_A+2
                CLC
                ADC #$20
                TAX
                LDA @l AUD_T+14
                CALL YM_POKE

                setaxl
                LDA @l VID_A+6
                INC A
                TAX
                setas
                LDA @l FM_BANK,X
                STA @l AUD_T+14
                LDA @l VID_A+2
                CLC
                ADC #$38
                TAX
                LDA @l AUD_T+14
                CALL YM_POKE

                ; Six blocks of four operators. The patch stores them
                ; block by block, which is the order the chip indexes
                ; them in: register = block*32 + $40 + operator*8 + ch.
                setas
                LDA #0
                STA @l VID_A+3          ; block, 0-5
fa_block        setas
                LDA #0
                STA @l VID_A+4          ; operator, 0-3

fa_op           setaxl                  ; patch byte 2 + block*4 + op
                LDA @l VID_A+3
                AND #$00FF
                ASL A
                ASL A
                STA @l AUD_T
                LDA @l VID_A+4
                AND #$00FF
                CLC
                ADC @l AUD_T
                CLC
                ADC #2
                CLC
                ADC @l VID_A+6
                TAX
                setas
                LDA @l FM_BANK,X
                STA @l AUD_T+14

                setaxl                  ; and where it goes
                LDA @l VID_A+3
                AND #$00FF
                .rept 5
                ASL A
                .next
                CLC
                ADC #$0040
                STA @l AUD_T
                LDA @l VID_A+4
                AND #$00FF
                .rept 3
                ASL A
                .next
                CLC
                ADC @l AUD_T
                CLC
                ADC @l VID_A+2
                AND #$00FF
                TAX

                setas
                LDA @l AUD_T+14
                CALL YM_POKE

                setas
                LDA @l VID_A+4
                INC A
                STA @l VID_A+4
                CMP #4
                BCS fa_nextblk
                BRL fa_op               ; a register write a pass puts this
                                        ;  out of branch range
fa_nextblk      setas
                LDA @l VID_A+3
                INC A
                STA @l VID_A+3
                CMP #6
                BCS fa_done
                BRL fa_block

fa_done         PLY
                PLX
                PLP
                RETURN
                .pend

;
; FMINST ch, n -- give a channel one of the instruments.
;
S_FMINST        .proc
                PHP
                TRACE "S_FMINST"
                setaxl

                CALL EVALEXPR           ; channel
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                AND #$0007
                STA @l VID_A+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; instrument
                CALL ASS_ARG1_BYTE

                setal
                LDA ARGUMENT1
                CMP #8
                BCS fi_range
                .rept 5                 ; times 32
                ASL A
                .next
                STA @l VID_A+6

                CALL FM_ENSURE
                CALL FM_APPLY

                PLP
                RETURN
fi_range        THROW ERR_RANGE
                .pend

;
; FMLOAD file$ -- replace the instrument bank from the card.
;
; The format is the one above and nothing else: patches of 32 bytes, up
; to eight, in the order FMINST numbers them. A SHORTER FILE replaces
; only as many as it holds, which is how a program changes one
; instrument without having to ship the other seven.
;
S_FMLOAD        .proc
                PHP
                TRACE "S_FMLOAD"
                setaxl
                PHX

                CALL EVALEXPR
                CALL ASS_ARG1_STR
                CALL SETFILEDESC
                CALL VIO_LOAD

                CALL FM_ENSURE          ; so the patches the file does not
                                        ;  reach keep their built-in values
                setal
                LDA @l VIO_N+2
                BNE fl_cap
                LDA @l VIO_N
                CMP #8*FM_PATCH_SIZE+1
                BCC fl_size
fl_cap          LDA #8*FM_PATCH_SIZE
fl_size         STA @l AUD_T+2
                BEQ fl_done

                setaxl
                LDX #0
fl_copy         setas
                LDA @l VIO_STAGE,X
                STA @l FM_BANK,X
                setaxl
                INX
                TXA                     ; CPX has no long addressing mode
                CMP @l AUD_T+2
                BCC fl_copy

fl_done         PLX
                PLP
                RETURN
                .pend

;;;
;;; PLAY -- the music string
;;;
;;; The classic BASIC way, and the one thing on the audio pages that a
;;; beginner can use without knowing what an operator is:
;;;
;;;     PLAY "T120 L4 O4 CDEFGAB > C"
;;;
;;;   A-G   a note. Follow it with # or + for a sharp, - for a flat, a
;;;         number for its own length, and . to make it half again as
;;;         long: "C#8." is a dotted quaver C sharp.
;;;   O n   octave 0 to 7. Octave 4 is the one with middle C in it.
;;;   > <   up an octave, down an octave.
;;;   L n   the length notes take when they do not say: 1 whole, 2 half,
;;;         4 quarter, 8 quaver, and so on. Any number works, so L3 and
;;;         L6 give triplets.
;;;   T n   tempo, quarter notes a minute. 32 to 255.
;;;   R P   a rest, with a length like a note.
;;;   space and comma are ignored, so a string can be laid out to read.
;;;
;;; IT BLOCKS, which is the classic behaviour and the honest one here: a
;;; note has to end, and the only alternative is a VSYNC handler ageing
;;; the voices, which would make PLAY the one statement that keeps
;;; running after it has returned. Ctrl-C stops it between notes.
;;;
;;; It plays on FM channel 0 with whatever instrument that channel has,
;;; so FMINIT (or FMINST 0,n) has to have happened first -- the chip
;;; powers up silent, and PLAY choosing an instrument for itself would
;;; overwrite one the program had chosen.
;;;

; A-G as semitones above C. A is 9, B is 11, C is 0.
ply_degree      .byte 9, 11, 0, 2, 4, 5, 7

;
; PLY_WHOLE := milliseconds in a whole note = 240000 / tempo.
;
; A whole note is four beats and a beat is 60000/T milliseconds, so the
; four cancels into the constant.
;
PLY_WHOLECALC   .proc
                PHP
                setaxl

                LDA #$A980              ; 240000, the whole-note constant
                STA ARGUMENT1
                LDA #$0003
                STA ARGUMENT1+2
                LDA @l PLY_TEMPO
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2

                CALL UDIV32

                LDA ARGUMENT1
                STA @l PLY_WHOLE
                LDA ARGUMENT1+2
                STA @l PLY_WHOLE+2

                PLP
                RETURN
                .pend

;
; PLY_MS := PLY_WHOLE / the length in PLY_NOTE.
;
PLY_LENMS       .proc
                PHP
                setaxl

                LDA @l PLY_WHOLE
                STA ARGUMENT1
                LDA @l PLY_WHOLE+2
                STA ARGUMENT1+2
                LDA @l PLY_NOTE
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2

                CALL UDIV32

                LDA ARGUMENT1
                STA @l PLY_MS
                LDA ARGUMENT1+2
                STA @l PLY_MS+2

                PLP
                RETURN
                .pend

;
; Wait PLY_MS milliseconds, or until Ctrl-C.
;
; The hardware millisecond counter, so the wait is the same at 8 MHz and
; 14 MHz -- the same reason WAIT uses it rather than counting loops.
;
PLY_DELAY       .proc
                PHP
                setaxl
                PHX

                JSL KERN_TIME_GET       ; C = low 16, X = high 16
                CLC
                ADC @l PLY_MS
                STA @l WAIT_T
                TXA
                ADC @l PLY_MS+2
                STA @l WAIT_T+2

pd_loop         CALL ENV_POLL           ; PLAY blocks for a whole note, and a
                                        ;  PSG envelope running underneath it
                                        ;  must not stop for that long
                JSL FK_TESTBREAK
                BCS pd_break

                JSL KERN_TIME_GET
                STA @l WAIT_N
                TXA
                STA @l WAIT_N+2

                SEC                     ; now - target: a borrow means the
                LDA @l WAIT_N           ;  target is still ahead
                SBC @l WAIT_T
                LDA @l WAIT_N+2
                SBC @l WAIT_T+2
                BCC pd_loop

                PLX
                PLP
                RETURN

pd_break        CALL PLY_KEYOFF         ; do not leave a note sounding
                PLX
                PLP
                THROW ERR_BREAK
                .pend

;
; Key the note in PLY_NOTE on, and off again.
;
PLY_KEYON       .proc
                PHP
                setaxl
                PHX

                LDA @l PLY_NOTE         ; octave and degree
                AND #$00FF
                LDX #0
pk_oct          CMP #12
                BCC pk_have
                SEC
                SBC #12
                INX
                CPX #8
                BCC pk_oct
                DEX                     ; clamp rather than wrap
                CLC
                ADC #12

pk_have         PHX                     ; A = degree
                TAX
                setas
                LDA @l YM_KEYCODE,X
                STA @l VID_A+5
                setal
                PLA                     ; the octave back
                .rept 4
                ASL A
                .next
                setas
                ORA @l VID_A+5
                STA @l VID_A+5

                setas                   ; key off first, or a note already
                LDX #$08                ;  sounding will not retrigger
                LDA @l PLY_CH
                CALL YM_POKE

                setas
                LDA @l PLY_CH
                CLC
                ADC #$28
                TAX
                LDA @l VID_A+5
                CALL YM_POKE

                setas
                LDA @l PLY_CH
                CLC
                ADC #$30
                TAX
                LDA #$00
                CALL YM_POKE

                setas
                LDX #$08
                LDA @l PLY_CH
                ORA #$78                ; all four operators
                CALL YM_POKE

                PLX
                PLP
                RETURN
                .pend

PLY_KEYOFF      .proc
                PHP
                setaxl
                PHX
                setas
                LDX #$08
                LDA @l PLY_CH
                AND #$07
                CALL YM_POKE
                PLX
                PLP
                RETURN
                .pend

;
; A = the next character, uppercased, or 0 at the end of the string.
; Does not consume it.
;
PLY_PEEK        .proc
                PHP
                setas
                LDA [MTEMP]
                BEQ pp_done
                CMP #'a'
                BCC pp_done
                CMP #'z'+1
                BCS pp_done
                SEC
                SBC #$20                ; to upper case
pp_done         PLP
                RETURN
                .pend

;
; Step over one character.
;
PLY_STEP        .proc
                PHP
                setal
                INC MTEMP
                BNE ps_done
                INC MTEMP+2
ps_done         PLP
                RETURN
                .pend

;
; Read a decimal number into PLY_NOTE. Carry set if there was one.
;
PLY_NUM         .proc
                PHP
                setaxl

                LDA #0
                STA @l PLY_NOTE
                setas
                LDA #0
                STA @l AUD_T+4          ; did we see a digit?

pn_loop         CALL PLY_PEEK
                CMP #'0'
                BCC pn_done
                CMP #'9'+1
                BCS pn_done

                SEC
                SBC #'0'
                STA @l AUD_T+5

                setaxl                  ; n = n*10 + digit
                LDA @l PLY_NOTE
                ASL A
                STA @l AUD_T+6
                ASL A
                ASL A
                CLC
                ADC @l AUD_T+6
                CLC
                ADC @l AUD_T+5
                AND #$00FF              ; nothing here needs more than a byte
                STA @l PLY_NOTE

                setas
                LDA #1
                STA @l AUD_T+4
                CALL PLY_STEP
                BRA pn_loop

pn_done         setas
                LDA @l AUD_T+4
                LSR A                   ; bit 0 into the carry
                PLP
                RETURN
                .pend

;
; PLAY s$ -- the music string.
;
S_PLAY          .proc
                PHP
                TRACE "S_PLAY"
                setaxl
                PHX

                CALL EVALEXPR
                CALL ASS_ARG1_STR

                setal                   ; MTEMP is the cursor: [ptr] lives
                LDA ARGUMENT1           ;  in the direct page and a string
                STA MTEMP               ;  can be in any bank. Safe here --
                LDA ARGUMENT1+2         ;  nothing PLAY calls streams
                STA MTEMP+2             ;  through it.

                setas                   ; the defaults, as every BASIC has
                LDA #4                  ;  had them
                STA @l PLY_OCT
                LDA #4
                STA @l PLY_LEN
                LDA #0
                STA @l PLY_CH
                setal
                LDA #120
                STA @l PLY_TEMPO
                CALL PLY_WHOLECALC

pl_loop         CALL PLY_PEEK
                setas
                CMP #0
                BNE pl_char
                JMP pl_done

pl_char         CMP #' '                ; layout, ignored
                BEQ pl_skip
                CMP #','
                BEQ pl_skip

                CMP #'>'
                BEQ pl_up
                CMP #'<'
                BEQ pl_down
                CMP #'O'
                BEQ pl_octave
                CMP #'L'
                BEQ pl_length
                CMP #'T'
                BNE pl_c1
                JMP pl_tempo
pl_c1           CMP #'R'
                BNE pl_c2
                JMP pl_rest
pl_c2           CMP #'P'
                BNE pl_c3
                JMP pl_rest

pl_c3           CMP #'A'
                BCC pl_tobad
                CMP #'G'+1
                BCS pl_tobad
                JMP pl_note

pl_skip         CALL PLY_STEP
                JMP pl_loop           ; the parser is wider than a branch

                ; The command handlers below are further from the error
                ; exit than a relative branch reaches, so it gets a
                ; trampoline. Nothing falls into it: the BRA above is
                ; unconditional.
pl_tobad        JMP pl_bad

pl_up           CALL PLY_STEP
                setas
                LDA @l PLY_OCT
                CMP #7
                BCS pl_loop2
                INC A
                STA @l PLY_OCT
pl_loop2        JMP pl_loop           ; the parser is wider than a branch

pl_down         CALL PLY_STEP
                setas
                LDA @l PLY_OCT
                BEQ pl_loop2
                DEC A
                STA @l PLY_OCT
                JMP pl_loop           ; the parser is wider than a branch

                ; ... and a second trampoline for the handlers,
                ; which are the far side of the first one.
pl_tobad2       JMP pl_bad

pl_octave       CALL PLY_STEP
                CALL PLY_NUM
                BCC pl_tobad2
                setas
                LDA @l PLY_NOTE
                CMP #8
                BCS pl_bad
                STA @l PLY_OCT
                JMP pl_loop           ; the parser is wider than a branch

pl_length       CALL PLY_STEP
                CALL PLY_NUM
                BCC pl_tobad2
                setas
                LDA @l PLY_NOTE
                BEQ pl_tobad2
                STA @l PLY_LEN
                JMP pl_loop           ; the parser is wider than a branch

pl_tempo        CALL PLY_STEP
                CALL PLY_NUM
                BCC pl_tobad2
                setal
                LDA @l PLY_NOTE
                CMP #32
                BCC pl_tobad2
                STA @l PLY_TEMPO
                CALL PLY_WHOLECALC
                JMP pl_loop           ; the parser is wider than a branch

pl_bad          THROW ERR_ARGUMENT

                ; ---- a rest ----
pl_rest         CALL PLY_STEP
                CALL PLY_NUM            ; its own length, or the default
                BCS pl_restlen
                setas
                LDA @l PLY_LEN
                setal
                AND #$00FF
                STA @l PLY_NOTE
pl_restlen      CALL PLY_LENMS
                CALL PLY_DOT
                CALL PLY_DELAY
                JMP pl_loop

                ; ---- a note ----
pl_note         setas
                SEC
                SBC #'A'
                setaxl
                AND #$00FF
                TAX
                setas
                LDA @l ply_degree,X
                STA @l AUD_T+8         ; the degree, before accidentals
                CALL PLY_STEP

                CALL PLY_PEEK           ; sharp or flat
                CMP #'#'
                BEQ pl_sharp
                CMP #'+'
                BEQ pl_sharp
                CMP #'-'
                BEQ pl_flat
                BRA pl_nolen

pl_sharp        CALL PLY_STEP
                setas
                LDA @l AUD_T+8
                INC A
                STA @l AUD_T+8
                BRA pl_nolen

pl_flat         CALL PLY_STEP
                setas
                LDA @l AUD_T+8
                DEC A
                STA @l AUD_T+8

pl_nolen        CALL PLY_NUM            ; its own length, or the default
                BCS pl_havelen
                setas
                LDA @l PLY_LEN
                setal
                AND #$00FF
                STA @l PLY_NOTE
pl_havelen      CALL PLY_LENMS
                CALL PLY_DOT

                setaxl                  ; note = octave*12 + degree, and
                LDA @l PLY_OCT          ;  12 is 8 + 4
                AND #$00FF
                ASL A
                ASL A                   ; o*4
                STA @l AUD_T+10
                ASL A                   ; o*8
                CLC
                ADC @l AUD_T+10         ; o*12
                STA @l AUD_T+10
                LDA @l AUD_T+8
                AND #$00FF
                CMP #$0080              ; a flatted C went below zero
                BCC pl_addoct
                LDA #0
pl_addoct       CLC
                ADC @l AUD_T+10
                CMP #96                 ; eight octaves is all the chip has
                BCC pl_setnote
                LDA #95
pl_setnote      STA @l PLY_NOTE

                CALL PLY_KEYON
                CALL PLY_DELAY
                CALL PLY_KEYOFF
                JMP pl_loop

pl_done         PLX
                PLP
                RETURN
                .pend

;
; A trailing "." makes the note half again as long.
;
PLY_DOT         .proc
                PHP
                setaxl

                CALL PLY_PEEK
                CMP #'.'
                BNE pd_none
                CALL PLY_STEP

                setal                   ; ms += ms/2
                LDA @l PLY_MS+2
                LSR A
                STA @l AUD_T+12
                LDA @l PLY_MS
                ROR A
                CLC
                ADC @l PLY_MS
                STA @l PLY_MS
                LDA @l AUD_T+12
                ADC @l PLY_MS+2
                STA @l PLY_MS+2

pd_none         PLP
                RETURN
                .pend

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

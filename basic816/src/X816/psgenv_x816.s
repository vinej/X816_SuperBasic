;;;
;;; ENV / ENVOFF -- volume envelopes over the PSG voices
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; SOUND turns a voice on and leaves it on. That is the whole of what
;;; the PSG offers -- a frequency and a volume, both of which sit there
;;; until something writes them again -- and it is why every note out of
;;; this machine starts and stops like a switch. An envelope is the
;;; difference between a switch and an instrument: the volume moves,
;;; once a frame, and a note can fade instead of stopping dead.
;;;
;;;     ENV v,a,d,s,r       arm voice v
;;;     SOUND v,hz,vol      vol is now the PEAK, and the note starts at 0
;;;     ENVOFF v            let go: fall to silence over r frames
;;;
;;; a, d and r are TIMES IN FRAMES, not levels: the number of frames a
;;; full 0-to-63 sweep would take, so a shorter sweep takes
;;; proportionally less. s is a LEVEL, 0-63, the one the note holds at
;;; until it is let go. 0 for a time means instant, and an instant one
;;; happens inside the statement that asks for it rather than at the
;;; next frame -- ENV 0,0,0,63,0 behaves exactly like plain SOUND, which
;;; is the property that makes the degenerate case testable.
;;;
;;; WHERE THE TICK COMES FROM, and where it deliberately does not.
;;;
;;; Not from KIRQ_VSYNC. That slot is the kernel's blinking cursor and
;;; installing anything there takes it off the cursor -- and worse, the
;;; next K_CON_CURSOR call takes the slot straight back and unhooks us
;;; with nothing said. The same reasoning is in the header of
;;; X816/irq_x816.s and it applies here unchanged.
;;;
;;; It comes from ENV_POLL, which asks the kernel how many frames have
;;; gone by since the last one and steps the levels that many times. It
;;; is called from IRQ_POLL, at the statement boundary, and from the
;;; three places a statement can BLOCK for longer than a frame: WAIT,
;;; VSYNC and PLAY's note delay. Without those three the commonest
;;; program of all --
;;;
;;;     SOUND 0,440,63 : ENVOFF 0 : WAIT 1000
;;;
;;; -- would hold its release for the whole second and then collapse it
;;; in one step, which is the sound of the feature not working.
;;;
;;; Nothing here runs in interrupt context, so there is no width and no
;;; re-entrancy problem to have: this is ordinary code reached from the
;;; interpreter, exactly like SOUND itself.
;;;
;;; CATCHING UP, and its limit. A program executing fewer than sixty
;;; statements a second would otherwise stretch every envelope to match
;;; its own speed, which makes "sixty frames" mean nothing. So the poll
;;; applies as many steps as frames have passed -- but AT MOST EIGHT.
;;; The cap is what stops WAIT 10000 from walking six hundred frames of
;;; sixteen voices in one go; past it an envelope finishes late rather
;;; than the machine appearing to hang.
;;;
;;; THE STATE, sixteen bytes a voice, indexed by voice*16 so the index
;;; is four shifts:
;;;
;;;   +0    phase   0 off, 1 attack, 2 decay, 3 sustain, 4 release
;;;   +1    peak    0-63, what SOUND asked for
;;;   +2,+3 level   the live level, 8.8 fixed point
;;;   +4,+5 astep   how far the level moves in a frame, 8.8
;;;   +6,+7 dstep
;;;   +8,+9 rstep
;;;   +10   sus     the sustain level, 0-63
;;;   +11   armed   non-zero if ENV has been used on this voice
;;;   +12   chan    the two channel bits that sit above the volume
;;;   +13   dtgt    where the decay stops: min(sus, peak)
;;;
;;; The level is 8.8 rather than a plain 0-63 because the step has to be
;;; fractional: a four-second fade is 240 frames over 63 levels, which
;;; is a quarter of a level a frame, and an integer step can only be 0
;;; (never arrives) or 1 (arrives in one second).
;;;

;
; Full scale, 63.0, in the 8.8 the level is kept in. A rate argument is
; the number of frames THIS sweep would take, so the step is this over
; the argument.
;
ENV_FULL        = 63 * 256

;
; Clear every voice. Called from IRQ_DISARM, which is CLRINTERP, which
; is RUN, NEW, LOAD -- and INITBASIC, which is what zeroes the table at
; boot: nothing else does, and an envelope made of powered-up RAM would
; start walking voices the moment anything armed one.
;
; It does NOT silence the PSG. RUN has never stopped a note that was
; already sounding and this is not the change that should start; a voice
; caught mid-envelope simply stays where it was, exactly as a voice set
; by plain SOUND does.
;
ENV_CLEAR       .proc
                PHP
                setaxl
                PHX

                LDX #0
ec_loop         setas
                LDA #0
                STA @l ENV_TAB,X
                setaxl
                INX
                CPX #16*16
                BCC ec_loop

                setas
                LDA #0
                STA @l ENV_ANY

                setaxl
                PLX
                PLP
                RETURN
                .pend

;
; Recompute ENV_ANY: is any voice armed at all?
;
; IRQ_POLL's fast path is one 16-bit read of IRQ_STATE, and IRQ_REARM
; folds this byte into it -- so an armed envelope costs a running
; program exactly what an armed ONVSYNC costs, and an unarmed one costs
; nothing.
;
ENV_RESCAN      .proc
                PHP
                setaxl
                PHX

                setas
                LDA #0
                STA @l ENV_ANY

                setaxl
                LDX #11                 ; the "armed" byte of voice 0
er_loop         setas
                LDA @l ENV_TAB,X
                BEQ er_next
                LDA #1
                STA @l ENV_ANY
                BRA er_done

er_next         setaxl
                TXA
                CLC
                ADC #16
                TAX
                CPX #16*16
                BCC er_loop

er_done         setaxl
                PLX
                PLP
                RETURN
                .pend

;
; A rate argument to a step.
;
; Inputs:
;   A = the time in frames, 0-255
; Outputs:
;   A = how far the level moves in one frame, 8.8
;
; 0 means instant and answers $FFFF, which overshoots any target in one
; step and is then clamped to it -- so "instant" needs no special case
; anywhere below. The floor of 1 cannot be reached from a legal argument
; (16128/255 is 63) and is there because a step of zero would leave the
; phase walking on the spot forever.
;
ENV_RATE        .proc
                PHP
                setaxl

                CMP #0
                BEQ er_instant

                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2
                LDA #ENV_FULL
                STA ARGUMENT1
                LDA #0
                STA ARGUMENT1+2
                CALL UDIV32

                setaxl
                LDA ARGUMENT1
                BNE er_done
                LDA #1
er_done         PLP
                RETURN

er_instant      LDA #$FFFF
                PLP
                RETURN
                .pend

;
; Advance one voice by one frame and write its PSG volume byte.
;
; Inputs:
;   ENV_P = the voice's offset into ENV_TAB, which is voice*16
;
; Also called directly by SOUND and ENVOFF, so that a zero-frame attack
; or release is heard in the statement that asked for it.
;
; A voice in SUSTAIN returns without writing anything: its level is not
; moving, and writing the same byte sixteen times a second to say so is
; the sort of cost that only shows up as "why is this program slow".
;
ENV_STEPV       .proc
                PHP
                setaxl
                PHX

                LDA @l ENV_P
                TAX

                ; The four arms are each longer than a relative branch
                ; reaches, so the dispatch goes the long way round.
                setas
                LDA @l ENV_TAB,X            ; the phase
                BNE sv_live
                BRL sv_out                  ; off
sv_live         CMP #3
                BNE sv_moving
                BRL sv_out                  ; sustain: nothing moves
sv_moving       CMP #1
                BNE sv_notatk
                BRL sv_attack
sv_notatk       CMP #2
                BNE sv_notdec
                BRL sv_decay
sv_notdec

                ; ---- release: down to silence, then off ----
                setal
                LDA @l ENV_TAB+2,X
                SEC
                SBC @l ENV_TAB+8,X
                BCC sv_silent               ; borrowed: past zero
                CMP #$0100                  ; below one whole level there is
                BCC sv_silent               ;  nothing left to hear, and a
                                            ;  fractional tail would take
                                            ;  another two hundred frames
                STA @l ENV_TAB+2,X
                BRA sv_write

sv_silent       LDA #0
                STA @l ENV_TAB+2,X
                setas
                LDA #0
                STA @l ENV_TAB,X            ; off
                BRA sv_write

                ; ---- attack: up to the peak, then decay ----
sv_attack       setal
                LDA @l ENV_TAB+1,X          ; the peak, with the low half of
                AND #$00FF                  ;  the level beside it masked off
                XBA                         ; peak << 8: the target
                STA @l ENV_TGT

                LDA @l ENV_TAB+2,X
                CLC
                ADC @l ENV_TAB+4,X
                BCS sv_peak                 ; past $FFFF: at the top for sure
                CMP @l ENV_TGT
                BCC sv_astore
sv_peak         LDA @l ENV_TGT
                STA @l ENV_TAB+2,X
                setas
                LDA #2                      ; on to the decay
                STA @l ENV_TAB,X
                BRA sv_write
sv_astore       STA @l ENV_TAB+2,X
                BRA sv_write

                ; ---- decay: down to the sustain level, and hold ----
sv_decay        setal
                LDA @l ENV_TAB+13,X         ; the decay target
                AND #$00FF
                XBA
                STA @l ENV_TGT

                LDA @l ENV_TAB+2,X
                SEC
                SBC @l ENV_TAB+6,X
                BCC sv_sustain              ; borrowed: below it for sure
                CMP @l ENV_TGT
                BCC sv_sustain
                STA @l ENV_TAB+2,X
                BRA sv_write
sv_sustain      LDA @l ENV_TGT
                STA @l ENV_TAB+2,X
                setas
                LDA #3                      ; hold here until ENVOFF
                STA @l ENV_TAB,X

                ; ---- the volume byte: the level's whole part, under the
                ;      two channel bits ----
                ;
                ; The bits are remembered rather than read back. The PSG
                ; is VRAM and VRAM does read back, but the palette taught
                ; this port that what comes back is not always what a
                ; program believes it wrote (HELP PAL), and a wrong pair
                ; of bits here is a voice that goes silent rather than a
                ; colour that looks odd.
sv_write        setal
                LDA @l ENV_TAB+2,X
                XBA
                AND #$00FF
                STA @l ENV_TMP
                LDA @l ENV_TAB+12,X         ; the channel bits
                AND #$00FF
                ORA @l ENV_TMP
                STA @l ENV_TMP

                LDA @l ENV_P                ; voice*16 back to voice*4, and
                LSR A                       ;  the volume byte is the third
                LSR A                       ;  of the four
                CLC
                ADC #(<>VERA_PSG) + 2
                STA @l ENV_TGT

                setas
                LDA #0
                STA @l VERA_CTRL            ; data port 0, DCSEL 0
                LDA @l ENV_TGT
                STA @l VERA_ADDR_L
                LDA @l ENV_TGT+1
                STA @l VERA_ADDR_M
                LDA #$01                    ; bit 16 set, auto-increment 0
                STA @l VERA_ADDR_H
                LDA @l ENV_TMP
                STA @l VERA_DATA0

sv_out          setaxl
                PLX
                PLP
                RETURN
                .pend

;
; One frame, across all sixteen voices.
;
ENV_TICK        .proc
                PHP
                setaxl

                LDA #0
                STA @l ENV_P
et_loop         CALL ENV_STEPV
                setaxl
                LDA @l ENV_P
                CLC
                ADC #16
                STA @l ENV_P
                CMP #16*16
                BCC et_loop

                PLP
                RETURN
                .pend

;
; The tick. Cheap when nothing is armed, which is every program that
; never says ENV.
;
; Called from IRQ_POLL at the statement boundary, and from the loops of
; WAIT, VSYNC and PLAY -- see the header for why those three are not
; optional.
;
ENV_POLL        .proc
                PHP
                setaxl

                setas
                LDA @l ENV_ANY
                BEQ ep_out

                setaxl
                JSL KERN_IRQ_FRAMES         ; C = frames, 16-bit, wraps
                STA @l ENV_NOW
                SEC
                SBC @l ENV_FRAME            ; how many since the last tick.
                BEQ ep_out                  ;  Unsigned, so the wrap comes
                                            ;  out right on its own.
                CMP #9
                BCC ep_have
                LDA #8                      ; the catch-up cap: see the header
ep_have         STA @l ENV_N
                LDA @l ENV_NOW
                STA @l ENV_FRAME

ep_frame        CALL ENV_TICK
                setaxl
                LDA @l ENV_N
                DEC A
                STA @l ENV_N
                BNE ep_frame

ep_out          PLP
                RETURN
                .pend

;
; ENV voice,attack,decay,sustain,release
;
; attack, decay and release are frames for a full sweep; sustain is a
; level, 0-63. All four zero DISARMS the voice: an envelope that rises
; instantly to a sustain of nothing and falls instantly from it is
; silence, so it can never be what somebody meant, and spending a token
; on ENVCLR to say the same thing would be spending one of the forty
; that are left.
;
; Arming does not disturb a voice that is already sounding, and
; re-arming one mid-note keeps its phase and level and changes only the
; rates -- which is how a program bends an envelope while it plays.
;
S_ENV           .proc
                PHP
                TRACE "S_ENV"
                setaxl

                CALL EVALEXPR               ; the voice, 0-15
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                CMP #16
                BCC ev_okvoice              ; five expressions stand between
                JMP ev_range                ;  here and the error exit, which
ev_okvoice                                  ;  is further than a branch reaches
                .rept 4
                ASL A
                .next
                STA @l ENV_V                ; the record offset, voice*16.
                                            ;  ENV_V and not ENV_P: the frame
                                            ;  tick uses ENV_P as its loop
                                            ;  counter, and this has to
                                            ;  survive four more expressions

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; attack, in frames
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                STA @l ENV_A

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; decay
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                STA @l ENV_D

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; sustain, a LEVEL not a time
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                CMP #64
                BCC ev_oksus
                JMP ev_range
ev_oksus        STA @l ENV_S

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; release
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                STA @l ENV_R

                ; ---- all four zero: forget this voice ----
                setaxl
                LDA @l ENV_A
                ORA @l ENV_D
                ORA @l ENV_S
                ORA @l ENV_R
                BNE ev_arm

                LDA @l ENV_V
                TAX
                LDA #0
                STA @l ENV_TAB,X            ; phase and peak
                STA @l ENV_TAB+2,X          ; the level
                setas
                LDA #0
                STA @l ENV_TAB+11,X         ; and it is no longer armed
                BRA ev_done

                ; ---- the rates, computed once, here ----
ev_arm          setaxl
                LDA @l ENV_A
                CALL ENV_RATE
                setaxl
                STA @l ENV_TMP
                LDA @l ENV_V
                TAX
                LDA @l ENV_TMP
                STA @l ENV_TAB+4,X

                LDA @l ENV_D
                CALL ENV_RATE
                setaxl
                STA @l ENV_TMP
                LDA @l ENV_V
                TAX
                LDA @l ENV_TMP
                STA @l ENV_TAB+6,X

                LDA @l ENV_R
                CALL ENV_RATE
                setaxl
                STA @l ENV_TMP
                LDA @l ENV_V
                TAX
                LDA @l ENV_TMP
                STA @l ENV_TAB+8,X

                setas
                LDA @l ENV_S
                STA @l ENV_TAB+10,X
                LDA #1
                STA @l ENV_TAB+11,X         ; armed
                LDA @l ENV_TAB+12,X         ; the channel bits, if SOUND has
                BNE ev_havechan             ;  not set them yet
                LDA #$C0
                STA @l ENV_TAB+12,X
ev_havechan
                ; A voice re-armed in mid-note keeps its phase, so its
                ; decay target has to be recomputed against the peak it
                ; is already climbing to.
                LDA @l ENV_S
                CMP @l ENV_TAB+1,X          ; the peak
                BCC ev_dtgt
                LDA @l ENV_TAB+1,X          ; the decay never goes UP
ev_dtgt         STA @l ENV_TAB+13,X

ev_done         CALL ENV_RESCAN
                CALL IRQ_REARM              ; the fast path has to know

                setaxl                      ; arm from the CURRENT frame, so
                JSL KERN_IRQ_FRAMES         ;  the first step is one frame
                STA @l ENV_FRAME            ;  from now and not a catch-up
                                            ;  burst from whenever the last
                                            ;  envelope ran
                PLP
                RETURN

ev_range        THROW ERR_RANGE
                .pend

;
; ENVOFF voice -- let go of a note: fall to silence over its release.
;
; This is the statement the whole page is for. SOUND v,0,0 still stops a
; voice DEAD and still means exactly what it always meant; this is the
; other one, and a program can use both on the same voice.
;
; A voice that is off, already releasing, or was never given an envelope
; is left alone rather than made an error: ENVOFF in a loop that has
; already finished is normal, and a program should not have to guard it.
;
S_ENVOFF        .proc
                PHP
                TRACE "S_ENVOFF"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                setal
                LDA ARGUMENT1
                CMP #16
                BCS eo_range
                .rept 4
                ASL A
                .next
                STA @l ENV_P
                TAX

                setas
                LDA @l ENV_TAB+11,X         ; armed?
                BEQ eo_done
                LDA @l ENV_TAB,X            ; and sounding?
                BEQ eo_done
                CMP #4
                BEQ eo_done                 ; already on its way down

                LDA #4                      ; release
                STA @l ENV_TAB,X
                CALL ENV_STEPV              ; so a release of 0 frames is
                                            ;  silent NOW, not next frame
eo_done         PLP
                RETURN

eo_range        THROW ERR_RANGE
                .pend

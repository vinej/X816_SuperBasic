;;;
;;; ADPCMPLAY -- IMA ADPCM, decoded up front and played through the FIFO
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; Four bits a sample instead of sixteen, so a file is a quarter the
;;; size -- and the size is what limits sound on this machine, because
;;; PCMPLAY reads a whole sample into memory before it plays a byte of
;;; it (HELP AUDIOPCM). The space is the smaller half of it: a card read
;;; is slow, and a quarter as many bytes is a quarter of the wait before
;;; the sound starts.
;;;
;;; IT IS A DECODER AND NOTHING ELSE. The compressed file is loaded to
;;; the staging buffer, decoded into memory, and the result is handed to
;;; the AFLOW feeder PCMPLAY already has. Nothing interpreted can feed a
;;; DAC live and nothing here tries: the whole file is decoded before a
;;; sample is played, which costs a second or two on a big one and is
;;; the statement blocking, not the machine hanging.
;;;
;;; THE FORMAT. A nibble a sample, low nibble of a byte first:
;;;
;;;     step = step_table[index]
;;;     diff = step/8 + (n&4 ? step : 0) + (n&2 ? step/2 : 0)
;;;                   + (n&1 ? step/4 : 0)
;;;     predictor += (n&8) ? -diff : +diff,  clamped to 16 bits
;;;     index += index_table[n],             clamped to 0..88
;;;
;;; Two tables, 89 entries and 16, and the loop above. That is the whole
;;; of IMA ADPCM; there is no entropy coding and no lookahead.
;;;
;;; WHY IT READS WAV FILES. Every tool that produces IMA ADPCM produces
;;; a WAV, and this BASIC has no way to strip a header off one -- so a
;;; decoder that took only a raw stream would be a decoder nobody could
;;; feed. More than convenience, though: an IMA WAV RESTARTS the
;;; predictor at every block, with the starting value in a four-byte
;;; block header, and a decoder that ignored that would drift into noise
;;; a fraction of a second in. The block size is in the header and
;;; nowhere else, so reading the header is what makes the decode
;;; CORRECT, not merely convenient.
;;;
;;; A file that is not RIFF is decoded as one continuous raw stream from
;;; a predictor of 0 and an index of 0, which is the convention for a
;;; headerless IMA stream.
;;;
;;; WHERE THE DECODED AUDIO GOES -- the one open question on the help
;;; page. It goes to a fixed buffer at $0A:0000, the 384 KB between the
;;; staging buffer's 128 KB and $10:0000, which is the EXEC staging area
;;; and belongs to whatever `run` happens next (PORT.md 3). That caps
;;; the compressed file at 96 KB, and it is checked before anything is
;;; decoded rather than found out by overrunning into it.
;;;
;;; The alternative was K_MEM_ALLOC out of the arena at $20:0100. It
;;; would be tidier and it was not taken: the kernel allows 32 blocks
;;; and nothing here would ever free one, so a program that played ten
;;; sounds would run out of BLOCKS with megabytes free -- a failure
;;; whose message would say nothing about sound.
;;;

;
; The decoded buffer, and what fits in it.
;
ADP_OUT         = $0A0000
ADP_OUTMAX      = $060000       ; $0A:0000 through $0F:FFFF
ADP_INMAX       = ADP_OUTMAX / 4

;
; The step table: 89 entries, each about 1.1 times the one before it, so
; the last is 32767 and the first is 7. It is a table and not a formula
; because the standard is the table -- a decoder that computed close
; enough would drift against the encoder that made the file.
;
adp_steptab     .word 7, 8, 9, 10, 11, 12, 13, 14, 16, 17
                .word 19, 21, 23, 25, 28, 31, 34, 37, 41, 45
                .word 50, 55, 60, 66, 73, 80, 88, 97, 107, 118
                .word 130, 143, 157, 173, 190, 209, 230, 253, 279, 307
                .word 337, 371, 408, 449, 494, 544, 598, 658, 724, 796
                .word 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066
                .word 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358
                .word 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899
                .word 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767

;
; How the index moves. The low three bits are the magnitude, so a small
; one steps DOWN the table and a large one jumps up: the step size
; chases the signal. Bit 3 is the sign and does not affect the index,
; which is why the sixteen entries are eight repeated twice.
;
adp_idxtab      .char -1, -1, -1, -1, 2, 4, 6, 8
                .char -1, -1, -1, -1, 2, 4, 6, 8

;
; Decode one nibble, in the low four bits of ADP_NIB, into ADP_PRED.
;
; The predictor is kept in ADP_PRED as a signed 16-bit value and the
; add is done in 32 BITS, because diff reaches 1.875 * 32767 -- close to
; 61438, which fits a 16-bit word but not a signed one, and the sum can
; land either side of the range. Doing it narrow and clamping on the
; carry gets the common case right and the loud case wrong, which is
; the sort of bug that sounds like a bad sample.
;
ADP_STEPNIB     .proc
                PHP
                setaxl
                PHX

                LDA @l ADP_IDX              ; step = step_table[index]
                ASL A
                TAX
                LDA @l adp_steptab,X
                STA @l ADP_STEP

                LSR A                       ; diff = step/8
                LSR A
                LSR A
                STA @l ADP_DIFF

                LDA @l ADP_NIB
                AND #4
                BEQ sn_no4
                LDA @l ADP_DIFF
                CLC
                ADC @l ADP_STEP
                STA @l ADP_DIFF
sn_no4          LDA @l ADP_NIB
                AND #2
                BEQ sn_no2
                LDA @l ADP_STEP
                LSR A
                CLC
                ADC @l ADP_DIFF
                STA @l ADP_DIFF
sn_no2          LDA @l ADP_NIB
                AND #1
                BEQ sn_no1
                LDA @l ADP_STEP
                LSR A
                LSR A
                CLC
                ADC @l ADP_DIFF
                STA @l ADP_DIFF
sn_no1
                ; ---- predictor +/- diff, in 32 bits ----
                LDA @l ADP_PRED             ; sign-extend the predictor into
                STA @l ADP_T                ;  a 32-bit accumulator
                BMI sn_wasneg
                LDA #0
                BRA sn_pos
sn_wasneg       LDA #$FFFF
sn_pos          STA @l ADP_T+2

                LDA @l ADP_NIB
                AND #8
                BNE sn_down

                LDA @l ADP_T                ; up
                CLC
                ADC @l ADP_DIFF
                STA @l ADP_T
                LDA @l ADP_T+2
                ADC #0
                STA @l ADP_T+2
                BRA sn_clamp

sn_down         LDA @l ADP_T
                SEC
                SBC @l ADP_DIFF
                STA @l ADP_T
                LDA @l ADP_T+2
                SBC #0
                STA @l ADP_T+2

                ; In range when the high word is the low word's sign
                ; extension, and nothing else. Two tests, and the order
                ; matters: $0000/$8000 is +32768 and must clamp DOWN.
sn_clamp        LDA @l ADP_T+2
                BNE sn_neg                  ; not 0: either negative or over
                LDA @l ADP_T
                BMI sn_hi                   ; 0/$8000 and up: past +32767
                BRA sn_store
sn_neg          CMP #$FFFF
                BNE sn_lo                   ; anything but $FFFF is way past
                LDA @l ADP_T
                BPL sn_lo                   ; $FFFF/$7FFF and down: past -32768
                BRA sn_store
sn_hi           LDA #$7FFF
                BRA sn_store2
sn_lo           LDA #$8000
                BRA sn_store2
sn_store        LDA @l ADP_T
sn_store2       STA @l ADP_PRED

                ; ---- index += index_table[nibble], clamped ----
                LDA @l ADP_NIB
                AND #$000F
                TAX
                setas
                LDA @l adp_idxtab,X
                setal
                AND #$00FF                  ; a signed byte, widened by hand
                CMP #$0080
                BCC sn_idxpos
                ORA #$FF00
sn_idxpos       CLC
                ADC @l ADP_IDX
                BPL sn_idxhi
                LDA #0                      ; went below the bottom
                BRA sn_idxput
sn_idxhi        CMP #89
                BCC sn_idxput
                LDA #88
sn_idxput       STA @l ADP_IDX

                PLX
                PLP
                RETURN
                .pend

;
; Write ADP_PRED to the output and step past it.
;
ADP_EMIT        .proc
                PHP
                setal

                LDA @l ADP_PRED
                STA [PCM_PTR]               ; 16-bit, so two bytes go out

                LDA PCM_PTR
                CLC
                ADC #2
                STA PCM_PTR
                BCC ae_count                ; the bank only moves when the
                INC PCM_PTR+2               ;  low word wraps

ae_count        LDA @l ADP_OUTN
                CLC
                ADC #2
                STA @l ADP_OUTN
                BCC ae_done
                LDA @l ADP_OUTN+2           ; INC has no long addressing mode
                INC A
                STA @l ADP_OUTN+2

ae_done         PLP
                RETURN
                .pend

;
; Step the input cursor one byte on and count it down.
;
ADP_INSTEP      .proc
                PHP
                setal

                INC MTEMP
                BNE ai_count
                INC MTEMP+2

ai_count        LDA @l ADP_IN
                BNE ai_low
                LDA @l ADP_IN+2
                DEC A
                STA @l ADP_IN+2
                LDA #$FFFF
                STA @l ADP_IN
                BRA ai_done
ai_low          DEC A
                STA @l ADP_IN

ai_done         PLP
                RETURN
                .pend

;
; The decode. MTEMP is the input cursor and PCM_PTR the output one; both
; are direct-page because [ptr] addressing exists nowhere else, and both
; are borrowed rather than new: MTEMP is the staging cursor VIO_LOAD has
; already finished with, and PCM_PTR is where the answer has to end up
; anyway. The direct page has four bytes free, not eight (PORT.md 19).
;
ADP_DECODE      .proc
                PHP
                setaxl

                LDA #0
                STA @l ADP_OUTN
                STA @l ADP_OUTN+2
                STA @l ADP_PRED
                STA @l ADP_IDX
                STA @l ADP_BLKN

                LDA #<>ADP_OUT
                STA PCM_PTR
                LDA #`ADP_OUT
                STA PCM_PTR+2

ad_loop         setaxl
                LDA @l ADP_IN               ; anything left to read?
                ORA @l ADP_IN+2
                BNE ad_more
ad_toend        JMP ad_done                 ; the arms below are wider than a
                                            ;  branch reaches, so both exits
                                            ;  go through here
ad_more         LDA @l ADP_BLK              ; a continuous stream has no
                BEQ ad_todata               ;  block headers at all
                LDA @l ADP_BLKN
                BEQ ad_header
ad_todata       JMP ad_data

                ; ---- a block header: four bytes, and the predictor it
                ;      carries IS the block's first sample ----
ad_header       LDA @l ADP_IN+2
                BNE ad_hdrok
                LDA @l ADP_IN
                CMP #4
                BCC ad_toend                ; a tail too short to be one

ad_hdrok        setal
                LDA [MTEMP]                 ; the starting predictor
                STA @l ADP_PRED
                LDY #2
                LDA [MTEMP],Y               ; and the starting index, with
                AND #$00FF                  ;  the reserved byte beside it
                CMP #89
                BCC ad_idxok
                LDA #88                     ; a file claiming 200 is a file
ad_idxok        STA @l ADP_IDX              ;  we decline to index with

                CALL ADP_INSTEP
                CALL ADP_INSTEP
                CALL ADP_INSTEP
                CALL ADP_INSTEP

                setal
                LDA @l ADP_BLK
                SEC
                SBC #4
                STA @l ADP_BLKN

                CALL ADP_EMIT               ; the header's predictor is a
                BRA ad_loop                 ;  sample, not just a seed

                ; ---- a data byte: two samples, low nibble first ----
ad_data         setal
                LDA [MTEMP]
                AND #$000F
                STA @l ADP_NIB
                CALL ADP_STEPNIB
                CALL ADP_EMIT

                setal
                LDA [MTEMP]
                AND #$00F0
                LSR A
                LSR A
                LSR A
                LSR A
                STA @l ADP_NIB
                CALL ADP_STEPNIB
                CALL ADP_EMIT

                CALL ADP_INSTEP
                setal
                LDA @l ADP_BLK
                BEQ ad_loop2
                LDA @l ADP_BLKN
                BEQ ad_loop2
                DEC A
                STA @l ADP_BLKN
ad_loop2        BRL ad_loop

ad_done         PLP
                RETURN
                .pend

;
; Walk a RIFF/WAVE file in the staging buffer.
;
; Outputs:
;   Carry SET  -- it was one, and it was IMA ADPCM mono. MTEMP points at
;                 the data chunk, ADP_IN is its length, ADP_BLK is the
;                 block size and ADP_RATE the sample rate.
;   Carry CLEAR -- not a RIFF at all: the caller decodes it raw.
;
; Throws when it IS a RIFF and is not something this can play, rather
; than decoding a stereo or an 8-bit file into noise and letting the
; speaker report it.
;
; No PHP anywhere near the exits: the answer is in the carry, and a PLP
; would put the caller's flags back over it -- the same trap noted in
; X816/input_x816.s.
;
ADP_WAV         .proc
                setaxl
                PHX
                PHY

                LDA #<>VIO_STAGE            ; the cursor, at the RIFF header
                STA MTEMP
                LDA #`VIO_STAGE
                STA MTEMP+2

                LDA @l VIO_N+2              ; twelve bytes before there can
                BNE aw_big                  ;  be a chunk at all
                LDA @l VIO_N
                CMP #12
                BCS aw_big
aw_toraw        JMP aw_raw                  ; the chunk walk stands between
                                            ;  here and both exits, so they
                                            ;  each get a trampoline
aw_big          LDA [MTEMP]                 ; "RI"
                CMP #$4952
                BNE aw_toraw
                LDY #2
                LDA [MTEMP],Y               ; "FF"
                CMP #$4646
                BNE aw_toraw
                LDY #8
                LDA [MTEMP],Y               ; "WA"
                CMP #$4157
                BNE aw_toraw
                LDY #10
                LDA [MTEMP],Y               ; "VE"
                CMP #$4556
                BNE aw_toraw

                LDA #0                      ; nothing found yet
                STA @l ADP_BLK
                STA @l ADP_RATE
                STA @l ADP_RATE+2

                LDA @l VIO_N                ; bytes left from the cursor
                SEC
                SBC #12
                STA @l ADP_T+4
                LDA @l VIO_N+2
                SBC #0
                STA @l ADP_T+6

                LDA MTEMP                   ; past the twelve-byte header
                CLC
                ADC #12
                STA MTEMP
                BCC aw_chunk
                INC MTEMP+2

                ; ---- each chunk: four bytes of id, four of length ----
aw_chunk        setaxl
                LDA @l ADP_T+6
                BNE aw_have8
                LDA @l ADP_T+4
                CMP #8
                BCS aw_have8
                JMP aw_bad                  ; ran out before a data chunk

aw_have8        LDY #4                      ; the chunk's length
                LDA [MTEMP],Y
                STA @l ADP_T
                LDY #6
                LDA [MTEMP],Y
                STA @l ADP_T+2

                LDA [MTEMP]                 ; "fm"
                CMP #$6D66
                BNE aw_notfmt
                LDY #2
                LDA [MTEMP],Y               ; "t "
                CMP #$2074
                BNE aw_notfmt

                LDY #8                      ; wFormatTag: 17 is IMA ADPCM
                LDA [MTEMP],Y
                CMP #17
                BNE aw_tobad
                LDY #10                     ; nChannels
                LDA [MTEMP],Y
                CMP #1
                BNE aw_tobad
                LDY #12                     ; nSamplesPerSec
                LDA [MTEMP],Y
                STA @l ADP_RATE
                LDY #14
                LDA [MTEMP],Y
                STA @l ADP_RATE+2
                LDY #20                     ; nBlockAlign
                LDA [MTEMP],Y
                CMP #5                      ; a block is four bytes of header
                BCC aw_tobad                ;  and at least one of data
                STA @l ADP_BLK
                BRA aw_next

aw_tobad        JMP aw_bad                  ; nothing falls in here: the BRA
                                            ;  above is unconditional
aw_notfmt       LDA [MTEMP]                 ; "da"
                CMP #$6164
                BNE aw_next
                LDY #2
                LDA [MTEMP],Y               ; "ta"
                CMP #$6174
                BNE aw_next

                LDA @l ADP_BLK              ; data before fmt: a file we
                BEQ aw_tobad                ;  cannot decode without going
                                            ;  back, and nobody writes one

                LDA MTEMP                   ; the cursor to the samples
                CLC
                ADC #8
                STA MTEMP
                BCC aw_dlen
                INC MTEMP+2

aw_dlen         LDA @l ADP_T                ; and its length, but no more
                STA @l ADP_IN               ;  than the file actually holds
                LDA @l ADP_T+2
                STA @l ADP_IN+2

                LDA @l ADP_T+6
                BNE aw_dcap
                LDA @l ADP_T+4
                SEC
                SBC #8
                STA @l ADP_T+4
                LDA #0
                STA @l ADP_T+6
aw_dcap         LDA @l ADP_IN+2
                CMP @l ADP_T+6
                BCC aw_dok
                BNE aw_trunc
                LDA @l ADP_IN
                CMP @l ADP_T+4
                BCC aw_dok
aw_trunc        LDA @l ADP_T+4              ; a length field longer than the
                STA @l ADP_IN               ;  file: trust the file
                LDA @l ADP_T+6
                STA @l ADP_IN+2

aw_dok          PLY
                PLX
                SEC
                RETURN

                ; ---- on to the next chunk: 8 + length, rounded up ----
aw_next         setaxl
                LDA @l ADP_T
                AND #1                      ; an odd chunk is followed by a
                BEQ aw_even                 ;  pad byte
                LDA @l ADP_T
                CLC
                ADC #1
                STA @l ADP_T
                LDA @l ADP_T+2
                ADC #0
                STA @l ADP_T+2

aw_even         LDA @l ADP_T
                CLC
                ADC #8
                STA @l ADP_T
                LDA @l ADP_T+2
                ADC #0
                STA @l ADP_T+2

                LDA @l ADP_T+2              ; a chunk longer than what is
                CMP @l ADP_T+6              ;  left is a broken file
                BCC aw_step
                BNE aw_bad
                LDA @l ADP_T
                CMP @l ADP_T+4
                BCS aw_bad

aw_step         LDA MTEMP
                CLC
                ADC @l ADP_T
                STA MTEMP
                LDA MTEMP+2
                ADC @l ADP_T+2
                STA MTEMP+2

                LDA @l ADP_T+4
                SEC
                SBC @l ADP_T
                STA @l ADP_T+4
                LDA @l ADP_T+6
                SBC @l ADP_T+2
                STA @l ADP_T+6
                JMP aw_chunk

aw_raw          PLY
                PLX
                CLC
                RETURN

aw_bad          PLY
                PLX
                THROW ERR_ARGUMENT
                .pend

;
; Set VERA's rate register from ADP_RATE, if a header gave us one.
;
; The register steps by 25000000/(512*128), about 381.47 Hz. 381 is used
; instead, and the +190 rounds rather than truncates: the error is a
; tenth of a percent, which is a tenth of a semitone over eight octaves
; and inaudible, and it costs one divide instead of a scaled one.
;
ADP_SETRATE     .proc
                PHP
                setaxl

                LDA @l ADP_RATE
                ORA @l ADP_RATE+2
                BEQ ar_done                 ; a raw stream says nothing about
                                            ;  its rate, so PCMRATE stands

                LDA @l ADP_RATE
                CLC
                ADC #190
                STA ARGUMENT1
                LDA @l ADP_RATE+2
                ADC #0
                STA ARGUMENT1+2
                LDA #381
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2
                CALL UDIV32

                setaxl
                LDA ARGUMENT1+2             ; anything over 128 the hardware
                BNE ar_cap                  ;  reads as 256-n, which is a
                LDA ARGUMENT1               ;  wrap and not a clamp
                CMP #129
                BCC ar_put
ar_cap          LDA #128
ar_put          setas
                STA @l VERA_AUDIO_RATE

ar_done         PLP
                RETURN
                .pend

;
; ADPCMPLAY file$ -- decode an IMA ADPCM file and play it.
;
S_ADPCMPLAY     .proc
                PHP
                TRACE "S_ADPCMPLAY"
                setaxl

                CALL PCM_STOP               ; whatever was playing, is not
                                            ;  now -- and the feeder must be
                                            ;  off before PCM_PTR is borrowed
                                            ;  as the decoder's output cursor
                CALL EVALEXPR
                CALL ASS_ARG1_STR
                CALL SETFILEDESC
                CALL VIO_LOAD               ; the staging buffer, and VIO_N

                setaxl
                LDA @l VIO_N                ; an empty file is not a sample
                ORA @l VIO_N+2
                BNE ap_have
                JMP ap_done
ap_have
                CALL ADP_WAV                ; a header, or a raw stream
                BCS ap_sized

                LDA @l VIO_N                ; raw: the whole file, no blocks
                STA @l ADP_IN
                LDA @l VIO_N+2
                STA @l ADP_IN+2
                LDA #0
                STA @l ADP_BLK
                STA @l ADP_RATE
                STA @l ADP_RATE+2
                LDA #<>VIO_STAGE
                STA MTEMP
                LDA #`VIO_STAGE
                STA MTEMP+2

                ; Four output bytes a compressed byte, and the buffer is
                ; what it is. Checked HERE, before a sample is decoded:
                ; the alternative is finding out by writing over $10:0000,
                ; which is the next program's staging area and would come
                ; back as that program misbehaving.
ap_sized        setaxl
                LDA @l ADP_IN+2
                CMP #`ADP_INMAX
                BCC ap_fits
                BNE ap_toobig
                LDA @l ADP_IN
                CMP #<>ADP_INMAX
                BCS ap_toobig
ap_fits
                CALL ADP_DECODE
                CALL ADP_SETRATE

                setaxl
                LDA @l ADP_OUTN             ; did it decode anything?
                ORA @l ADP_OUTN+2
                BEQ ap_done

                ; 16-bit mono, and this statement sets it rather than
                ; leaving it to PCMMODE. PCMPLAY does not, and the
                ; difference is real: a raw file says nothing about its
                ; format so the program must, and an IMA file has
                ; exactly one decoded format -- there is nothing for a
                ; program to choose and a wrong PCMMODE would only be a
                ; way to hear noise.
                setas
                LDA @l VERA_AUDIO_CTRL
                AND #$0F                    ; keep the volume
                ORA #$20                    ; 16-bit, mono
                STA @l VERA_AUDIO_CTRL

                setal                       ; the feeder reads the decoded
                LDA #<>ADP_OUT              ;  buffer, not the staging one
                STA PCM_PTR
                LDA #`ADP_OUT
                STA PCM_PTR+2
                LDA @l ADP_OUTN
                STA @l PCM_LEN
                LDA @l ADP_OUTN+2
                STA @l PCM_LEN+2

                setas
                LDA #1
                STA @l PCM_ON

                setaxl                      ; the handler, THEN the source,
                LDY #`PCM_FEED              ;  as PCMPLAY does and for the
                LDX #<>PCM_FEED             ;  same reason
                LDA #KIRQ_AFLOW
                JSL KERN_IRQ_SET
                BCS ap_bad

                CALL PCM_FEED_NOW           ; prime it: AFLOW fires on a FIFO
                                            ;  that has drained, and an empty
                                            ;  one never drains
                setas
                LDA @l VERA_IEN
                ORA #$08                    ; AFLOW on
                STA @l VERA_IEN

ap_done         PLP
                RETURN
ap_toobig       THROW ERR_RANGE
ap_bad          THROW ERR_ARGUMENT
                .pend


;;;
;;; ZX0 decompression
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; Ported from the working 6502 version in X816_Library (util/zx0.asm),
;;; which is itself a port of Einar Saukas's reference dzx0. What the
;;; port had to change is the pointers: that one is 16-bit and lives
;;; inside 64 KB, and this machine is flat 16 MB, so all three cursors
;;; are 24-bit.
;;;
;;; THREE CURSORS AND NO NEW DIRECT PAGE. [ptr] addressing exists only
;;; there and the page has 46 bytes left, but none are spent here:
;;; MTEMP reads the compressed stream, ARGUMENT1 writes the output and
;;; ARGUMENT2 reads the output back for a match. All three are scratch
;;; that nothing else touches while this runs -- the same borrowing
;;; REPLACE$ does, and for the same reason.
;;;
;;; RAM TO RAM, AND NOT IN PLACE. The match copier reads the output
;;; back, so the destination cannot overlap the source.
;;;
;;; It decodes the MODERN ZX0 v2 stream, which is what `zx0` and
;;; `salvador` emit by default -- not their -classic mode. Three
;;; states (literals, repeat the last offset, a new offset),
;;; interlaced Elias gamma lengths, and the offset byte's low bit
;;; seeding the next length.
;;;

;
; A (8-bit) = the next byte of the compressed stream.
;
ZX_GETBYTE      .proc
                PHP
                setas
                LDA [MTEMP]
                STA @l ZX_LAST
                setal
                INC MTEMP
                BNE gb_ok
                INC MTEMP+2
gb_ok           setas
                LDA @l ZX_LAST
                PLP
                RETURN
                .pend

;
; The next bit of the stream, into the carry.
;
; The buffer keeps a sentinel 1 in bit 0, so a zero buffer after the
; shift means "that carry WAS the sentinel": refill and take bit 7 of
; the fresh byte instead. ZX_BT is the backtrack -- after a new offset,
; the low bit of the offset byte is the first bit of the length that
; follows, and it has already gone past.
;
; NO PHP: the answer is the carry.
;
ZX_GETBIT       .proc
                setas
                LDA @l ZX_BT
                BEQ gt_stream

                LDA #0                      ; the backtracked bit
                STA @l ZX_BT
                LDA @l ZX_LAST
                LSR A
                RETURN

gt_stream       LDA @l ZX_BITS              ; ASL has no long addressing mode,
                ASL A                       ;  so the buffer goes through A --
                STA @l ZX_BITS              ;  and the carry it shifts out is
                BEQ gt_refill               ;  the answer, so nothing may
                RETURN                      ;  touch the flags after it

gt_refill       CALL ZX_GETBYTE
                setas
                SEC
                ROL A                       ; carry = bit 7, sentinel to bit 0
                STA @l ZX_BITS
                RETURN
                .pend

;
; An interlaced Elias gamma number into ZX_VAL. ZX_INV inverts the data
; bits, which is what the v2 stream wants for a new offset's high part.
;
ZX_GAMMA        .proc
                PHP
                setaxl

                LDA #1
                STA @l ZX_VAL

ga_more         CALL ZX_GETBIT
                BCS ga_done                 ; a 1 control bit ends it

                CALL ZX_GETBIT              ; the data bit, into the carry
                setas
                LDA #0
                ROL A
                EOR @l ZX_INV
                LSR A                       ; ...and back out of it
                setal
                LDA @l ZX_VAL               ; ROL has no long mode either
                ROL A
                STA @l ZX_VAL
                BRA ga_more

ga_done         PLP
                RETURN
                .pend

;
; ZX_VAL -= 1, Z set when it reaches zero.
;
ZX_DECLEN       .proc
                PHP
                setal
                LDA @l ZX_VAL
                DEC A
                STA @l ZX_VAL
                PLP
                RETURN
                .pend

;
; Copy ZX_VAL bytes from (output - ZX_OFF) to the output.
;
ZX_COPY         .proc
                PHP
                setal

                SEC                         ; ARGUMENT2 = output - offset
                LDA ARGUMENT1
                SBC @l ZX_OFF
                STA ARGUMENT2
                LDA ARGUMENT1+2
                SBC #0
                STA ARGUMENT2+2

cp_byte         setas
                LDA [ARGUMENT2]
                STA [ARGUMENT1]

                setal
                INC ARGUMENT2
                BNE cp_dst
                INC ARGUMENT2+2
cp_dst          INC ARGUMENT1
                BNE cp_count
                INC ARGUMENT1+2

cp_count        CALL ZX_DECLEN
                setal
                LDA @l ZX_VAL
                BNE cp_byte

                PLP
                RETURN
                .pend

;
; ZX0(src, dst) -- decompress, and answer one past the last byte out.
;
; A function rather than a statement because the LENGTH is the thing a
; caller cannot work out for itself: a compressed file says how big it
; unpacks to only by unpacking. Knowing where the output ended is what
; lets a program load two of them back to back.
;
FN_ZX0          .proc
                FN_START "FN_ZX0"
                PHP
                setaxl

                CALL EVALEXPR               ; the compressed data
                CALL ASS_ARG1_INT
                setal
                LDA ARGUMENT1
                STA @l ZX_S
                LDA ARGUMENT1+2
                STA @l ZX_S+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; where it goes
                CALL ASS_ARG1_INT

                setal                       ; the cursors, set AFTER the last
                LDA @l ZX_S                 ;  EVALEXPR: an expression can
                STA MTEMP                   ;  stream a file through MTEMP and
                LDA @l ZX_S+2               ;  uses ARGUMENT1 for its answer
                STA MTEMP+2
                                            ; ARGUMENT1 already holds dst

                setas                       ; an empty bit buffer refills on
                LDA #0                      ;  first use
                STA @l ZX_BITS
                STA @l ZX_BT
                setal
                LDA #1                      ; the first offset is 1
                STA @l ZX_OFF

                ; ---- literals ----
zx_lits         setas
                LDA #0
                STA @l ZX_INV
                CALL ZX_GAMMA               ; how many

zx_litb         CALL ZX_GETBYTE
                setas
                STA [ARGUMENT1]
                setal
                INC ARGUMENT1
                BNE zx_litc
                INC ARGUMENT1+2
zx_litc         CALL ZX_DECLEN
                setal
                LDA @l ZX_VAL
                BNE zx_litb

                CALL ZX_GETBIT
                BCS zx_newoff

                ; ---- the same offset again ----
                setas
                LDA #0
                STA @l ZX_INV
                CALL ZX_GAMMA               ; how long a match
                CALL ZX_COPY
                CALL ZX_GETBIT
                BCC zx_lits

                ; ---- a new offset ----
zx_newoff       setas
                LDA #1                      ; the high part is INVERTED gamma
                STA @l ZX_INV
                CALL ZX_GAMMA

                setal
                LDA @l ZX_VAL               ; 256 is the end of the stream
                CMP #256
                BEQ zx_end

                ; offset = val*128 - (byte >> 1). The 6502 original does
                ; the multiply as LSR into the high byte and ROR the
                ; carry into bit 7 of the low one, which is a BYTE pair;
                ; transcribed into 16-bit A that stored two bytes at
                ; ZX_OFF+1 and smeared past it. Here it is one shift.
                LDA @l ZX_VAL
                .rept 7
                ASL A
                .next
                STA @l ZX_OFF

                CALL ZX_GETBYTE             ; and this latches ZX_LAST, which
                setas                       ;  the backtrack below reads
                LSR A
                setal
                AND #$00FF
                STA @l ZX_T
                SEC
                LDA @l ZX_OFF
                SBC @l ZX_T
                STA @l ZX_OFF

                setas                       ; that byte's low bit is the FIRST
                LDA #1                      ;  bit of the length gamma
                STA @l ZX_BT
                LDA #0
                STA @l ZX_INV
                CALL ZX_GAMMA

                setal
                LDA @l ZX_VAL               ; a new offset's match is one
                INC A                       ;  longer than it says
                STA @l ZX_VAL
                CALL ZX_COPY

                CALL ZX_GETBIT
                BCS zx_newoff
                BRL zx_lits

zx_end          setaxl                      ; one past the last byte written
                LDA ARGUMENT1+2
                AND #$00FF
                STA @l ZX_T
                LDA ARGUMENT1
                STA ARGUMENT1
                LDA @l ZX_T
                STA ARGUMENT1+2

                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

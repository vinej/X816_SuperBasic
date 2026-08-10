;;;
;;; VERA FX: the 32-bit write cache, and nothing else
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; WHAT IS HERE IS THE FILL, AND WHAT IS NOT HERE IS THE MULTIPLIER.
;;; Both decisions come from reading the hardware rather than the feature
;;; list, so both are written down.
;;;
;;; The fill is worth having. VERA's write cache is four bytes wide: with
;;; cache-write enabled, ONE store to the data port lays down four bytes,
;;; so a tilemap or a sprite sheet clears at four bytes per port write
;;; instead of one. SuperBasic had no bulk VRAM write at all before this
;;; -- VPOKE is one byte and re-sends the address every time -- so from
;;; BASIC the difference is not four times, it is the difference between
;;; a statement and a FOR loop nobody will wait for.
;;;
;;; NONE OF THIS TOUCHES THE BITMAP, and that is not a limitation of the
;;; code. The VERA2 framebuffer is ordinary CPU memory at $E0:0000, not
;;; VRAM, so the write cache cannot reach it; PSET, LINE, CIRCLE, FILL,
;;; RECT and BITMAP are all unaffected by everything in this file. What
;;; lives in VRAM is the text matrix, the font, the tilemaps, the sprite
;;; pixels and the palette -- HELP TILE, HELP SPRITE, HELP PAL -- and
;;; those are what there is to fill.
;;;
;;; THE MULTIPLIER IS ABSENT BECAUSE ITS RESULT CANNOT BE READ BACK. The
;;; hardware does have a 16x16 multiplier with a 32-bit accumulator, and
;;; an earlier version of help/VERAFX.TXT said the answer could be read
;;; at DCSEL 6 with no VRAM round trip. That is not true of either
;;; implementation:
;;;
;;;   the core     addr_data.v exposes the cache as ib_cache8, and top.v
;;;                passes it to vram_if.v, where the only use is
;;;                if0_wrdata_to_use -- VRAM WRITE DATA. There is no path
;;;                from the cache to the CPU data bus.
;;;   the emulator video.c reads $9F29-$9F2C at DCSEL 6 through a switch
;;;                whose 0x18 case resets the accumulator, whose 0x19
;;;                case performs the multiply, and which then falls out
;;;                and returns a byte of the version string. The cache is
;;;                readable only by the debugger (video_get_fx_accum).
;;;
;;; So getting a product out means writing the cache into VRAM and
;;; reading those four bytes back through the port: about twenty register
;;; accesses and a scratch VRAM address to clobber. Against that,
;;; SuperBasic's OP_INT_MUL is a 32-iteration shift-add -- and it is
;;; 32x32, where the hardware is 16x16, so the fast path would cover one
;;; special case and hand the general one back to the loop anyway. A
;;; keyword whose contract is "fast, unless your numbers are large, and
;;; it eats four bytes of VRAM you must nominate" is not worth having.
;;;
;;; If the read-back is ever added to the core, this is the file it
;;; belongs in and the note above is what to delete.
;;;

;
; FX_CACHE_SET -- load all four cache bytes with A (8-bit).
;
; The four bytes live at one address, DCSEL 6 $9F29, and the byte index
; auto-advances on each write (fx_cache_byte_index in video.c), so four
; stores to the same register fill all four. Leaves DCSEL 6 selected.
;
FX_CACHE_SET    .proc
                PHP
                setas
                PHA
                LDA #(6 << 1)               ; DCSEL 6, data port 0
                STA @l VERA_CTRL
                PLA
                STA @l VERA_FX_CACHE
                STA @l VERA_FX_CACHE
                STA @l VERA_FX_CACHE
                STA @l VERA_FX_CACHE
                PLP
                RETURN
                .pend

;
; FX_RESET -- every FX register this file touches, back to stock.
;
; Both DCSEL 2 registers are cleared, not just the one that was set: a
; program is free to have poked the others with VPOKE, and the whole
; point of the call is that ordinary VRAM writes work afterwards. Ends at
; DCSEL 0 with data port 0 selected, which is the state every other
; statement in SuperBasic assumes on entry.
;
FX_RESET        .proc
                PHP
                setas
                LDA #(2 << 1)               ; DCSEL 2
                STA @l VERA_CTRL
                LDA #0
                STA @l VERA_FX_CTRL         ; cache write, 4-bit, transparency
                STA @l VERA_FX_MULT         ; cache index, multiplier, subtract
                STA @l VERA_CTRL            ; DCSEL 0, data port 0
                PLP
                RETURN
                .pend

;
; FX_POINT -- point data port 0 at FX_ADDR, with the increment nibble in A.
;
;   in: A = increment nibble (8-bit), 1 for a step of one, 3 for four
;
; THE NIBBLE IS AN INDEX, NOT THE STEP. video.c's increments[] is indexed
; by nibble*2 (the odd entries being the decrements), so nibble 1 steps 1
; and nibble 3 steps 4. Reading it as the step fills every fourth byte and
; leaves the rest, which looks like a hardware fault rather than an
; arithmetic one.
;
FX_POINT        .proc
                PHP
                setas
                ASL A
                ASL A
                ASL A
                ASL A                       ; nibble into bits 4-7
                PHA
                LDA #0                      ; DCSEL 0, data port 0
                STA @l VERA_CTRL
                LDA @l FX_ADDR
                STA @l VERA_ADDR_L
                LDA @l FX_ADDR+1
                STA @l VERA_ADDR_M
                LDA @l FX_ADDR+2
                AND #$01                    ; VRAM is 17 bits
                ORA 1,S                     ; the increment nibble
                STA @l VERA_ADDR_H
                PLA
                PLP
                RETURN
                .pend

;
; FX_WBYTES -- write X bytes of FX_BYTE at wherever the port points.
;
;   in: X = count (16-bit), the port already pointed with a step of one
;
; The caller points the port; this only streams, which is what makes the
; three passes below read as three passes.
;
FX_WBYTES       .proc
                PHP
                setxl
                setas
                CPX #0
                BEQ fw_out
                LDA @l FX_BYTE
fw_loop         STA @l VERA_DATA0           ; the port auto-increments
                DEX
                BNE fw_loop
fw_out          PLP
                RETURN
                .pend

;
; FX_ADVANCE -- FX_ADDR += A, FX_LEFT -= A  (A 16-bit)
;
FX_ADVANCE      .proc
                PHP
                setal
                PHA
                CLC
                ADC @l FX_ADDR
                STA @l FX_ADDR
                LDA @l FX_ADDR+2
                ADC #0
                AND #$0001                  ; VRAM is 17 bits
                STA @l FX_ADDR+2
                SEC
                LDA @l FX_LEFT
                SBC 1,S
                STA @l FX_LEFT
                LDA @l FX_LEFT+2
                SBC #0
                STA @l FX_LEFT+2
                PLA
                PLP
                RETURN
                .pend

;
; FX_DOFILL -- the fill itself, on FX_BYTE, FX_ADDR and FX_LEFT.
;
; Shared by FXFILL and FXCLEAR, which is why those three are globals
; rather than stack locals: a called proc cannot reach the caller's frame.
;
; Three passes, and only the middle one is the accelerator:
;
;   head    up to the next multiple of four, one byte per port write.
;           Needed because cache-write masks the address to a multiple of
;           four IN HARDWARE (video.c: address &= 0x1fffc), so an
;           unaligned start would begin up to three bytes EARLY and
;           overwrite bytes the caller never named. Refusing unaligned
;           addresses would have been easier and worse: a tilemap row is
;           80 or 128 bytes and starts wherever it starts.
;   middle  four bytes per port write, through the cache.
;   tail    the leftover one to three, plainly again.
;
FX_DOFILL       .proc
                PHP
                setaxl

                LDA @l FX_LEFT              ; nothing asked for, nothing done
                ORA @l FX_LEFT+2
                BNE fd_any
                JMP fd_out

                ; The refusal sits here, before its callers, so every
                ; branch to it is a short one. VRAM is 17 bits: the last
                ; byte is $1FFFF, so an END of exactly $20000 is the
                ; first address a fill may reach and not write.
fd_range        PLP
                THROW ERR_RANGE

fd_any          CLC
                LDA @l FX_ADDR
                ADC @l FX_LEFT
                STA @l FX_END
                LDA @l FX_ADDR+2
                ADC @l FX_LEFT+2
                STA @l FX_END+2
                BEQ fd_head                 ; under $10000
                CMP #$0001
                BEQ fd_head                 ; under $20000
                CMP #$0002
                BNE fd_range                ; $30000 and up
                LDA @l FX_END
                BNE fd_range                ; past $20000 by something
                                            ; exactly $20000: allowed

fd_head         setal                       ; --- head ---------------------
                LDA @l FX_ADDR
                AND #$0003
                BEQ fd_mid                  ; already on a boundary
                EOR #$FFFF                  ; 4 - (addr & 3)
                INC A
                AND #$0003
                TAX
                LDA @l FX_LEFT+2            ; but never more than was asked
                BNE fd_hgo                  ; LEFT >= $10000, so 1-3 is fine
                TXA                         ; CPX and LDX have no long mode,
                CMP @l FX_LEFT              ;  so the compare goes through A
                BCC fd_hgo
                LDA @l FX_LEFT
                TAX
fd_hgo          setas
                LDA #1                      ; increment nibble 1 = step of one
                CALL FX_POINT
                setaxl
                CALL FX_WBYTES
                TXA
                CALL FX_ADVANCE

fd_mid          setal                       ; --- middle -------------------
                ; quads = LEFT >> 2, one bit at a time and through memory,
                ; because there is no stack or accumulator shift that will
                ; carry between two words. FX_END is free: the range check
                ; above has had its use of it.
                LDA @l FX_LEFT+2
                LSR A
                STA @l FX_END+2
                LDA @l FX_LEFT
                ROR A
                STA @l FX_END
                LDA @l FX_END+2
                LSR A
                LDA @l FX_END
                ROR A                       ; LEFT is at most $20000, so the
                TAX                         ;  quad count fits a word
                BNE fd_mgo
                JMP fd_tail

fd_mgo          PHX
                setas
                LDA @l FX_BYTE
                CALL FX_CACHE_SET           ; all four cache bytes
                LDA #(2 << 1)               ; DCSEL 2
                STA @l VERA_CTRL
                LDA #$40                    ; bit 6: four-byte cache write
                STA @l VERA_FX_CTRL
                LDA #3                      ; increment nibble 3 = step of four
                CALL FX_POINT
                setaxl
                PLX

                PHX
                setas
                LDA @l FX_BYTE              ; any value: the CACHE is written
fd_quad         STA @l VERA_DATA0
                DEX
                BNE fd_quad
                setaxl
                PLA                         ; the quad count again

                ; THE ARITHMETIC FIRST, THE REGISTERS AFTER. This was the
                ; other way round, and FX_RESET ends by storing a zero to
                ; VERA_CTRL -- so it returns with A = 0, the two shifts
                ; doubled nothing, and FX_ADVANCE walked the address on by
                ; nought. The tail then re-filled bytes the cache had
                ; already done and stopped three short of the end: with
                ; FXFILL 7,$4801,10, $4801 was 7 and $480A was 0.
                ;
                ; Session W caught it because it reads the LAST byte of
                ; the range and not only the first. FX_ADVANCE touches no
                ; VERA register, so nothing needs the reset to come first.
                ASL A                       ; quads to bytes
                ASL A
                CALL FX_ADVANCE
                CALL FX_RESET               ; now put the mode bits back

fd_tail         setal                       ; --- tail ---------------------
                LDA @l FX_LEFT
                AND #$0003
                TAX
                BEQ fd_done
                setas
                LDA #1
                CALL FX_POINT
                setaxl
                CALL FX_WBYTES

fd_done         CALL FX_RESET
fd_out          PLP
                RETURN
                .pend

;
; FXFILL b, addr, count -- fill VRAM with a byte, four at a time.
;
S_FXFILL        .proc
                PHP
                TRACE "S_FXFILL"
                setaxl

                CALL EVALEXPR               ; the byte
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                AND #$00FF
                STA @l FX_BYTE

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; the VRAM address
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l FX_ADDR
                LDA ARGUMENT1+2
                AND #$0001                  ; VRAM is 17 bits
                STA @l FX_ADDR+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; how many bytes
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l FX_LEFT
                LDA ARGUMENT1+2
                STA @l FX_LEFT+2

                CALL FX_DOFILL

                PLP
                RETURN
                .pend

;
; FXCLEAR addr, count -- the same with a zero, which is what it is for.
;
S_FXCLEAR       .proc
                PHP
                TRACE "S_FXCLEAR"
                setaxl

                LDA #0
                STA @l FX_BYTE

                CALL EVALEXPR               ; the VRAM address
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l FX_ADDR
                LDA ARGUMENT1+2
                AND #$0001
                STA @l FX_ADDR+2

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR               ; how many bytes
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l FX_LEFT
                LDA ARGUMENT1+2
                STA @l FX_LEFT+2

                CALL FX_DOFILL

                PLP
                RETURN
                .pend

;
; FXOFF -- put the FX registers back.
;
; FXFILL and FXCLEAR restore what they touched, so this is not needed
; after either of them. It is here for a program that has been poking
; $9F29-$9F2C itself through VPOKE, where forgetting to undo the mode
; bits corrupts the next thing anything draws -- and the symptom is four
; bytes appearing where one was asked for, which is a long way from
; pointing at a mode register.
;
S_FXOFF         .proc
                PHP
                TRACE "S_FXOFF"
                CALL FX_RESET
                PLP
                RETURN
                .pend

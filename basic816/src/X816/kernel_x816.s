;;;
;;; X816 kernel crossing glue
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; Width discipline (from X816_Library system/x816kernel.asm): the
;;; kernel is entered with M=0/X=0 via JSL and clobbers A/X/Y and flags;
;;; it preserves only D and DBR. Every wrapper here saves the caller's
;;; state, crosses once, and restores on every path. Arguments are
;;; masked so the hidden high byte of A never leaks into a call.
;;;

;
; Check whether the user has pressed Ctrl-C.
; Drop-in replacement for the Foenix kernel's FK_TESTBREAK:
; called with JSL from interpreter.s / listing.s / repl.s.
;
; There is no $03 to look for. The kernel folds Shift into the character
; it returns but reports Ctrl as a key event in its own right, leaving
; the meaning to the caller (see KEY_LCTRL in x816_kernel.inc). Holding
; Ctrl and pressing C therefore arrives as two polls: $013A, then 'c'.
;
; So Ctrl sets a latch and the next key decides. con_getkey discards
; every key-up except Shift's, so the release of Ctrl is never seen and
; the latch cannot be cleared by it — instead the next key spends it,
; whatever that key is. The window in which a stray 'c' could be read as
; a break is thus exactly one keystroke after Ctrl was pressed.
;
; Note this consumes the key it polls, which is the same bargain the
; C256 build makes with its interrupt-set flag: keystrokes typed at a
; running program are swallowed by the break check.
;
; Outputs:
;   C set if BREAK (Ctrl-C) was pressed, clear otherwise
;
FK_TESTBREAK    PHX
                PHY
                PHP
                setaxl
                JSL KERN_CON_GETKEY     ; Non-blocking key poll
                BCS no_break            ; Kernel error: treat as no key
                CMP #0
                BEQ no_break            ; Nothing waiting: the latch survives

                CMP #KEY_LCTRL          ; Ctrl itself: arm the latch
                BEQ arm_latch
                CMP #KEY_RCTRL
                BEQ arm_latch

                TAX                     ; Any other key spends the latch
                setas
                LDA @l CTRL_DOWN
                BEQ not_armed           ; Ctrl was not held: ordinary keystroke

                LDA #0
                STA @l CTRL_DOWN
                setal
                TXA                     ; Is this the C of Ctrl-C?
                CMP #'c'
                BEQ break_hit
                CMP #'C'
                BEQ break_hit
                CMP #CHAR_CTRL_C        ; Should a later kernel map it after all
                BEQ break_hit
                BRA no_break

not_armed       setal
                BRA no_break

arm_latch       setas
                LDA #1
                STA @l CTRL_DOWN
                setal

no_break        PLP
                PLY
                PLX
                CLC
                RTL
break_hit       PLP
                PLY
                PLX
                SEC
                RTL

;;;
;;; Disk: the Foenix FK_* entry points, over the X816 kernel's K_FS_*.
;;;
;;; dos.s reaches the card ONLY through these, so implementing them here
;;; lights up LOAD/SAVE/BLOAD/BSAVE without touching portable code.
;;;
;;; THE CARRY IS INVERTED between the two sides, and this is the thing to
;;; get right. Every call site in dos.s reads carry SET as SUCCESS
;;; ("JSL FK_LOAD / BCS start_tokenize"). The X816 kernel uses the
;;; opposite convention -- carry set is failure, with a KERR in C. So
;;; each routine below flips it, and each sets the carry AFTER its PLP,
;;; because PLP would otherwise restore the caller's.
;;;

;
; Load a whole file into memory.
;
; Inputs:
;   FD_IN.PATH   = 24-bit pointer to a NUL-terminated path
;   DOS_DST_PTR  = 24-bit destination address
;
; Outputs:
;   C set on success, clear on failure
;   FD_IN.FILESIZE = the file's size
;
; FD_IN is used directly rather than through DOS_FD_PTR: every caller
; sets that pointer to FD_IN via SETFILEDESC, and FD_IN is not on the
; direct page here, so an indirect read would have to move D first.
;
FK_LOAD         PHP
                setaxl
                PHB
                PHX
                PHY

                LDA @l FD_IN.PATH+2     ; C:X = path, Y = mode. LDX has no
                TAX                     ;  long addressing mode, so the bank
                LDA @l FD_IN.PATH       ;  goes through A
                LDY #KFS_READ
                JSL KERN_FS_OPEN
                BCS load_fail
                STA @l FS_BLK_H         ; keep the handle

                JSL KERN_FS_SIZE        ; C = size low, X = size high
                BCS load_shut
                STA @l FS_BLK_N
                STA @l FD_IN.FILESIZE   ; what CMD_LOAD reads back
                TXA
                STA @l FS_BLK_N+2
                STA @l FD_IN.FILESIZE+2

                LDA @l DOS_DST_PTR      ; where it goes
                STA @l FS_BLK_A
                LDA @l DOS_DST_PTR+2
                AND #$00FF
                STA @l FS_BLK_A+2

                LDA #<>FS_BLK
                LDX #`FS_BLK
                JSL KERN_FS_READ
                BCS load_shut

                LDA @l FS_BLK_H         ; success: close and report it
                JSL KERN_FS_CLOSE
                PLY
                PLX
                PLB
                PLP
                SEC
                RTL

load_shut       LDA @l FS_BLK_H         ; failed with the file open
                JSL KERN_FS_CLOSE
load_fail       PLY
                PLX
                PLB
                PLP
                CLC
                RTL

;
; Save a range of memory to a file, truncating any existing one.
;
; Inputs:
;   FD_IN.PATH   = 24-bit pointer to a NUL-terminated path
;   DOS_SRC_PTR  = first byte to write
;   DOS_END_PTR  = LAST byte to write, inclusive
;
; Outputs:
;   C set on success, clear on failure
;
FK_SAVE         PHP
                setaxl
                PHB
                PHX
                PHY

                LDA @l FD_IN.PATH+2     ; C:X = path, Y = mode. LDX has no
                TAX                     ;  long addressing mode, so the bank
                LDA @l FD_IN.PATH       ;  goes through A
                LDY #KFS_WRITE
                JSL KERN_FS_OPEN
                BCS save_fail
                STA @l FS_BLK_H

                SEC                     ; count = END - SRC + 1
                LDA @l DOS_END_PTR
                SBC @l DOS_SRC_PTR
                STA @l FS_BLK_N
                LDA @l DOS_END_PTR+2
                SBC @l DOS_SRC_PTR+2
                AND #$00FF
                STA @l FS_BLK_N+2

                LDA @l FS_BLK_N         ; the +1: DOS_END_PTR is inclusive
                INC A
                STA @l FS_BLK_N
                BNE save_addr
                LDA @l FS_BLK_N+2
                INC A
                STA @l FS_BLK_N+2

save_addr       LDA @l DOS_SRC_PTR
                STA @l FS_BLK_A
                LDA @l DOS_SRC_PTR+2
                AND #$00FF
                STA @l FS_BLK_A+2

                LDA #<>FS_BLK
                LDX #`FS_BLK
                JSL KERN_FS_WRITE
                BCS save_shut

                LDA @l FS_BLK_H
                JSL KERN_FS_CLOSE
                PLY
                PLX
                PLB
                PLP
                SEC
                RTL

save_shut       LDA @l FS_BLK_H
                JSL KERN_FS_CLOSE
save_fail       PLY
                PLX
                PLB
                PLP
                CLC
                RTL

;
; Foenix entry points still unbound. CLC, because these report success
; with the carry SET: the previous stub returned SEC and so told dos.s
; that every directory listing, delete and copy had worked -- after
; which CMD_DIR printed whatever was in the entry buffer. Refusing is
; the honest answer until each is written.
;
FK_STUB         CLC
                RTL

FK_RUN = FK_STUB
FK_DELETE = FK_STUB
FK_COPY = FK_STUB
FK_DIROPEN = FK_STUB
FK_DIRNEXT = FK_STUB
FK_DIRREAD = FK_STUB
FK_DIRWRITE = FK_STUB

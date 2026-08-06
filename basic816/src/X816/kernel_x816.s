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
FK_DIRREAD = FK_STUB
FK_DIRWRITE = FK_STUB

COPY_CHUNK = 512                ; CLUSTER_BUFF is exactly this big

;
; Copy a file.
;
; Inputs:
;   DOS_STR1_PTR = source path, DOS_STR2_PTR = destination path
;
; The C256 kernel had a copy call; this one does not, and rightly -- a
; copy is a read loop and a write loop with a buffer, and the kernel has
; no idea which buffer a program can spare. CLUSTER_BUFF is the obvious
; one here: dos.s allocates 512 bytes of it for the C256 kernel's
; cluster I/O, and nothing on this platform uses it for that.
;
; Two files are open at once, which the kernel's handle pool allows.
;
FK_COPY         PHP
                setaxl
                PHB
                PHX
                PHY

                LDA #0
                STA @l COPY_HS
                STA @l COPY_HD

                LDA @l DOS_STR1_PTR+2   ; Open the source for reading
                TAX
                LDA @l DOS_STR1_PTR
                LDY #KFS_READ
                JSL KERN_FS_OPEN
                BCC copy_src_ok
                BRL copy_fail
copy_src_ok     STA @l COPY_HS

                LDA @l DOS_STR2_PTR+2   ; Create (or truncate) the destination
                TAX
                LDA @l DOS_STR2_PTR
                LDY #KFS_WRITE
                JSL KERN_FS_OPEN
                BCC copy_dst_ok
                BRL copy_shut
copy_dst_ok     STA @l COPY_HD

copy_loop       LDA @l COPY_HS          ; Fill the buffer
                STA @l FS_BLK_H
                LDA #<>CLUSTER_BUFF
                STA @l FS_BLK_A
                LDA #`CLUSTER_BUFF
                AND #$00FF
                STA @l FS_BLK_A+2
                LDA #COPY_CHUNK
                STA @l FS_BLK_N
                LDA #0
                STA @l FS_BLK_N+2
                LDA #<>FS_BLK
                LDX #`FS_BLK
                JSL KERN_FS_READ
                BCC copy_read_ok
                BRL copy_shut
copy_read_ok    CMP #0
                BEQ copy_done           ; A short read of nothing is the end
                STA @l COPY_N

                LDA @l COPY_HD          ; Write exactly what came back
                STA @l FS_BLK_H
                LDA @l COPY_N
                STA @l FS_BLK_N
                LDA #0
                STA @l FS_BLK_N+2
                LDA #<>FS_BLK
                LDX #`FS_BLK
                JSL KERN_FS_WRITE
                BCC copy_wrote
                BRL copy_shut
copy_wrote      CMP @l COPY_N           ; A short write means the card is full
                BEQ copy_loop
                BRL copy_shut

copy_done       LDA @l COPY_HD
                JSL KERN_FS_CLOSE
                LDA @l COPY_HS
                JSL KERN_FS_CLOSE
                PLY
                PLX
                PLB
                PLP
                SEC
                RTL

copy_shut       LDA @l COPY_HD          ; Close whichever ones got opened
                BEQ copy_shut_src
                JSL KERN_FS_CLOSE
copy_shut_src   LDA @l COPY_HS
                BEQ copy_fail
                JSL KERN_FS_CLOSE
copy_fail       PLY
                PLX
                PLB
                PLP
                CLC
                RTL

;
; Delete a file.
;
; Inputs:
;   DOS_PATH_BUFF holds the name -- NOT FD_IN.PATH. S_DEL calls
;   COPY2PATHBUF rather than SETFILEDESC, so the two disk statements set
;   their path up in different places; reading the descriptor here gave
;   a stale pointer and "Unable to delete file" on a file that existed.
;
FK_DELETE       PHP
                setaxl
                PHB
                PHX
                PHY

                LDA #`DOS_PATH_BUFF
                TAX
                LDA #<>DOS_PATH_BUFF
                JSL KERN_FS_DELETE
                BCS del_fail

                PLY
                PLX
                PLB
                PLP
                SEC
                RTL
del_fail        PLY
                PLX
                PLB
                PLP
                CLC
                RTL

;
; Open a directory and produce its first entry.
;
; CMD_DIR walks RAW FAT32 directory records: it reads DOS_DIR_PTR as a
; pointer to a 32-byte on-disk DIRENTRY and picks out the 8.3 name, the
; attribute byte and the size. The kernel does not deal in those -- it
; returns a cooked record, a NUL-terminated "FOO.BAS" with a directory
; flag and a size. So one is built from the other in DIRREAD1 below.
;
; CMD_DIR also never closes the directory, and the kernel's handle pool
; is small, so the handle is closed here at the end of a listing and any
; leftover one is closed before opening the next.
;
; Inputs:
;   FD_IN.PATH = path, or 0 for "the current directory"
;
; Outputs:
;   C set and DOS_DIR_PTR pointing at the first entry, or C clear
;
FK_DIROPEN      PHP
                setaxl
                PHB
                PHX
                PHY

                LDA @l KDIR_H           ; Close a listing left half-read
                BEQ dopen_ptr
                JSL KERN_DIR_CLOSE
                LDA #0
                STA @l KDIR_H

dopen_ptr       LDA #<>FDIRENT          ; Point dos.s at the entry we build
                STA @l DOS_DIR_PTR
                LDA #`FDIRENT
                STA @l DOS_DIR_PTR+2

                LDA @l FD_IN.PATH       ; A null path means the default
                ORA @l FD_IN.PATH+2     ;  directory. An EMPTY STRING is how
                BNE dopen_arg           ;  the kernel spells that: abspath
                LDA #`dir_here          ;  copies the working directory when
                TAX                     ;  the argument does not start "/".
                LDA #<>dir_here
                BRA dopen_go
dopen_arg       LDA @l FD_IN.PATH+2
                TAX
                LDA @l FD_IN.PATH
dopen_go        JSL KERN_DIR_OPEN
                BCS dopen_fail
                STA @l KDIR_H

                JSR DIRREAD1            ; First entry, if there is one
                BCC dopen_fail
                PLY
                PLX
                PLB
                PLP
                SEC
                RTL

dopen_fail      PLY
                PLX
                PLB
                PLP
                CLC
                RTL

dir_here        .byte 0                 ; the empty path; never executed

;
; Step to the next directory entry.
;
; Outputs:
;   C set if an entry was produced, clear at the end of the listing
;
FK_DIRNEXT      PHP
                setaxl
                PHB
                PHX
                PHY

                JSR DIRREAD1
                BCC dnext_end
                PLY
                PLX
                PLB
                PLP
                SEC
                RTL
dnext_end       PLY
                PLX
                PLB
                PLP
                CLC
                RTL

;
; Read one entry and translate it into FDIRENT.
; Assumes 16-bit A/X/Y. C set if an entry was produced.
;
DIRREAD1        LDA @l KDIR_H
                BNE dr_have             ; No listing open: nothing to read
                CLC
                RTS

dr_have         LDX #<>KDIR_ENT         ; C = handle, X:Y = entry buffer
                LDY #`KDIR_ENT
                JSL KERN_DIR_NEXT
                BCC dr_got              ; Carry set = no more entries; the
                BRL dr_close            ;  translation below is too long to
                                        ;  branch across
dr_got          PHB                     ; The copies below use plain indexed
                setas                   ;  addressing, which goes through DBR
                LDA #0
                PHA
                PLB

                LDX #0                  ; Blank the whole 8.3 field: a short
                LDA #' '                ;  name is space-padded, not
dr_blank        STA FDIRENT,X           ;  NUL-padded
                INX
                CPX #11
                BNE dr_blank

                LDX #0                  ; Name, up to the dot, into bytes 0-7
                LDY #0
                LDA KDIR_NAME           ; "." and ".." are entries in every
                CMP #'.'                ;  subdirectory, and their dots are
                BNE dr_name             ;  the NAME, not a separator -- split
dr_dots         LDA KDIR_NAME,X         ;  them and ".." lists as "." and "."
                BEQ dr_attr             ;  as nothing at all
                CPY #8
                BEQ dr_attr
                STA FDIRENT,Y
                INY
                INX
                CPX #13
                BNE dr_dots
                BRA dr_attr

dr_name         LDA KDIR_NAME,X
                BEQ dr_attr
                CMP #'.'
                BEQ dr_dot
                CPY #8
                BEQ dr_skip             ; Longer than 8: drop the excess
                STA FDIRENT,Y
                INY
dr_skip         INX
                CPX #13
                BNE dr_name
                BRA dr_attr

dr_dot          INX                     ; Extension into bytes 8-10
                LDY #8
dr_ext          LDA KDIR_NAME,X
                BEQ dr_attr
                CPY #11
                BEQ dr_attr
                STA FDIRENT,Y
                INY
                INX
                CPX #13
                BNE dr_ext

dr_attr         LDA KDIR_ISDIR
                BEQ dr_file
                LDA #DOS_ATTR_DIR
                BRA dr_setattr
dr_file         LDA #DOS_ATTR_ARCH
dr_setattr      STA FDIRENT+DIRENTRY.ATTRIBUTE

                LDA #0                  ; Times, dates and clusters: CMD_DIR
                LDX #DIRENTRY.IGNORED1  ;  reads none of them (its date and
dr_zero         STA FDIRENT,X           ;  time prints are commented out)
                INX
                CPX #DIRENTRY.SIZE
                BNE dr_zero

                setal
                LDA KDIR_SIZE
                STA FDIRENT+DIRENTRY.SIZE
                LDA KDIR_SIZE+2
                STA FDIRENT+DIRENTRY.SIZE+2

                PLB
                SEC
                RTS

dr_close        LDA @l KDIR_H           ; End of listing: give the handle back
                JSL KERN_DIR_CLOSE
                LDA #0
                STA @l KDIR_H
dr_end          CLC
                RTS

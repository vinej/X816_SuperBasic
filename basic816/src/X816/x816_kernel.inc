;;;
;;; X816 kernel ABI constants
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; Derived from the normative contract in X816_core/tools/contract.py
;;; (see X816_core/doc/KERNEL.md). Do not edit values here without
;;; checking them against the contract.
;;;
;;; ABI: reach every entry with JSL, return is RTL. Entry must be in
;;; native mode with M=0, X=0 (16-bit A/X/Y). Up to three 16-bit args in
;;; C, X, Y; a 24-bit pointer is C = low 16 bits, X low byte = bank.
;;; Carry clear = success (result in C); carry set = failure (KERR in C).
;;; The kernel preserves only D and DBR. Bank-0 bytes $0022-$0031 are
;;; kernel scratch and are NOT preserved across calls.
;;;

KERN_TABLE      = $00FE00           ; 64 entries x 4 bytes (jmp long)

KERN_CON_PUTC   = KERN_TABLE + 0*4  ; C = character ($08 BS, $0A LF, $0D CR)
KERN_CON_PUTS   = KERN_TABLE + 1*4  ; C:X = 24-bit ptr, NUL-terminated
KERN_CON_GETC   = KERN_TABLE + 2*4  ; -> C = key event, blocking
KERN_CON_GETKEY = KERN_TABLE + 3*4  ; -> C = key event or 0, non-blocking
KERN_CON_CLS    = KERN_TABLE + 4*4
KERN_CON_GOTOXY = KERN_TABLE + 5*4  ; C = column, X = row
KERN_CON_GETXY  = KERN_TABLE + 6*4  ; -> C = column, X = row
KERN_CON_PUTRAW = KERN_TABLE + 7*4  ; C = col, X = row, Y = glyph
KERN_CON_CURSOR = KERN_TABLE + 8*4  ; C = 1 blink, 0 off
KERN_CON_COLOR  = KERN_TABLE + 9*4  ; C = fg, X = bg (0-15)

KERN_FS_OPEN    = KERN_TABLE + 16*4
KERN_FS_CLOSE   = KERN_TABLE + 17*4
KERN_FS_READ    = KERN_TABLE + 18*4
KERN_FS_WRITE   = KERN_TABLE + 19*4
KERN_FS_SEEK    = KERN_TABLE + 20*4
KERN_FS_SIZE    = KERN_TABLE + 21*4
KERN_FS_DELETE  = KERN_TABLE + 22*4
KERN_FS_RENAME  = KERN_TABLE + 23*4
KERN_DIR_OPEN   = KERN_TABLE + 24*4
KERN_DIR_NEXT   = KERN_TABLE + 25*4
KERN_DIR_CLOSE  = KERN_TABLE + 26*4
KERN_FS_CHDIR   = KERN_TABLE + 27*4
KERN_FS_GETCWD  = KERN_TABLE + 28*4
KERN_FS_MKDIR   = KERN_TABLE + 29*4
KERN_FS_RMDIR   = KERN_TABLE + 30*4

KERN_EXEC       = KERN_TABLE + 32*4 ; C:X = path; no return on success
KERN_EXIT       = KERN_TABLE + 33*4 ; C = status; no return

KERN_MEM_ALLOC  = KERN_TABLE + 40*4 ; C = size lo16, X = size hi16
KERN_MEM_FREE   = KERN_TABLE + 41*4 ; C:X = address

KERN_SYS_VERSION = KERN_TABLE + 48*4
KERN_IRQ_SET    = KERN_TABLE + 49*4 ; C = KIRQ slot, X:Y = handler
KERN_TIME_GET   = KERN_TABLE + 50*4 ; -> C = ms lo16, X = ms hi16
KERN_TIME_SET   = KERN_TABLE + 51*4
KERN_IRQ_FRAMES = KERN_TABLE + 52*4 ; -> C = VSYNC frame count

; Kernel error codes (carry set, code in C)
KERR_NOSYS      = 1
KERR_NOTFOUND   = 2
KERR_NOSPACE    = 3
KERR_BADARG     = 4
KERR_IO         = 5
KERR_EXISTS     = 6
KERR_NOTEMPTY   = 7

; IRQ slots for KERN_IRQ_SET (one per source)
KIRQ_VSYNC      = 0
KIRQ_LINE       = 1
KIRQ_SPRCOL     = 2
KIRQ_AFLOW      = 3
KIRQ_VIA1       = 4
KIRQ_VIA2       = 5
KIRQ_YM         = 6
KIRQ_SPURIOUS   = 7
KIRQ_NMI        = 8
KIRQ_BRK        = 9
KIRQ_COP        = 10

; Key events returned by GETC/GETKEY (16-bit):
;   $0000          nothing waiting (GETKEY only)
;   $0001-$00FF    a CP437/ASCII character
;   $0100 | n      a key with no character; n = IBM key position number
KEY_SPECIAL     = $0100

; VERA registers (bank 0 I/O page), for direct text-matrix reads
VERA_ADDR_L     = $009F20
VERA_ADDR_M     = $009F21
VERA_ADDR_H     = $009F22
VERA_DATA0      = $009F23
VERA_CTRL       = $009F25

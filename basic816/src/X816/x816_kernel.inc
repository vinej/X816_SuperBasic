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

; K_FS_OPEN modes (Y). WRITE creates the file if absent and TRUNCATES it
; if present, which is what SAVE wants and is NOT what an append would.
KFS_READ        = 0
KFS_WRITE       = 1

; K_FS_SEEK takes a parameter block: handle, then a WHENCE byte, then a
; 32-bit offset. It returns the new offset, and refuses a target past the
; end of the file rather than growing it.
KFS_SET         = 0         ; from the beginning
KFS_CUR         = 1         ; from where the file is now
KFS_END         = 2         ; from the end, so a negative offset backs up

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

; Ctrl is reported as a key of its own and never folds into a character:
; the kernel tracks Shift on both edges inside con_getkey, but leaves
; Ctrl/Alt/GUI/CapsLock to the caller ("making Ctrl-C a character is a
; design step, not a mapping one" — X816_Calypsi runtime/console.h). So
; there is no $03 to poll for; FK_TESTBREAK pairs these with the 'C'
; that follows. IBM key positions, per KERNEL.md.
KEY_LCTRL       = KEY_SPECIAL | 58
KEY_RCTRL       = KEY_SPECIAL | 64

; VERA's interrupt registers. Read back, IEN's bit 7 is IRQLINE's ninth
; bit and bit 6 is the CURRENT scanline's ninth bit -- a status bit that
; is not writable -- so a read/modify/write of IEN must mask to $8F or it
; will move the compare line by 256 whenever the beam is past 255.
; ISR is write-1-to-clear, and its bits 7:4 are the sprite collision
; groups rather than more enables.
VERA_IEN        = $009F26
VERA_ISR        = $009F27
VERA_IRQLINE    = $009F28       ; low 8 bits; bit 8 rides in IEN bit 7
VERA_IRQ_VSYNC  = $01
VERA_IRQ_LINE   = $02
VERA_IRQ_SPRCOL = $04
VERA_IRQ_AFLOW  = $08

; VERA registers (bank 0 I/O page), for direct text-matrix reads
VERA_ADDR_L     = $009F20
VERA_ADDR_M     = $009F21
VERA_ADDR_H     = $009F22
VERA_DATA0      = $009F23
VERA_DATA1      = $009F24       ; the SECOND data port. CTRL bit 0 selects
                                ;  which pointer the ADDRESS registers refer
                                ;  to, but DATA0 always steps pointer 0 and
                                ;  DATA1 always steps pointer 1 -- so a VRAM
                                ;  to VRAM copy is a load and a store.
VERA_CTRL       = $009F25       ; bit 0 = data port, bits 1-6 = DCSEL

; Composer and layer registers, verified against the emulator's video.c
; rather than assumed from the X16: the border is reg_composer[3] and
; the layer scroll is reg_layer[0][3..4], of which only the LOW NIBBLE
; of the high byte belongs to the scroll.
VERA_DC_VIDEO   = $009F29       ; DCSEL 0: bit 4 layer0, 5 layer1, 6 sprites
VERA_DC_BORDER  = $009F2C       ; needs DCSEL = 0
VERA_L0_CONFIG  = $009F2D       ; depth 1:0, bitmap 2, 256c text 3, size 7:4
VERA_L0_MAPBASE = $009F2E       ; map address >> 9
VERA_L0_TILEBASE = $009F2F      ; font address >> 11 in 7:2, tile size in 1:0
VERA_L0_HSCR_L  = $009F30
VERA_L0_HSCR_H  = $009F31       ; low nibble only
VERA_L0_VSCR_L  = $009F32
VERA_L0_VSCR_H  = $009F33       ; low nibble only

; SYSCTL, the X816's own control register (MEMORY_MAP.md). Bit 0 is the
; boot-ROM overlay, bit 1 reads the CPU's live E flag, bit 2 is TURBO --
; so anything written here is a read-modify-write, never a store.
SYSCTL          = $009F80

; Structures that live in VRAM rather than in registers, so they are
; reached through the data port like any other video memory.
VERA_PALETTE    = $01FA00       ; 256 entries, 2 bytes each, $0RGB
VERA_SPRATTR    = $01FC00       ; 128 sprites, 8 bytes each
VERA_PSG        = $01F9C0       ; 16 voices, 4 bytes each

; Hz -> PSG frequency register: 2^17 / 48828.125, as IEEE-754 single.
FC_PSGHZ        = $402BCC77     ; 2.68435456

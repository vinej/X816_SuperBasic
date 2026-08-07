;;;
;;; Block assignment for the X816
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The X816 is a flat 16 MB machine: no banking hardware. The kernel
;;; owns $00:2000-$2FFF, the I/O page is $00:9F00, the jump table is at
;;; $00:FE00. Programs load at $01:0000 with the 8-byte "X816" header.
;;; See X816_core/doc/MEMORY_MAP.md for the normative map.
;;;

.include "X816/x816_kernel.inc"

; (Phase 2: all FP coprocessor paths are guarded out on X816 — the
;  software float engine lives in X816/floats_x816.s.)

; The program image: 8-byte header, then code/data, all in banks $01-$04
; (single-cycle BRAM). CALL/RETURN are JSR/RTS, so all code must stay in
; one bank: everything below must fit in bank $01.
* = $010000
.dsection x816hdr

* = $010008
.dsection code
.dsection data
.dsection variables
.cerror * > $01FFFF, "Interpreter does not fit in bank $01"

; The X816 program header: magic + entry jump, exactly 8 bytes
.section x816hdr
            .text "X816"            ; magic checked by the loader
            JML START               ; entry point (called at $01:0004)
.send

; Direct-page globals: $00:3000 (page-aligned per MEMORY_MAP.md D rule).
; Must contain only uninitialized (?) entries so no binary output is
; emitted below $01:0000 (the header must stay at file offset 0).
* = $003000
.dsection globals
.cerror * > $30FF, "Too many direct page variables"

BASIC_BANK = $00            ; Default data bank (kernel convention: DBR=0)

; Bank 0 memory spaces (application window is $3000-$9DFF)

; Console text color, C256 layout (high nibble fg, low nibble bg).
; On the C256 screen.s writes this into the color matrix beside every
; glyph; the X816 console owns its own attributes, so this is only a
; shadow -- SCREEN_PUTC does not consult it. Real color changes go out
; through TEXTCOLOR -> KERN_CON_COLOR (statements_x816.s). It exists
; because the unit-test framework (tests/unittests.s) stores into it
; directly to color PASSED/FAILED lines.
;
; Sits above the software math scratch, which owns $4B00-$4B19:
; MATHR $4B00-$4B07 (ints_x816.s), FP_S1..FP_M2 $4B08-$4B17 and
; FP_T $4B18-$4B19 (floats_x816.s).
CURCOLOR = $004B1A          ; 1 byte

; Set when the last key event was Ctrl, so FK_TESTBREAK can recognise the
; 'C' that follows as a break. Lives here rather than in the direct page
; because FK_TESTBREAK is reached by JSL from anywhere and reads it with
; long addressing.
CTRL_DOWN = $004B1B         ; 1 byte

; Parameter block for K_FS_READ / K_FS_WRITE. Calls taking more than three
; arguments are passed a 24-bit pointer to little-endian fields
; (KERNEL.md 5.3); reserved fields must be written as zero.
FS_BLK    = $004B20         ; 10 bytes
FS_BLK_H  = FS_BLK + 0      ; word  - file handle
FS_BLK_A  = FS_BLK + 2      ; dword - address to read into / write from
FS_BLK_N  = FS_BLK + 6      ; dword - byte count

; Directory listing. The kernel hands back a COOKED entry and dos.s wants
; a RAW on-disk FAT32 one, so FK_DIRNEXT translates between the two.
KDIR_H    = $004B2C         ; word - open directory handle, 0 = none
KDIR_ENT  = $004B30         ; 18 bytes - what K_DIR_NEXT fills in:
KDIR_NAME = KDIR_ENT + 0    ;   13 bytes - NUL-terminated name, "FOO.BAS"
KDIR_ISDIR = KDIR_ENT + 13  ;   byte     - 1 if a directory
KDIR_SIZE = KDIR_ENT + 14   ;   dword    - size in bytes
FDIRENT   = $004B50         ; 32 bytes - a DIRENTRY built from the above

; Working values for FP_SQR's Newton iteration.
FP_SX     = $004B70         ; dword - the operand
FP_SY     = $004B74         ; dword - the running estimate

; FK_COPY holds two files open at once and streams between them.
COPY_HS   = $004B78         ; word - source handle, 0 = closed
COPY_HD   = $004B7A         ; word - destination handle, 0 = closed
COPY_N    = $004B7C         ; word - bytes in the chunk being moved

; Working values for the trigonometric range reduction.
FP_TX     = $004B80         ; dword - the original argument
FP_TR     = $004B84         ; dword - the reduced argument, in [-pi/4, pi/4]
FP_TU     = $004B88         ; dword - r*r, what the polynomials are in
FP_TS     = $004B8C         ; dword - TAN's numerator
FP_TC     = $004B90         ; dword - TAN's denominator
FP_TQ     = $004B94         ; word  - quadrant, 0-3

; Working values for LN and EXP.
FP_EX     = $004B98         ; dword - the argument, then the reduced value
FP_EU     = $004B9C         ; dword - what the polynomial is evaluated in
FP_EN     = $004BA0         ; word  - the power of two taken out, signed

; Working values for the inverse trigonometry.
FP_AY     = $004BA4         ; dword - the constant the reduction adds back
FP_AV     = $004BA8         ; dword - the untouched argument
FP_ASGN   = $004BAC         ; word  - sign of the argument, $8000 negative

; WAIT and VSYNC.
WAIT_T    = $004BB0         ; dword - the millisecond count to wait for
WAIT_N    = $004BB4         ; dword - scratch: the interval, or the frame

; VRAM access and the layer registers.
VID_A     = $004BB8         ; dword - a VRAM address, or a scratch byte

; Record I/O channels (X816/channels_x816.s). The table is four 16-byte
; records; the buffers are a page each and live up at $8000, in the part
; of the application window nothing else had claimed.
; The two pointers a channel is worked through are direct-page globals
; rather than fixed addresses here, because the records and buffers are
; reached as [CHN_P],Y and [CHN_B],Y and only the direct page has that
; addressing mode.
; The scratch pair sits BELOW the table, not above it: four 16-byte
; records fill $4BC0-$4BFF exactly, and putting them at $4BF8 overlaid
; channel 4's own fields.
CHN_W     = $004BBC         ; word  - a byte in transit
CHN_SAVE  = $004BBE         ; word  - BCONSOLE across a redirected PRINT
CHN_TAB   = $004BC0         ; 64 bytes - 4 records of 16, ending at $4BFF
CHN_BUF   = $008000         ; 4 pages, one a channel

; Joystick, I2C and mouse state (X816/input_x816.s). Up here with the
; channel buffers because the scratch page down at $4B00 is full.
JOY_MASK  = $008400         ; byte - which VIA data line this pad is on
JOY_W     = $008402         ; word - the sixteen bits as they shift in
I2C_W     = $008404         ; byte - a sampled data line
I2C_B     = $008406         ; byte - the byte being shifted either way
I2C_ACK   = $008408         ; byte - whether the master will acknowledge
I2C_DEV   = $00840A         ; byte - device address, not yet shifted
I2C_REG   = $00840C         ; byte - register within the device
MOUSE_X   = $008410         ; word - accumulated, because the hardware only
MOUSE_Y   = $008412         ;  ever reports movement
MOUSE_B   = $008414         ; byte - button flags from the last packet
MOUSE_D   = $008416         ; 2 bytes - the X and Y steps of one packet
MOUSE_N   = $008418         ; word - which of the three MOUSE() wants

IOBUF = $004C00             ; A buffer for I/O operations
ARRIDXBUF = $004D00         ; The array index buffer used for array references
TEMPBUF = $004E00           ; Temporary buffer for string processing, etc.
INPUTBUF = $004F00          ; Starting address of the line input buffer (one page)
RETURN_BOT = $005000        ; Starting address of the return stack
RETURN_TOP = $005FFF        ; Ending address of the return stack
ARGUMENT_BOT = $006000      ; Starting address of the argument stack
ARGUMENT_TOP = $006FFF      ; Ending address of the argument stack
OPERATOR_BOT = $007000      ; Starting address of the operator stack
OPERATOR_TOP = $007FFF      ; Ending address of the operator stack

STACK_END = $001FFF         ; Top of the CPU stack (kernel gives $0100-$1FFF)

; DOS working storage for dos.s. The C256 kernel put this block at
; $00:0320 (inside the X816's CPU stack), so it is relocated to free
; application space, keeping the C256 layout relative to the base.
; The DOS commands themselves refuse until phase 3 binds K_FS_*.
SDOS_VARIABLES = $004800
BIOS_STATUS      = SDOS_VARIABLES + $00     ; 1 byte  - BIOS op status
DOS_STATUS       = SDOS_VARIABLES + $0E     ; 1 byte  - file access error code
DOS_CLUS_ID      = SDOS_VARIABLES + $10     ; 4 bytes - cluster for a DOS op
DOS_DIR_PTR      = SDOS_VARIABLES + $18     ; 4 bytes - directory entry pointer
DOS_BUFF_PTR     = SDOS_VARIABLES + $1C     ; 4 bytes - cluster read/write pointer
DOS_FD_PTR       = SDOS_VARIABLES + $20     ; 4 bytes - file descriptor pointer
DOS_FAT_LBA      = SDOS_VARIABLES + $24     ; 4 bytes - FAT sector LBA
DOS_TEMP         = SDOS_VARIABLES + $28     ; 4 bytes - temporary storage
DOS_FILE_SIZE    = SDOS_VARIABLES + $2C     ; 4 bytes - file size
DOS_SRC_PTR      = SDOS_VARIABLES + $30     ; 4 bytes - transfer source
DOS_DST_PTR      = SDOS_VARIABLES + $34     ; 4 bytes - transfer destination
DOS_END_PTR      = SDOS_VARIABLES + $38     ; 4 bytes - last byte to save
DOS_RUN_PTR      = SDOS_VARIABLES + $3C     ; 4 bytes - loaded program start
DOS_RUN_PARAM    = SDOS_VARIABLES + $40     ; 4 bytes - program argument string
DOS_STR1_PTR     = SDOS_VARIABLES + $44     ; 4 bytes - string pointer
DOS_STR2_PTR     = SDOS_VARIABLES + $48     ; 4 bytes - string pointer
DOS_SCRATCH      = SDOS_VARIABLES + $4B     ; 4 bytes - short term storage
DOS_PATH_BUFF    = $004900                  ; 256 bytes - path name buffer

; CPU register save area for the monitor (C256 had it at $00:0240,
; inside the X816's CPU stack — relocated with the same layout).
; Nothing populates it yet: the BRK handler needs KERN_IRQ_SET wiring
; (phase 3+) before the monitor's register display means anything.
CPU_REGISTERS    = $004A00
CPUPC            = CPU_REGISTERS + $0       ;2 Bytes Program Counter (PC)
CPUPBR           = CPU_REGISTERS + $2       ;2 Bytes Program Bank Register (K)
CPUA             = CPU_REGISTERS + $4       ;2 Bytes Accumulator (A)
CPUX             = CPU_REGISTERS + $6       ;2 Bytes X Register (X)
CPUY             = CPU_REGISTERS + $8       ;2 Bytes Y Register (Y)
CPUSTACK         = CPU_REGISTERS + $A       ;2 Bytes Stack Pointer (S)
CPUDP            = CPU_REGISTERS + $C       ;2 Bytes Direct Page Register (D)
CPUDBR           = CPU_REGISTERS + $E       ;1 Byte  Data Bank Register (B)
CPUFLAGS         = CPU_REGISTERS + $F       ;1 Byte  Flags (P)

; Non bank 0 memory spaces

LOADBLOCK = $050000         ; File loading will start here (SDRAM; phase 3)
BASIC_BOT := $020000        ; Starting point for BASIC programs (BRAM)
HEAP_TOP := $04FFFF         ; Top of the heap (end of BRAM)

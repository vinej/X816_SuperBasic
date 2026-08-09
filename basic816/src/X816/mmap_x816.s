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

; VRAM access and the layer registers. EIGHT bytes, not four: sprites,
; tiles and the FM code all use VID_A+4 through VID_A+7 as working
; space, so $4BB8-$4BBF is one region and nothing else may live in it.
; The channel scratch was briefly put at $4BBC and aliased all of it.
VID_A     = $004BB8         ; 8 bytes - a VRAM address, then scratch

; Record I/O channels (X816/channels_x816.s). The table is four 16-byte
; records; the buffers are a page each and live up at $8000, in the part
; of the application window nothing else had claimed.
; The two pointers a channel is worked through are direct-page globals
; rather than fixed addresses here, because the records and buffers are
; reached as [CHN_P],Y and [CHN_B],Y and only the direct page has that
; addressing mode.
; Four 16-byte records fill $4BC0-$4BFF exactly, so the scratch pair
; cannot go above the table (it landed on channel 4) and cannot go below
; it either (that is VID_A's tail, see above). It lives up at $8400 with
; the rest of the newer state.
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

; Working storage for the no-argument-function rule in tokens.s.
PREVEXT   = $00841A         ; byte - PREVCHAR returned an extended sub-id
TKPF_W    = $00841C         ; word - the token id being asked about
TKPF_R    = $00841E         ; byte - the answer, on its way to the carry
CHN_W     = $008420         ; word - a byte in transit through a channel
CHN_SAVE  = $008422         ; word - BCONSOLE across a redirected PRINT
CHN_SEEKTO = $0084AC        ; dword - where SEEK is going, kept across the
                            ;  flush that has to happen first
FNT_CODE  = $008424         ; word - the glyph GLYPH is redefining
FNT_ROWS  = $008426         ; 8 bytes - its scanlines, collected before the
                            ;  VRAM port is pointed anywhere

; Bitmap drawing (X816/graphics_x816.s). All signed 16-bit: a negative
; coordinate has to survive the arithmetic so that a line running off
; the edge is clipped rather than wrapped.
GX        = $008430         ; word - the pixel being drawn, or a line cursor
GY        = $008432
GX1       = $008434         ; word - the far end of a line
GY1       = $008436
GDX       = $008438         ; word - the deltas, dy carried NEGATIVE
GDY       = $00843A
GSX       = $00843C         ; word - the step, +1 or -1
GSY       = $00843E
GERR      = $008440         ; word - the running error
GE2       = $008442         ; word - twice it
GCOL      = $008444         ; word - the pen
GT        = $008446         ; word - y*5, on the way to y*640
GOFF      = $008448         ; word - the pixel's offset within its bank
GBANK     = $00844A         ; word - and which bank that is, $E0 to $E4

; dos.s dumps a line of memory through this. It was 17 bytes of direct
; page, which is a page of 256 that everything else is short of.
MLINEBUF  = $008450         ; 17 bytes

; Deferred interrupt handlers (X816/irq_x816.s). ARMED and BUSY are
; adjacent and in that order ON PURPOSE: IRQ_POLL runs before EVERY
; statement, and its fast path -- nothing armed, nothing running -- is
; then a single 16-bit read of IRQ_STATE and a branch.
IRQ_STATE = $008460         ; word - both bytes below, read at once
IRQ_ARMED = $008460         ; byte - non-zero if any handler is armed
IRQ_BUSY  = $008461         ; byte - a handler is running: the re-entry guard
IRQ_VLINE = $008462         ; word - ONVSYNC's line number, 0 = disarmed
IRQ_RLINE = $008464         ; word - ONRASTER's
IRQ_CLINE = $008466         ; word - ONCOLLISION's
IRQ_FRAME = $008468         ; word - frame count at the last VSYNC tick
; Bulk transfers between VRAM and the card (X816/vramio_x816.s).
; The staging buffer is SDRAM and deliberately far above LOADBLOCK
; ($05:0000), which CMD_LOAD fills with program text: a TILELOAD in a
; running program must not land on the buffer its own source came
; through. 128 KB of room, which is a 256x256 tilemap, the largest
; single object any of these statements can move.
; The four slots have ONE meaning each and keep it. An earlier draft let
; VIO_T mean "the offset", "the byte count" and "the sprite number" in
; the same routine, and the unshifted address then read its own result.
VIO_VA    = $008480         ; 4 bytes - VRAM address of the transfer
VIO_N     = $008484         ; 4 bytes - bytes STILL to move; counts to zero
VIO_T     = $008488         ; 4 bytes - the transfer's LENGTH, for a save
VIO_U     = $00848C         ; 4 bytes - per-statement scratch
VIO_V     = $008490         ; 4 bytes - per-statement scratch
VIO_STAGE = $080000         ; the staging buffer itself

; Controllers. One pass of the shift register fills all of this, because
; all four pads shift out together on their own data lines -- reading
; one pad and reading four cost the same.
JOY_P     = $008494         ; 8 bytes - the four pads, buttons active HIGH
JOY_H     = $00849C         ; byte - the eight clocks AFTER the sixteen,
                            ;  ORed together. A present pad keeps shifting
                            ;  ZEROS; an absent line floats HIGH. Bit 7-n
                            ;  set means pad n did not answer.
JOY_C     = $00849E         ; byte - which bit the scan is on
; JOYX/JOYY need somewhere to park two masks and a value ACROSS a scan,
; so these cannot be JOY_W -- the scan uses that for the port byte on
; every one of its twenty-four passes. (JOY_W+2 would also have been
; I2C_W: the older block is packed two bytes apart.)
JOY_MN    = $0084A4         ; word - the mask for the negative direction
JOY_MP    = $0084A6         ; word - and for the positive one
JOY_V     = $0084A8         ; word - the pad reading being tested
; The byte an I2C WRITE is carrying. It cannot be I2C_B: that is
; I2C_TXBYTE's shift register, and it is left at zero by every byte that
; goes out -- so a value parked there before the address and register
; were sent arrived as 0. I2CPOKE wrote zeros and nothing said so.
I2C_V     = $0084AA         ; byte

; Audio. The YM2151 answers no reads at all -- its status register is
; timer and busy flags and nothing else -- so YMPEEK can only be a
; SHADOW of what was written, and every write goes through YM_POKE to
; keep it.
YM_SHADOW = $008600         ; 256 bytes - the last value written to each
FM_BANK   = $008700         ; 256 bytes - eight instrument patches of 32
FM_BANKED = $008800         ; byte - non-zero once FMLOAD replaced them

; The PCM feeder. PCM_PTR itself is a DIRECT PAGE variable (memorymap.s)
; because the interrupt handler dereferences it, and [ptr] addressing
; exists nowhere else.
PCM_LEN   = $008802         ; dword - sample bytes still to be fed
PCM_ON    = $008806         ; byte - the AFLOW handler is installed

; Scratch for the audio code. NOT VID_A: that region is exactly EIGHT
; bytes and the note beside it says so -- VID_A+8 is the record I/O
; channel table, and a patch loop that ran off the end of it would break
; OPEN rather than FMINST.
AUD_T     = $008830         ; 16 bytes

; PSG volume envelopes (X816/psgenv_x816.s). ENV_TAB is sixteen bytes a
; voice for sixteen voices, laid out in the header of that file; the
; index into it is voice*16 so that it is four shifts and no multiply.
;
; ENV_A through ENV_R park ENV's five arguments across the EVALEXPRs
; that read them, for the reason spelled out beside IRQ_TMP: an
; expression can call a function that uses VID_A, so the arguments
; cannot live there.
ENV_ANY   = $008840         ; byte - any voice armed. IRQ_REARM folds this
                            ;  into IRQ_ARMED, so an armed envelope costs
                            ;  a running program what an armed ONVSYNC does
ENV_FRAME = $008842         ; word - the kernel frame count at the last tick
ENV_N     = $008844         ; word - frames still to apply, this poll
ENV_P     = $008846         ; word - the voice being worked on, as voice*16
ENV_TGT   = $008848         ; word - the level the phase is walking towards
ENV_TMP   = $00884A         ; word - scratch inside one step
ENV_NOW   = $00884C         ; word - the frame count just read
ENV_SV    = $00884E         ; word - SOUND's voice, kept across the two
                            ;  EVALEXPRs after it
ENV_V     = $008858         ; word - ENV's voice, likewise. NOT ENV_P: the
                            ;  frame tick WRITES that one as its loop
                            ;  counter, and ENV parks its voice across four
                            ;  more expressions -- so the two would alias
                            ;  the day anything let a tick in mid-statement
ENV_A     = $008850         ; word - ENV's attack, in frames
ENV_D     = $008852         ; word - its decay
ENV_S     = $008854         ; word - its sustain, which is a LEVEL
ENV_R     = $008856         ; word - its release
ENV_TAB   = $008900         ; 256 bytes - sixteen voices of sixteen

; IMA ADPCM (X816/adpcm_x816.s). The two cursors the decoder runs on are
; NOT here: they are MTEMP and PCM_PTR, both direct page, because [ptr]
; addressing exists nowhere else -- and both are borrowed rather than
; new, MTEMP being the staging cursor VIO_LOAD has finished with and
; PCM_PTR being where the decoded audio has to end up anyway.
ADP_PRED  = $008860         ; word - the predictor, signed 16-bit
ADP_IDX   = $008862         ; word - the step index, 0-88
ADP_STEP  = $008864         ; word - step_table[index]
ADP_DIFF  = $008866         ; word - what this nibble moves the predictor
ADP_NIB   = $008868         ; word - the nibble being decoded, 0-15
ADP_IN    = $00886A         ; dword - compressed bytes still to read
ADP_OUTN  = $00886E         ; dword - decoded bytes written
ADP_BLK   = $008872         ; word - IMA block size, 0 = one raw stream
ADP_BLKN  = $008874         ; word - data bytes left in this block
ADP_RATE  = $008876         ; dword - sample rate out of a WAV header, 0
                            ;  if the file did not say and PCMRATE stands
ADP_T     = $00887A         ; 8 bytes - the 32-bit clamp, and the chunk
                            ;  walk's length and bytes-remaining

; Fast game maths (X816/fastmath_x816.s). Not VID_A and not ARGUMENT*:
; every one of these has to survive an EVALEXPR, because the functions
; take two and three arguments and an expression can call a function
; that uses either -- the same rule the note beside IRQ_TMP sets out.
ADV_A     = $008884         ; dword - the first argument, kept
ADV_B     = $008888         ; dword - the second
ADV_DX    = $00888C         ; word - ATAN2's arguments, and
ADV_DY    = $00888E         ; word -  their absolute values
ADV_AX    = $008890         ; word
ADV_AY    = $008892         ; word
ADV_NUM   = $008894         ; word - the smaller of the two, and
ADV_DEN   = $008896         ; word -  the larger: the ratio's terms
ADV_FLIP  = $008898         ; word - non-zero in the steep half, where the
                            ;  answer is 64 minus the table's
ADV_T     = $00889A         ; word - the angle being assembled, and LERP's
                            ;  fraction

; Shapes on the bitmap (X816/shapes_x816.s). GX/GY/GCOL and the rest of
; the line drawing block above are shared; these are what a rectangle,
; a circle and an ellipse need on top of them.
GRX0      = $0088A0         ; word - the rectangle's corners, put in order
GRY0      = $0088A2         ;  by GFX_RORDER so either way round works
GRX1      = $0088A4
GRY1      = $0088A6
GHX0      = $0088A8         ; word - a horizontal span's two ends
GHX1      = $0088AA
GCX       = $0088AC         ; word - a circle's centre
GCY       = $0088AE
GCR       = $0088B0         ; word - its radius
GCDX      = $0088B2         ; word - the octant walk's offsets
GCDY      = $0088B4
GCE       = $0088B6         ; word - the midpoint error term
GCSPAN    = $0088B8         ; word - non-zero to FILL rather than outline
GOA       = $0088BA         ; word - the ellipse's semi-axes, and
GOB       = $0088BC
GOA2      = $0088BE         ;  their squares, computed once
GOB2      = $0088C0

; MEMCOPY (X816/statements_x816.s). The SOURCE cursor is MTEMP, not one
; of these: [ptr] addressing exists only in the direct page and MTEMP is
; the scratch pointer that is already there.
MC_S      = $0088C4         ; dword - where the copy reads from
MC_D      = $0088C8         ; dword - and writes to; its bank goes to DBR
MC_N      = $0088CC         ; dword - bytes still to move, counts to zero

; The soft clock (X816/clock_x816.s). The date is CARRIED rather than
; derived: there is no RTC, so SETDATE records a date and the day number
; the millisecond counter was on, and GETDATE$ adds the midnights since.
CLK_Y     = $0088D0         ; word - the year last set, 0 until SETDATE
CLK_M     = $0088D2         ; word - month 1-12
CLK_D     = $0088D4         ; word - day 1-31
CLK_BASE  = $0088D6         ; word - the day number SETDATE recorded
CLK_DSET  = $0088D8         ; word - non-zero once SETDATE has been used
CLK_T     = $0088DA         ; dword - the counter, then each remainder
CLK_U     = $0088DE         ; dword - the divisor of the moment
CLK_ACC   = $0088E2         ; dword - milliseconds being assembled
CLK_V     = $0088E6         ; word - a value being formatted or parsed
CLK_W     = $0088E8         ; word - scratch beside it
CLK_X     = $0088EA         ; word - and one more, for the times-ten
CLK_N     = $0088EC         ; word - how much of the string is built
CLK_R     = $0088EE         ; word - midnights still to walk forward. NOT
                            ;  CLK_W: CLK_MLEN uses that as its own
                            ;  scratch, and the roll loop calls it

; PLAY's parser state.
PLY_P     = $008810         ; dword - where it is in the string
PLY_N     = $008814         ; word - characters left
PLY_OCT   = $008816         ; byte - current octave, 0-7
PLY_LEN   = $008818         ; byte - default note length: 1, 2, 4 ... 32
PLY_TEMPO = $00881A         ; word - quarter notes a minute
PLY_WHOLE = $00881C         ; dword - milliseconds in a whole note
PLY_MS    = $008820         ; dword - and in the note being played
PLY_NOTE  = $008824         ; word - the note number being assembled
PLY_CH    = $008826         ; byte - which FM channel it plays on

; GTEXT and FILL (X816/gfx2_x816.s). ABOVE ENV_TAB, which owns
; $8900-$89FF: the first draft put these inside it, and drawing a string
; would have quietly rewritten the PSG envelope of every voice.
GFT       = $008A00         ; word - the pixel GFX_PGET read back
GTX0      = $008A02         ; word - where the next glyph goes
GTY0      = $008A04
GTC       = $008A06         ; word - the character being drawn
GTB       = $008A08         ; dword - the address of its eight scanlines
GTROW     = $008A0C         ; 8 bytes - and the scanlines themselves
GTR       = $008A14         ; word - which of the eight is being drawn
GTCOL     = $008A16         ; word - and which bit of it
GTBITS    = $008A18         ; word - the row, shifted left as it is walked

; The flood fill's seed stack. One seed a RUN, not a pixel: 256 of them
; is a screen of rows twice over, and a shape convoluted enough to want
; more leaves part of itself unfilled rather than running past the end.
FIL_MAX   = 256
FIL_SP    = $008A1A         ; word - seeds on the stack
FIL_OLD   = $008A1C         ; word - the colour being replaced
FIL_X1    = $008A1E         ; word - the run being filled
FIL_X2    = $008A20
FIL_Y     = $008A22         ; word - its row, kept across the two scans
FIL_IN    = $008A24         ; word - is the scan inside a run right now
FIL_SX    = $008A26         ; word - the seed the statement was given
FIL_SY    = $008A28
FIL_STK   = $008B00         ; 1 KB - FIL_MAX entries of (x, y)

; Mouse extras.
MOUSE_WH  = $0084A0         ; word - wheel movement, signed, cleared by a read
MOUSE_PK  = $0084A2         ; byte - bytes in one movement packet: 3, or 4
                            ;  once the SMC has been asked for a wheel mouse

IRQ_TMP   = $00846A         ; 4 bytes - scratch across an EVALEXPR. NOT
                            ;  VID_A, which an expression can reach: the
                            ;  scanline in "ONRASTER VPEEK(A),100" would
                            ;  be overwritten by the function that
                            ;  produced it.

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

#!/usr/bin/env bash
# Boot SuperBasic on the X816 emulator and type at the REPL.
#
# The whole stack is under test at once: the resident kernel boots from
# the firmware region, its shell EXECs BASIC.BIN off a real FAT32 card,
# BASIC comes up on the kernel console, and every keystroke travels the
# real SMC path (-autokeys).
#
# TWO SESSIONS, and that is deliberate. The console is 80x60 and one
# combined session outgrew it, at which point the greeting banner had
# scrolled off and the run failed on a check about SCREEN_PUTC. The
# obvious repair -- reconstruct the scrollback from the GIF -- was tried
# and abandoned: unioning frames breaks the checks that COUNT identical
# lines, and stitching them by overlap mis-stitches, because under -warp
# the guest both prints and scrolls between two captures and a capture
# can land mid-redraw. Keeping each session inside one screen removes
# the problem rather than modelling it.
#
#   session A -- the language and the maths
#     1. the greeting banner prints  - the SCREEN_PUTC crossing works
#     2. no READY banner anywhere    - SuperBasic prints none: entering a
#                                      line leaves the cursor at the start
#                                      of the next line and nothing more.
#                                      Asserted as an ABSENCE, so it fails
#                                      if the prompt ever comes back.
#     3. PRINT 1 answers 1           - tokenizer, interpreter, ITOS and
#                                      the software divide (DIVINT10)
#     4. XYZZY answers Syntax error  - the error path
#     5. float maths in direct mode  - the software FP engine, and SQR
#     6. 10 PRINT 1.5 then RUN       - a float literal parsed out of
#                                      STORED program text. Worth its own
#                                      check: PARSENUM counts digits in Y
#                                      and then advances BIP by it, so a
#                                      math routine that clobbers Y sends
#                                      the interpreter into the middle of
#                                      the program. Direct mode hides it
#                                      (the bad pointer lands in INPUTBUF
#                                      and finds a NUL); only RUN shows it.
#
#   session B -- the filesystem, on a real FAT32 card
#     7. SAVE/NEW/LOAD/RUN           - a program survives the round trip
#     8. DIR, DEL, DIR               - counted, so one assertion covers
#                                      three statements and fails from
#                                      either side
#     9. MKDIR/CD/PWD/RMDIR          - the working directory
#    10. RENAME, then COPY           - the copy is LOADed and RUN, so the
#                                      check is that the bytes arrived,
#                                      not merely that a file appeared
#
#   session F -- interrupts, and BRUN
#    11. IRQ 1,addr                 - a handler POKEd in as seven bytes of
#                                     machine code, which STORES A CONSTANT
#                                     the BASIC side never computes. The
#                                     word reads 0 before and 4660 after,
#                                     so the check cannot pass on leftover
#                                     memory
#    12. BRUN "T.BIN",addr          - the same trick from a file written by
#                                     pyfatfs: loaded, called, and its
#                                     return value read back out of ERR%.
#                                     ERR% and not ERR: SET_ERRERL creates
#                                     it as an INTEGER, and a bare name is
#                                     looked up as a float -- VAR_FIND
#                                     matches on type before name, so
#                                     "PRINT ERR" reports the variable as
#                                     not found. Stock behaviour, and the
#                                     same for ERL%, DOSSTAT% and BIOSSTAT%
#
#                                     NEXT takes no variable in this BASIC.
#                                     S_NEXT reads its record off the return
#                                     stack and never parses one, so the " I"
#                                     in "NEXT I" is left for the statement
#                                     checker and comes back as a syntax
#                                     error on that line
#    13. ONVSYNC / RETIRQ           - the deferred handler. I-J is 1500
#                                     whatever NEXT's off-by-one convention
#                                     is, so it says one thing only: the
#                                     return stack came back intact from
#                                     every tick that fired INSIDE the FOR
#                                     loop. D proves the handler body ran
#
#   ./run-emu.sh              build and run
#   ./run-emu.sh --negative   corrupt the image magic: EXEC must refuse
#                             it and no banner may print, proving check
#                             1 can fail
#
# Requires: pip install pillow numpy pyfatfs, and a built X816_Calypsi
# examples/shell/kernel.bin (sh build.sh there).
set -u

# EMU, CORE and RT come from the same place every X816_Calypsi script
# gets them, so a moved checkout moves once.
. "$(dirname "$0")/../X816_Calypsi/runtime/calypsi.sh"
cd "$(dirname "$0")"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
WOUT=$(cygpath -m "$OUT" 2>/dev/null || echo "$OUT")

KERNEL="../X816_Calypsi/examples/shell/kernel.bin"
[ -f "$KERNEL" ] || { echo "kernel.bin missing -- run sh build.sh in X816_Calypsi/examples/shell"; exit 1; }

./build.sh || exit 1
cp build/basic.bin "$OUT/basic.bin"

NEG=0
if [ "${1:-}" = "--negative" ]; then
    NEG=1
    # Break the image magic: EXEC must refuse the file, so no banner.
    printf 'Y' | dd of="$OUT/basic.bin" bs=1 count=1 conv=notrunc 2>/dev/null
    echo "negative control: corrupted image magic, expecting NO banner"
fi

# One typed line per entry. The padding works around -autokeys dropping
# characters under load; keep it.
PAD='                                        '

keys_of () {            # build an -autokeys script from the arguments
    local k out='run BASIC.BIN\n'
    for k in "$@"; do out="$out$PAD$k\n"; done
    printf '%s' "$out"
}

KEYS_A=$(keys_of \
    'PRINT 1' \
    'XYZZY' \
    'PRINT 10/4' \
    'PRINT 2^10' \
    'PRINT 1/0' \
    'PRINT SQR(2)' \
    'PRINT SIN(1)' \
    'PRINT COS(10)' \
    'PRINT LN(10)' \
    'PRINT EXP(1)' \
    'PRINT ATAN(10)' \
    'PRINT 2^-1' \
    'PRINT INSTR("ABCDEFG","EF")' \
    'PRINT UCASE$("abc")' \
    'PRINT "["+TRIM$(" x ")+"]"' \
    'PRINT STRING$(5,"*")' \
    '10 PRINT 1.5' \
    '20 A=TIMER:WAIT 200:PRINT TIMER-A' \
    '30 B=FRAMES:VSYNC:PRINT FRAMES-B' \
    'RUN')

KEYS_B=$(keys_of \
    '10 PRINT 4242' \
    'SAVE "T.BAS"' \
    'NEW' \
    'LOAD "T.BAS"' \
    'RUN' \
    'DIR' \
    'DEL "T.BAS"' \
    'DIR' \
    'MKDIR "ND"' \
    'CD "ND"' \
    'PWD' \
    'CD "/"' \
    'RMDIR "ND"' \
    'PWD' \
    'SAVE "A.BAS"' \
    'RENAME "A.BAS","B.BAS"' \
    'COPY "B.BAS","C.BAS"' \
    'DIR' \
    'LOAD "C.BAS"' \
    'RUN' \
    'DEL "B.BAS"' \
    'DEL "C.BAS"')


KEYS_C=$(keys_of \
    'VPOKE &h10000,90' \
    'PRINT VPEEK(&h10000)' \
    'BORDER 0' \
    'PAL 1,&h0F00' \
    'PRINT VPEEK(&h1FA03)' \
    'SOUND 0,440,32' \
    'PRINT VPEEK(&h1F9C0)' \
    'SPRITEAT 0,100,50' \
    'SPRITESIZE 0,2,2' \
    'SPRITE 0,0' \
    'PRINT VPEEK(&h1FC02)' \
    'TILEAT 70,50,65,7' \
    'PRINT VPEEK(&h328C)' \
    'PCMVOL 10' \
    'PCMRATE 64' \
    'PCMMODE 16,1' \
    'PRINT PEEK(&h9F3B)' \
    'FMINIT' \
    'FMNOTE 0,48' \
    'FMVOL 0,100' \
    'FMOFF 0' \
    'PRINT I2CPEEK(&h42,&h30)' \
    'PRINT I2CPEEK(&h55,&h30)' \
    'PRINT JOY(0)' \
    'MOUSEAT 321,50' \
    'PRINT MOUSE(0)' \
    'A=10' \
    'PRINT PCMFREE-A' \
    'PRINT "FMOK"')

# Record I/O gets a session of its own because B was already 22 lines
# and the console is 60 rows: the last thing wanted is another
# scroll silently moving what an assertion reads.
KEYS_D=$(keys_of \
    'OPEN #1,"REC.TXT","W"' \
    'PRINT #1,1234' \
    'PRINT #1,"REC-OK"' \
    'CLOSE #1' \
    'OPEN #1,"REC.TXT","R"' \
    'INPUT #1,A' \
    'INPUT #1,B$' \
    'PRINT A' \
    'PRINT B$' \
    'PRINT EOF(1)' \
    'CLOSE #1' \
    'PRINT #9,1' \
    'PRINT "UNWEDGED"' \
    '-5' \
    'PRINT "AFTERMINUS"' \
    'MONITOR' \
    'TEXTCOLOR 15,0' \
    'PRINT "AFTERCOLOR"')

# The font gets a session to itself for an unusual reason: changing it
# changes EVERY glyph on the screen, including the ones other checks
# read. That is also what makes the check convincing.
#
# Lines are kept short. The console is 80 columns and the key script
# pads each line by 40, so a long GLYPH wraps and is TRUNCATED -- which
# looked exactly like a statement that silently did nothing, and cost
# an hour of looking at correct code.
KEYS_E=$(keys_of \
    'TILESET 1,&h18000' \
    'PRINT PEEK(&h9F36)' \
    'TILEMAP 1,&h11000' \
    'PRINT PEEK(&h9F35)' \
    'PRINT CHARSETAT' \
    'FONTCOPY &h4000,&h4800' \
    'A=&h4800' \
    'GLYPH A,65,254,198,140,24,50,102,254,0' \
    'CHARSET A' \
    'PRINT "AAA"' \
    'GRAPHICS 1' \
    'CLRBITMAP 7' \
    'PLOT 10,20,77' \
    'PRINT PEEK(&hE0320A)' \
    'LINE 0,100,639,100,55' \
    'PRINT POINT(300,100)' \
    'PRINT POINT(4,5)' \
    'PRINT PEEK(&hE4AFFF)')

# Interrupts and BRUN. The machine code both halves run is the same
# seven bytes -- LDA #$1234 / STA $8610 / RTL -- once POKEd in and once
# loaded off the card, because a constant the interpreter never computes
# is the only thing that can prove foreign code actually executed.
#
# Every word read back is zeroed first. Without that, "it reads 4660"
# would also pass on a machine where 4660 was already sitting there, and
# the first print in each pair is exactly the negative control for the
# second.
KEYS_F=$(keys_of \
    'POKEW &h8600,0' \
    'POKEW &h8610,0' \
    'PRINT PEEKW(&h8600)' \
    'POKE &h8500,&hA9' \
    'POKE &h8501,&h34' \
    'POKE &h8502,&h12' \
    'POKE &h8503,&h8D' \
    'POKE &h8504,&h00' \
    'POKE &h8505,&h86' \
    'POKE &h8506,&h6B' \
    'IRQ 1,&h8500' \
    'WAIT 200' \
    'IRQ 1,0' \
    'PRINT PEEKW(&h8600)' \
    'PRINT PEEKW(&h8610)' \
    'BRUN "T.BIN",&h8700' \
    'PRINT PEEKW(&h8610)' \
    'PRINT ERR%' \
    '5 D=0' \
    '10 FOR I=1 TO 500' \
    '20 NEXT' \
    '30 J=I' \
    '40 ONVSYNC 200' \
    '50 FOR I=1 TO 2000' \
    '60 NEXT' \
    '70 ONVSYNC 0' \
    '80 PRINT I-J' \
    '90 PRINT D' \
    '100 END' \
    '200 D=42' \
    '210 RETIRQ' \
    'RUN')

# The BRUN payload: the same instructions POKEd in above, but reaching
# the machine as a file. It returns $1234 in A, which lands in ERR.
printf '\xA9\x34\x12\x8D\x10\x86\x6B' > "$OUT/t.bin"

# Each session gets its own card, written by pyfatfs -- an independent
# FAT32 implementation, as everywhere else in the tree -- so neither can
# be fooled by what the other left behind.
run_session () {        # $1 = tag, $2 = key script, $3 = extra file, $4 = its name
    cp "$CORE/boot/fat32.img" "$OUT/card$1.img"
    python tools/putfile.py "$(cygpath -m "$OUT/card$1.img")" \
        "$(cygpath -m "$OUT/basic.bin")" BASIC.BIN >/dev/null || return 1
    if [ -n "${3:-}" ]; then
        python tools/putfile.py "$(cygpath -m "$OUT/card$1.img")" \
            "$(cygpath -m "$3")" "$4" >/dev/null || return 1
    fi
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 90 \
        "$EMU/build/x16emu.exe" -boot "$(cygpath -m "$CORE/boot/boot.rom")" \
        -load "F00000,$(cygpath -m "$(pwd)/$KERNEL")" \
        -sdcard "$WOUT/card$1.img" \
        -autokeys "$2" \
        -warp -gif "$WOUT/out$1.gif" >/dev/null 2>&1
    [ -f "$OUT/out$1.gif" ]
}

run_session A "$KEYS_A" || { echo "session A produced no recording"; exit 1; }
if [ "$NEG" = "0" ]; then
    run_session B "$KEYS_B" || { echo "session B produced no recording"; exit 1; }
    run_session C "$KEYS_C" || { echo "session C produced no recording"; exit 1; }
    run_session D "$KEYS_D" || { echo "session D produced no recording"; exit 1; }
    run_session E "$KEYS_E" || { echo "session E produced no recording"; exit 1; }
    run_session F "$KEYS_F" "$OUT/t.bin" T.BIN || { echo "session F produced no recording"; exit 1; }
else
    cp "$OUT/outA.gif" "$OUT/outB.gif"      # unused: the check ends early
    cp "$OUT/outA.gif" "$OUT/outC.gif"
    cp "$OUT/outA.gif" "$OUT/outD.gif"
    cp "$OUT/outA.gif" "$OUT/outE.gif"
    cp "$OUT/outA.gif" "$OUT/outF.gif"
fi

python - "$WOUT/outA.gif" "$WOUT/outB.gif" "$WOUT/outC.gif" "$WOUT/outD.gif" "$WOUT/outE.gif" "$WOUT/outF.gif" "$RT/font_cp437.s" "$NEG" <<'PY'
import sys, re, io
import numpy as np
from PIL import Image, ImageFile
ImageFile.LOAD_TRUNCATED_IMAGES = True

(gif_a, gif_b, gif_c, gif_d, gif_e, gif_f,
 fontinc) = (sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4],
             sys.argv[5], sys.argv[6], sys.argv[7])
negative = sys.argv[8] == "1"

vals = []
for line in io.open(fontinc, encoding='utf-8'):
    m = re.match(r'\s*\.byte\s+(.*)$', line.split(';')[0])
    if m:
        vals += [int(x.strip().lstrip('$'), 16)
                 for x in m.group(1).split(',') if x.strip()]

def _key(rows8):
    k = 0
    for b in rows8:
        k = (k << 8) | int(b)
    return k

glyph = {}
for _c in range(0x20, 0x7F):
    glyph[_key(vals[_c * 8:(_c + 1) * 8])] = chr(_c)
# The block cursor is a REVERSED cell, so on a blank one every pixel is
# lit. Read it as a space rather than as an unknown glyph. (CP437 $DB,
# a solid block, aliases onto this. Nothing here prints one.)
glyph[(1 << 64) - 1] = ' '

BIT = (0x80 >> np.arange(8)).astype(np.uint64)
PLACE = (np.uint64(256) ** np.arange(7, -1, -1, dtype=np.uint64))

def last_screen(path):
    im = Image.open(path)
    n = 0
    while True:
        try:
            im.seek(n); im.load(); n += 1
        except (EOFError, OSError, IndexError):
            break
    if n == 0:
        sys.exit("no decodable frame in %s -- did the emulator run?" % path)
    im.seek(n - 1)
    a = np.asarray(im.convert('RGB'))[:480, :640]
    cells = a.any(axis=2).reshape(60, 8, 80, 8).transpose(0, 2, 1, 3)
    keys = ((cells * BIT).sum(axis=3).astype(np.uint64) * PLACE).sum(axis=2)
    return ["".join(glyph.get(int(k), '?') for k in keys[r]).rstrip()
            for r in range(60)]

rows_a = last_screen(gif_a)
rows_b = [] if negative else last_screen(gif_b)
rows_c = [] if negative else last_screen(gif_c)
rows_d = [] if negative else last_screen(gif_d)
rows_e = [] if negative else last_screen(gif_e)
rows_f = [] if negative else last_screen(gif_f)
rows = rows_a + rows_b + rows_c + rows_d + rows_e + rows_f

def fail(msg):
    print("FAIL:", msg)
    for i, r in enumerate(rows):
        if r:
            print(f"  {i}: {r!r}")
    sys.exit(1)

banner = any("SuperBasic" in r for r in rows_a)

if negative:
    if banner:
        fail("banner printed despite a corrupted image magic -- "
             "EXEC's magic check is not what admitted the program")
    print("PASS (negative control): corrupted magic, no banner -- "
          "EXEC refused the image as designed")
    sys.exit(0)

if not banner:
    fail("no greeting banner -- BASIC.BIN did not run or SCREEN_PUTC is broken")
if any("READY" in r for r in rows):
    fail("a READY banner was printed -- SuperBasic prints no prompt")
if not any(r.strip() == "1" for r in rows_a):
    fail("`PRINT 1` did not answer 1")
if not any("Syntax error" in r for r in rows_a):
    fail("`XYZZY` did not report a syntax error")
# FTOS always emits BASIC816's 6-significant-digit form, with an
# exponent suffix whenever the decimal exponent is not zero -- so 2.5
# prints as "2.50000" and 1024 as "1.02400E03". That is upstream
# formatting, identical on the C256; assert what the interpreter really
# says rather than the shape a calculator would use.
if not any("2.50000" in r for r in rows_a):
    fail("`PRINT 10/4` did not answer 2.50000 (software float divide)")
if not any("1.02400E03" in r for r in rows_a):
    fail("`PRINT 2^10` did not answer 1.02400E03 (integer power)")
if not any("Division by zero" in r for r in rows_a):
    fail("`PRINT 1/0` did not report division by zero")
# SQR is Newton-Raphson over the software float ops, seeded from the
# exponent field. 1.41421 is the whole of what six significant digits
# can say about root two, so this catches a bad seed or a dropped
# iteration as well as an outright break.
if not any("1.41421" in r for r in rows_a):
    fail("`PRINT SQR(2)` did not answer 1.41421")
# SIN and COS: five Horner terms on [-pi/4, pi/4], with the whole circle
# folded into that range by subtracting multiples of pi/2. COS(10) is
# the one that matters -- ten radians is past three quadrants, so it
# checks the reduction and the quadrant sign, not just the polynomial.
if not any("8.41470E-01" in r for r in rows_a):
    fail("`PRINT SIN(1)` did not answer 8.41470E-01")
if not any("-8.39071E-01" in r for r in rows_a):
    fail("`PRINT COS(10)` did not answer -8.39071E-01 -- the range "
         "reduction or the quadrant sign is wrong")
# LN and EXP take the power of two out of, and back into, the exponent
# field. ATAN(10) is past both of the tangent folds, so like COS(10) it
# tests the reduction rather than the polynomial. 2^-1 has to go through
# EXP(y*LN(x)) -- repeated multiplication cannot do a negative exponent
# -- so it is the check that the two new functions are actually wired
# into the operator.
if not any("2.30258" in r for r in rows_a):
    fail("`PRINT LN(10)` did not answer 2.30258")
if not any("2.71828" in r for r in rows_a):
    fail("`PRINT EXP(1)` did not answer 2.71828")
if not any("1.47112" in r for r in rows_a):
    fail("`PRINT ATAN(10)` did not answer 1.47112 -- the fold is wrong")
if not any("5.00000E-01" in r for r in rows_a):
    fail("`PRINT 2^-1` did not answer 5.00000E-01 -- a negative exponent "
         "must route through EXP(y*LN(x))")
# The SuperBasic string layer. INSTR is ZERO-BASED so that its result
# can be handed straight to MID$, which counts from zero on this BASIC;
# "EF" sits at offset 4 of "ABCDEFG".
if not any(r.strip() == "4" for r in rows_a):
    fail("`PRINT INSTR(\"ABCDEFG\",\"EF\")` did not answer 4")
if not any(r.strip() == "ABC" for r in rows_a):
    fail("`PRINT UCASE$(\"abc\")` did not answer ABC")
if not any(r.strip() == "[x]" for r in rows_a):
    fail("TRIM$ did not strip the spaces from \" x \"")
# STRING$ lives in the EXTENDED token table, reached through the $FF
# escape. It is here to prove the two-byte scheme end to end from the
# tokenizer through execution -- VSYNC on line 30 proves the same for a
# statement, and LIST proves the detokenizer.
if not any(r.strip() == "*****" for r in rows_a):
    fail("`PRINT STRING$(5,\"*\")` did not answer ***** -- an extended "
         "token did not survive tokenizing, storing or dispatch")
if not any("1.50000" in r for r in rows_a):
    fail("`RUN` of a stored float literal did not answer 1.50000")
# WAIT and VSYNC, measured INSIDE a running program: typing a line at the
# REPL takes emulated seconds, so the same measurement between two typed
# lines would be dominated by the keystrokes rather than the wait.
# WAIT 200 is allowed anywhere in 200-299 ms; the point is that it waits
# about the right time rather than not at all. VSYNC must be exact.
if not any(r.strip().startswith("2.") and r.strip().endswith("E02")
           for r in rows_a):
    fail("`WAIT 200` did not take about 200 ms by the hardware clock")
# One frame, or two: a frame boundary can fall between B=FRAMES and the
# wait actually starting, and it does under -warp. What matters is that
# VSYNC waited for a boundary at all rather than returning at once or
# hanging, so accept either and reject everything else.
if not any(r.strip() in ("1.00000", "2.00000") for r in rows_a):
    fail("`VSYNC` did not advance the frame counter by one or two")

# ---- session B: the card ------------------------------------------------
# The exact match matters throughout: every typed line is echoed on
# screen whatever the disk does, so a substring test would pass with the
# statement under test completely broken. Only program output, and DIR's
# own columns, sit on a row of their own.
if len([r for r in rows_b if r.strip() == "4242"]) != 2:
    fail("expected 4242 twice -- once from the SAVE/LOAD round trip and "
         "once from the COPY -- so a program did not survive the card")
listed = [r for r in rows_b if r.startswith("T        BAS")]
if len(listed) != 1:
    fail("expected T.BAS in the first DIR and gone from the second after "
         "DEL, but it was listed %d time(s)" % len(listed))
if not any(r.strip() == "/ND" for r in rows_b):
    fail("MKDIR then CD then PWD did not report /ND")
if not any(r.strip() == "/" for r in rows_b):
    fail("PWD never reported the root directory")
if any(r.startswith("A        BAS") for r in rows_b):
    fail("RENAME left A.BAS behind -- it did not rename, it copied or "
         "did nothing")
if len([r for r in rows_b if r.startswith("B        BAS")]) != 1:
    fail("RENAME did not produce exactly one B.BAS listing")
if len([r for r in rows_b if r.startswith("C        BAS")]) != 1:
    fail("COPY did not produce exactly one C.BAS listing")

# ---- session C: the hardware ---------------------------------------------
# Its own session because B outgrew the 60-row console and SCROLLED, which
# moved the tile cell out from under the address the check reads back.
# VRAM is not in the CPU address space; VPOKE/VPEEK go through the port at
# $9F20. $10000 is chosen over something lower for two reasons: it
# exercises bit 16 of the address, which sits alone in ADDR_H, and it is
# clear of the tilemap and font, so the poke leaves no stray character on
# screen for the decoder to read past.
if not any(r.strip() == "90" for r in rows_c):
    fail("VPOKE then VPEEK did not round-trip a byte through VRAM")
# The palette is VRAM as well, at $1FA00, two bytes an entry. $0F00 is
# pure red, so the second byte -- the red nibble -- reads back as 15.
if not any(r.strip() == "15" for r in rows_c):
    fail("PAL did not write a palette entry that VPEEK can read back")
# So is the PSG, at $1F9C0. SOUND cannot be heard from here, but its
# registers can be read: 440 Hz becomes 1181 ($049D) because the
# register is Hz * 2^17 / 48828.125, so the low byte is 157. That checks
# the frequency conversion, not merely that something was written.
if not any(r.strip() == "157" for r in rows_c):
    fail("SOUND did not convert 440 Hz to the PSG frequency register")
# Sprite attributes are VRAM as well, eight bytes each from $1FC00.
# SPRITE 0,0 leaves the sprite hidden on purpose: enabling one with
# whatever happened to be in VRAM for its image draws junk across the
# screen, which the glyph decoder then has to read past.
if not any(r.strip() == "100" for r in rows_c):
    fail("SPRITEAT did not write the sprite X position")
# The console is itself a tilemap at VRAM $00000, two bytes a cell and
# 128 cells to a row, so cell (70,50) is at 50*256 + 70*2 = $328C.
# That corner of the screen is chosen because the character really does
# appear there, and anywhere nearer the top would land in a row the
# decoder has to read.
if not any(r.strip() == "65" for r in rows_c):
    fail("TILEAT did not write a cell of the console tilemap")

# PCM: the control byte reads back, so this is an assertion and not a
# hope. 122 is $7A -- 16-bit ($20), stereo ($10), volume 10 ($0A), and
# the FIFO-empty flag ($40) the hardware adds for itself.
if not any(r.strip() == "122" for r in rows_c):
    fail("the VERA PCM control register did not read back what PCMMODE set")

# The YM2151 gives nothing back at all -- its status register reports
# timer and busy flags, never a register -- so the FM statements can
# only be shown to run. FMOK printing means none of the five threw.
if not any(r.strip() == "FMOK" for r in rows_c):
    fail("one of the FM statements threw")

# The strongest check on this page. 47 is the system controller's
# firmware major version, compiled into the emulator and not produced by
# any code here, and reading it exercises the whole bit-banged I2C
# master: start, address, register, stop, start, address again, eight
# shifted-in bits, NACK, stop.
if not any(r.strip() == "47" for r in rows_c):
    fail("I2CPEEK did not read the system controller version over I2C")
# ...and its own negative control: nothing lives at $55, so the master
# has to notice the missing acknowledge rather than invent a byte.
if not any(r.strip() == "-1" for r in rows_c):
    fail("I2CPEEK invented an answer for a device that is not on the bus")

# No controller is attached in a headless run, so every line reads high
# and JOY inverts that to "no buttons". This shows the sixteen-bit shift
# completes and the result is inverted; it cannot show the bit order.
if not any(r.strip() == "0" for r in rows_c):
    fail("JOY did not report an absent controller as no buttons held")
# The pointer position is SuperBasic's own, since the hardware reports
# only movement -- so MOUSEAT setting it and MOUSE reading it back is
# the whole contract, and 321 is nothing else on any screen.
if not any(r.strip() == "321" for r in rows_c):
    fail("MOUSE did not read back the position MOUSEAT set")

# A no-argument function followed by a minus. PCMFREE is 1 and A is 10,
# so a BINARY minus gives -9 and a NEGATION would give -10 -- the two
# readings differ, which is the whole point of choosing these numbers.
# PCMFREE is an EXTENDED token, so this also covers the half of the rule
# the old list of base ids could never have reached.
if not any(r.strip().startswith("-9") for r in rows_c):
    fail("a minus after a no-argument function was read as a negation")

# ---- session D: record I/O ------------------------------------------------
# The whole round trip: PRINT # writes through the buffer layer, CLOSE
# flushes it, INPUT # reads it back through the same layer, and EOF says
# when to stop. The two values are deliberately unlike anything else on
# any screen so a stray match cannot pass for a read.
if not any(r.strip() == "1.23400E03" for r in rows_d):
    fail("INPUT #1 did not read back the number PRINT #1 wrote")
if not any(r.strip() == "REC-OK" for r in rows_d):
    fail("INPUT #1 did not read back the string PRINT #1 wrote")
if not any(r.strip() == "-1" for r in rows_d):
    fail("EOF(1) was not true at the end of the file")
# A throw inside a redirected PRINT skips the restore at the end of the
# statement. If PRREADY did not undo the redirect, every later PRINT
# would go into a file and the console would look dead.
if not any(r.strip() == "UNWEDGED" for r in rows_d):
    fail("the console did not recover from an error inside PRINT #")

# A line that is nothing but a minus sign and a number. This used to
# fill the screen with garbage: PREVCHAR reached its "nothing before
# this" return with a 16-bit accumulator, where the assembler had
# emitted a two-byte LDA #0, and the instruction swallowed the opcode
# after it. The typo is an easy one and the failure was total, so both
# halves are checked -- the error is reported, AND the machine is still
# there afterwards.
if not any(r.strip() == "Syntax error" for r in rows_d):
    fail("a line beginning with a minus sign was not refused")
if not any(r.strip() == "AFTERMINUS" for r in rows_d):
    fail("the machine did not survive a line beginning with a minus sign")

# The monitor and the inline assembler are not built here. The keyword
# stays reserved and refuses -- deleting the token would renumber every
# one after it, and a zero-length record in its place would TERMINATE
# the table walk and quietly unmake every keyword that follows. So this
# also checks that GET, INPUT and TEXTCOLOR, which come after MONITOR in
# the table, still exist.
#
# TEXTCOLOR is the proof of that AND a fix of its own: it pushed the
# foreground colour 8 bits wide and pulled it back 16, taking the return
# address with it, so it hung the machine every time it was used.
if not any(r.strip() == "AFTERCOLOR" for r in rows_d):
    fail("TEXTCOLOR hung, or a keyword after MONITOR in the table is gone")

# ---- session E: the redefinable character set ----------------------------
# 16384 is $4000, where the kernel leaves its font. CHARSETAT reads the
# tilebase register back and undoes the >>11 the hardware stores it as.
if not any(r.strip() == "16384" for r in rows_e):
    fail("CHARSETAT did not report the kernel font address")

# The layer bases are stored shifted, and the addresses here are chosen
# ABOVE $10000 on purpose: bit 16 has to be brought down and merged with
# the shifted low word, and getting that wrong is invisible below $10000.
# CHARSET had exactly that bug and passed its test, because both fonts
# in play live at $4000 and $4800.
#   $18000 >> 11 << 2 = 192      $11000 >> 9 = 136
if not any(r.strip() == "192" for r in rows_e):
    fail("TILESET mis-stored a tile base above $10000")
if not any(r.strip() == "136" for r in rows_e):
    fail("TILEMAP mis-stored a map base above $10000")

# Character 65 was given the bitmap of a Z in a COPY of the font, and the
# console pointed at the copy. The whole screen re-renders through it, so
# every A anywhere becomes a Z -- which is why the banner is checked as
# well as the printed string. This asserts on PIXELS, decoded from the
# recording against the CP437 table: it is not SuperBasic reporting on
# itself, and it fails if FONTCOPY, GLYPH or CHARSET is wrong.
if not any(r.strip() == "ZZZ" for r in rows_e):
    fail("GLYPH did not replace character 65 in the font being displayed")
if not any("BZSIC816" in r for r in rows_e):
    fail("the redefined glyph did not reach text drawn before CHARSET")

# ---- session E: bitmap graphics on VERA2 ---------------------------------
# The framebuffer is ordinary memory at $E0:0000, so PEEK reaches it -- and
# PEEK is a completely different path from POINT, which means the pixel can
# be confirmed by something that shares no code with what wrote it.
# Pixel (10,20) is at 20*640 + 10 = $320A.
if not any(r.strip() == "77" for r in rows_e):
    fail("PLOT did not put a pixel where PEEK could find it")
# A line the full width of the screen, sampled in the middle.
if not any(r.strip() == "55" for r in rows_e):
    fail("LINE did not draw across the screen")
# Two 7s, and they check different things. POINT(4,5) is next to the
# diagonal in the earlier test and must still hold the CLRBITMAP colour --
# a line that painted its neighbours would fail here. $E4AFFF is the LAST
# byte of the frame, $E00000 + 307199, so the fill is shown to have covered
# every one of the five banks it spans rather than stopping at the first.
if len([r for r in rows_e if r.strip() == "7"]) < 2:
    fail("CLRBITMAP did not fill the whole frame, or LINE painted too wide")

# ---- session F: interrupts and BRUN --------------------------------------
# 4660 is $1234, stored by seven bytes of machine code that BASIC never
# executes an instruction of. It has to appear TWICE -- once from the
# handler the kernel called at a raster line, once from the file BRUN
# loaded and JSLed -- and 0 has to appear twice before them, which is
# what stops either check passing on memory that already held the value.
if len([r for r in rows_f if r.strip() == "0"]) < 2:
    fail("the two words did not read 0 before the code that writes them "
         "ran -- the checks below would prove nothing")
if len([r for r in rows_f if r.strip() == "4660"]) != 3:
    fail("expected 4660 three times in session F: from the IRQ handler, "
         "from the BRUN'd file, and from ERR carrying its return value")

# The deferred handler. I-J is 1500 whichever value NEXT leaves the loop
# variable at, so this asserts one thing and one thing only: every tick
# that fired between two statements of the FOR loop pushed and popped the
# return stack in balance. RETIRQ restoring the wrong BIP would derail
# the program long before it reached here.
if not any(r.strip() in ("1500", "1.50000E03") for r in rows_f):
    fail("ONVSYNC handlers firing inside a FOR loop did not leave the "
         "loop where they found it -- I-J was not 1500")
if not any(r.strip() in ("42", "4.20000E01") for r in rows_f):
    fail("the ONVSYNC handler never ran, or never reached its second "
         "statement -- D was not 42")

print("PASS: SuperBasic booted from the card, ran the language and float")
print("      checks, round-tripped programs through SAVE, LOAD, DIR, DEL,")
print("      RENAME and COPY, and wrote and read a data file with PRINT #")
print("      and INPUT #, all on a real FAT32 card")
for r in rows:
    if r:
        print("   ", r)
PY
# `|| exit 1` and not decoration: without it a fail() printed FAIL and the
# script carried on to the pyfatfs check, whose success became the exit
# status. A run that had failed reported 0.
[ $? -eq 0 ] || exit 1

# The screen only proves SuperBasic can read back what SuperBasic wrote.
# pyfatfs is a second, independent FAT32 implementation, so it can tell a
# correct file from a merely self-consistent one -- and it is the only
# thing here that sees the bytes rather than the glyphs.
if [ "$NEG" = "0" ]; then
python - "$WOUT/cardD.img" <<'PYCHECK' || exit 1
import sys
from pyfatfs.PyFatFS import PyFatFS
fs = PyFatFS(sys.argv[1])
try:
    with fs.open("/REC.TXT", "rb") as f:
        got = f.read()
finally:
    fs.close()
want = b" 1234" + bytes([13]) + b"REC-OK" + bytes([13])
if got != want:
    print("FAIL: REC.TXT on the card is %r, expected %r" % (got, want))
    sys.exit(1)
print("PASS: and pyfatfs reads that same file back as %r" % (got,))
PYCHECK
fi

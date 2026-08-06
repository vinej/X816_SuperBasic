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

# Each session gets its own card, written by pyfatfs -- an independent
# FAT32 implementation, as everywhere else in the tree -- so neither can
# be fooled by what the other left behind.
run_session () {        # $1 = tag, $2 = key script
    cp "$CORE/boot/fat32.img" "$OUT/card$1.img"
    python tools/putfile.py "$(cygpath -m "$OUT/card$1.img")" \
        "$(cygpath -m "$OUT/basic.bin")" BASIC.BIN >/dev/null || return 1
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
else
    cp "$OUT/outA.gif" "$OUT/outB.gif"      # unused: the check ends early
fi

python - "$WOUT/outA.gif" "$WOUT/outB.gif" "$RT/font_cp437.s" "$NEG" <<'PY'
import sys, re, io
import numpy as np
from PIL import Image, ImageFile
ImageFile.LOAD_TRUNCATED_IMAGES = True

gif_a, gif_b, fontinc = sys.argv[1], sys.argv[2], sys.argv[3]
negative = sys.argv[4] == "1"

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
rows = rows_a + rows_b

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
if not any(r.strip() == "1.00000" for r in rows_a):
    fail("`VSYNC` did not advance the frame counter by exactly one")

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

print("PASS: SuperBasic booted from the card, ran the language and float")
print("      checks, and round-tripped programs through SAVE, LOAD, DIR,")
print("      DEL, RENAME and COPY on a real FAT32 card")
for r in rows:
    if r:
        print("   ", r)
PY

#!/usr/bin/env bash
# ============================================================================
# run-bench.sh -- how fast is SuperBasic, in the units the period used.
#
# Runs the two benchmarks BASIC implementations of the late 70s and early
# 80s were actually measured with, and prints what SuperBasic takes on an
# 8 MHz X816.
#
#   Rugg & Feldman BM1-BM8   Kilobaud / Interface Age, 1977. Eight programs
#                            that add ONE feature at a time: an empty FOR
#                            loop, then K=K+1, then division, then more
#                            arithmetic, then GOSUB, then a nested loop,
#                            then an array, then exponent/log/sine. The
#                            DIFFERENCES between them say where the
#                            interpreter spends its time. BM1I is this
#                            port's own addition: BM1 on K%, the integer
#                            fast path.
#
#   Ahl's benchmark          David Ahl, Creative Computing, 1983-84. One
#                            program, and it reports ACCURACY as well as
#                            speed; these floats are the port's own
#                            software IEEE-754 singles, so the accuracy
#                            column is a result and not a formality.
#
# WHY THE TIMES ARE REAL DESPITE -warp. The emulator's millisecond counter
# is driven by EXECUTED CYCLES at the emulated 8 MHz (X816_Emulator
# src/memory.c timer_step), not by the host's wall clock. Warping changes
# how long the run takes, not what TIMER reads. Checked against the FPGA
# on 2026-08-09: BM1 measured 946 ms on the MiSTer at 8 MHz against 871
# here, so the cycle model runs about 8 percent optimistic -- deltas and
# percentages from this script are sound; absolute times worth quoting
# come from hardware. The same run measured 539 ms at TURBO's 14 MHz,
# against 540.6 predicted by pure clock ratio: the interpreter is
# compute-bound and TURBO is worth exactly its ratio.
#
# THE PROGRAM IS TYPED IN, AND RUN IS THE LAST KEYSTROKE. -autokeys types
# into the SMC key FIFO on a timer and keeps typing while the guest is
# busy; the FIFO drops what does not fit. This harness lost three rounds
# to that: one session running all nine let a RUNNING benchmark eat the
# next LOAD, so eight of nine "results" were copies of the first; a
# session per benchmark lost the RUN itself during a long LOAD; and the
# repair lost its trailing newline to $(...), which STRIPS them -- RUN sat
# on the input line for five minutes while the GIF grew to 198 MB. Hence:
# type the program from bench/*.BAS (one source of truth with the card
# that runs on real hardware), make RUN the final keystroke, and end with
# a LITERAL backslash-n, which command substitution cannot strip and
# -autokeys converts to CR itself.
#
# The sessions run in PARALLEL, one per benchmark; safe for the same
# reason -warp is.
#
# This is NOT part of run-emu.sh and must not become part of it. That
# suite is a pass/fail on correctness; a benchmark has no failing value.
#
#   ./run-bench.sh                 build, run all ten, print the table
#   ./run-bench.sh --raw           also dump each decoded screen
#   ./run-bench.sh --raw BM6 AHL   only those, to see why one printed
#                                  nothing
# ============================================================================
set -u
cd "$(dirname "$0")"
. "../X816_Calypsi/runtime/calypsi.sh"

RAW=0
if [ "${1:-}" = "--raw" ]; then RAW=1; shift; fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
WOUT=$(cygpath -m "$OUT" 2>/dev/null || echo "$OUT")
KERNEL="../X816_Calypsi/programs/shell/kernel.bin"
TAGS="${*:-BM1 BM1I BM2 BM3 BM4 BM5 BM6 BM7 BM8 AHL}"

[ -f "$KERNEL" ] || { echo "kernel.bin missing -- run sh build.sh in X816_Calypsi/programs/shell"; exit 1; }

./build.sh >/dev/null 2>&1 || { echo "build failed"; exit 1; }
cp build/basic.bin "$OUT/basic.bin"

cp "$CORE/boot/fat32.img" "$OUT/card.img"
python tools/putfile.py "$(cygpath -m "$OUT/card.img")" \
    "$(cygpath -m "$OUT/basic.bin")" BASIC.BIN >/dev/null || exit 1

PAD='                                        '
prog_keys () {          # $1 = tag: the program text, then RUN, nothing after
    local out='run BASIC.BIN\n' line
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] && out="$out$PAD$line\n"
    done < "bench/$1.BAS"
    printf '%s%sRUN\\n' "$out" "$PAD"
}

run_one () {            # $1 = tag
    cp "$OUT/card.img" "$OUT/card$1.img"
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 300 \
        "$EMU/build/x16emu.exe" -boot "$(cygpath -m "$CORE/boot/boot.rom")" \
        -load "F00000,$(cygpath -m "$(pwd)/$KERNEL")" \
        -sdcard "$WOUT/card$1.img" \
        -autokeys "$(prog_keys "$1")" \
        -warp -gif "$WOUT/out$1.gif" >/dev/null 2>&1
}

echo "running the benchmarks at once. Each warps through its own emulated"
echo "time; the wall clock this takes is not the measurement."
for t in $TAGS; do run_one "$t" & done
wait

for t in $TAGS; do
    [ -f "$OUT/out$t.gif" ] || { echo "$t produced no recording"; exit 1; }
done

python - "$WOUT" "$RT/font_cp437.s" "$RAW" $TAGS <<'PY'
import sys, re, io, os
import numpy as np
from PIL import Image, ImageFile
ImageFile.LOAD_TRUNCATED_IMAGES = True
wout, fontinc, raw = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
TAGS = sys.argv[4:]

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
glyph[(1 << 64) - 1] = ' '
BIT = (0x80 >> np.arange(8)).astype(np.uint64)
PLACE = (np.uint64(256) ** np.arange(7, -1, -1, dtype=np.uint64))

def last_screen(gif):
    im = Image.open(gif)
    n = 0
    while True:
        try:
            im.seek(n); im.load(); n += 1
        except (EOFError, OSError, IndexError):
            break
    im.seek(n - 1)
    a = np.asarray(im.convert('RGB'))[:480, :640]
    cells = a.any(axis=2).reshape(60, 8, 80, 8).transpose(0, 2, 1, 3)
    keys = ((cells * BIT).sum(axis=3).astype(np.uint64) * PLACE).sum(axis=2)
    return ["".join(glyph.get(int(k), '?') for k in keys[r]).rstrip()
            for r in range(60)]

rows = []
for t in TAGS:
    got = last_screen(os.path.join(wout, "out%s.gif" % t))
    if raw:
        print("---- %s" % t)
        for i, r in enumerate(got):
            if r:
                print("%2d: %r" % (i, r))
        print()
    rows += got

# A result line is the tag then the milliseconds, in column 0 -- typed
# echo is indented by the autokeys padding. TIMER is a float, so a time
# prints as 1.23500E03; float() reads both forms.
WHAT = {
    "BM1":  "empty FOR loop, 1000 times",
    "BM1I": "the same loop on K% -- NEXT's integer fast path",
    "BM2":  "K=K+1 and a branch on a line number",
    "BM3":  "  + a division and three more terms",
    "BM4":  "  + constants instead of K (the classic one)",
    "BM5":  "  + a GOSUB and RETURN each pass",
    "BM6":  "  + an empty FOR loop of 5 inside",
    "BM7":  "  + an array store inside that loop",
    "BM8":  "K^2, LN(K) and SIN(K): the float library",
    "AHL":  "Ahl: 1000 SQR, 1000 ^, 2000 RND",
}
found, acc = {}, {}
for r in rows:
    if r.startswith(" "):
        continue
    m = re.match(r'^(BM[1-8]I?|AHL)\s+([0-9.E+-]+)$', r.strip())
    if m:
        found[m.group(1)] = float(m.group(2))
        continue
    m = re.match(r'^(ACC|RER)\s+(\S+)$', r.strip())
    if m:
        acc[m.group(1)] = m.group(2)

if not found:
    print("no results on any screen. Run with --raw to see what they said;")
    print("a program that threw prints an error instead of a time.")
    sys.exit(1)

print()
print("SuperBasic on the X816, 8 MHz                Rugg/Feldman and Ahl")
print("=" * 68)
print("%-5s %9s %9s   %s" % ("", "ms", "s", "what it adds"))
total = 0.0
for tag in TAGS:
    if tag not in found:
        print("%-5s %9s %9s   %s" % (tag, "-", "-", "DID NOT RUN -- see --raw"))
        continue
    ms = found[tag]
    total += ms
    print("%-5s %9.0f %9.2f   %s" % (tag, ms, ms / 1000.0, WHAT.get(tag, "")))
print("-" * 68)
print("%-5s %9.0f %9.2f   total" % ("", total, total / 1000.0))
if acc:
    print()
    print("Ahl's accuracy, 0 being perfect (the port's own software IEEE-754")
    print("singles, not Microsoft's -- it is a result):")
    print("   arithmetic error  %s" % acc.get("ACC", "?"))
    print("   RND sum error     %s" % acc.get("RER", "?"))
print()
print("A C64, an Apple II or a Spectrum ran at about 1 MHz against this")
print("machine's 8. Divide by 8 to ask whether the INTERPRETER is good;")
print("take the raw figure to ask whether the MACHINE is fast. Tables for")
print("those machines are not reproduced here on purpose.")
PY

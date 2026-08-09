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
#                            then an array, then exponent/log/sine. Because
#                            each isolates one thing, the DIFFERENCES
#                            between them say where the interpreter spends
#                            its time, which is worth more than any single
#                            number.
#
#   Ahl's benchmark          David Ahl, Creative Computing, 1983-84. One
#                            program, and it reports ACCURACY as well as
#                            speed. The accuracy column is a real result
#                            here rather than a formality: these floats are
#                            this port's own software implementation
#                            (X816/floats_x816.s), not Microsoft's.
#
# WHY THE TIMES ARE REAL DESPITE -warp. The emulator's millisecond counter
# is driven by EXECUTED CYCLES at the emulated 8 MHz (X816_Emulator
# src/memory.c timer_step: clks_per_ms = MHZ * 1000), not by the host's
# wall clock. Warping makes the run finish sooner without changing what
# TIMER reads. So the numbers are the seconds the real machine would take,
# to the accuracy of the emulator's cycle model -- which is per-instruction
# counting, CHECKED AGAINST THE FPGA on 2026-08-09: BM1 measured 946 ms on
# the MiSTer at 8 MHz against 871 ms here, so the model runs about 8
# percent optimistic. Deltas and percentages from this script are sound;
# absolute times worth quoting come from hardware. The same run measured
# 539 ms at TURBO's 14 MHz -- 540.6 predicted by pure clock ratio, so the
# interpreter is compute-bound and TURBO is worth exactly its ratio.
#
# READING THE RESULT. The X816 runs at 8 MHz where a C64, an Apple II or a
# Spectrum ran at about 1. The raw figure answers "is this machine fast";
# the figure divided by 8 answers "is this interpreter good", which is the
# question about the port. Published tables for those machines are easy to
# find and are deliberately NOT reproduced here: a comparison column is
# only worth having from a source you trust.
#
# This is NOT part of run-emu.sh and must not become part of it. That suite
# is a pass/fail on correctness; a benchmark has no failing value, and a
# slow build is not a broken one.
#
#   ./run-bench.sh                 build, run all nine, print the table
#   ./run-bench.sh --raw           also dump each decoded screen
#   ./run-bench.sh --raw BM6 AHL   only those, which is how you find out
#                                  why one of them printed nothing
# ============================================================================
set -u
cd "$(dirname "$0")"
. "../X816_Calypsi/runtime/calypsi.sh"

RAW=0
if [ "${1:-}" = "--raw" ]; then RAW=1; shift; fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
WOUT=$(cygpath -m "$OUT" 2>/dev/null || echo "$OUT")
KERNEL="../X816_Calypsi/examples/shell/kernel.bin"
TAGS="${*:-BM1 BM1I BM2 BM3 BM4 BM5 BM6 BM7 BM8 AHL}"

[ -f "$KERNEL" ] || { echo "kernel.bin missing -- run sh build.sh in X816_Calypsi/examples/shell"; exit 1; }

./build.sh >/dev/null 2>&1 || { echo "build failed"; exit 1; }
cp build/basic.bin "$OUT/basic.bin"

cp "$CORE/boot/fat32.img" "$OUT/card.img"
python tools/putfile.py "$(cygpath -m "$OUT/card.img")" \
    "$(cygpath -m "$OUT/basic.bin")" BASIC.BIN >/dev/null || exit 1
for t in $TAGS; do
    python tools/putfile.py "$(cygpath -m "$OUT/card.img")" \
        "$(cygpath -m "bench/$t.BAS")" "$t.BAS" >/dev/null || exit 1
done

PAD='                                        '

# THE PROGRAM IS TYPED IN, NOT LOADED, AND THAT IS THE WHOLE TRICK.
#
# -autokeys types into the SMC key FIFO on a timer and keeps typing while
# the guest is busy; the FIFO drops whatever does not fit. Both earlier
# versions of this script lost to that race. Driving all nine from one
# session let a RUNNING benchmark eat the next LOAD, so RUN re-ran the
# previous program and printed its time again -- nine plausible rows, one
# real measurement. A session each fixed that and then lost the race one
# step earlier: LOADing a longer file takes long enough that the padding
# ran out and the RUN itself was eaten. BM6 received "UN", and BM7 and
# AHL received nothing at all.
#
# Tuning the padding cannot fix it. Too little and RUN is eaten; too much
# and the part that DOES echo runs past column 80, wraps, and the line
# editor -- which reads one screen row -- gets half a command.
#
# So RUN is the LAST thing typed, and nothing follows it. The program text
# comes from bench/*.BAS line by line, which keeps one source of truth:
# the same files go on a card for real hardware, and typing them tokenizes
# them exactly as LOAD would.
prog_keys () {          # $1 = tag
    local out='run BASIC.BIN
' line
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] && out="$out$PAD$line
"
    done < "bench/$1.BAS"
    # Literal backslash-n, NOT a real newline: the caller reads this
    # through $(...), which STRIPS trailing newlines -- the first version
    # ended with printf's 
, the CR after RUN never reached the
    # emulator, and RUN sat on the input line of every session for five
    # minutes while the GIF grew to 198 MB. autokeys turns the two-byte
    # sequence into CR itself, immune to the stripping.
    printf '%s%sRUN\n' "$out" "$PAD"
}

# ONE EMULATOR SESSION PER BENCHMARK, AND THEY RUN AT ONCE.
#
# Running them concurrently is free of consequence for exactly the reason
# the times mean anything at all: the millisecond counter is driven by
# executed cycles, so a session that gets less of the host's CPU takes
# longer in wall time and reports the same number.
run_one () {            # $1 = tag
    cp "$OUT/card.img" "$OUT/card$1.img"
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 300         "$EMU/build/x16emu.exe" -boot "$(cygpath -m "$CORE/boot/boot.rom")"         -load "F00000,$(cygpath -m "$(pwd)/$KERNEL")"         -sdcard "$WOUT/card$1.img"         -autokeys "$(prog_keys "$1")"         -warp -gif "$WOUT/out$1.gif" >/dev/null 2>&1
}

echo "running the nine benchmarks at once. Each warps through its own"
echo "emulated time; the wall clock this takes is not the measurement."
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

# A result line is the tag and then the milliseconds. TIMER is a FLOAT
# here, so a time prints as 1.23500E03 rather than 1235; float() reads
# both. The lines that echo while being typed are indented by the autokeys
# padding, so a tag in the first column is the program's own output.
WHAT = {
    "BM1": "empty FOR loop, 1000 times",
    "BM1I": "the same loop on K% -- NEXT's integer fast path",
    "BM2": "K=K+1 and a branch on a line number",
    "BM3": "  + a division and three more terms",
    "BM4": "  + constants instead of K (the classic one)",
    "BM5": "  + a GOSUB and RETURN each pass",
    "BM6": "  + an empty FOR loop of 5 inside",
    "BM7": "  + an array store inside that loop",
    "BM8": "K^2, LN(K) and SIN(K): the float library",
    "AHL": "Ahl: 1000 SQR, 1000 ^, 2000 RND",
}
found, acc = {}, {}
for r in rows:
    if r.startswith(" "):
        continue
    m = re.match(r'^(BM[1-8]I?|AHL)\s+([0-9.E+-]+)$', r.strip())
    if m:
        found[m.group(1)] = float(m.group(2))
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
    print("%-5s %9.0f %9.2f   %s" % (tag, ms, ms / 1000.0, WHAT[tag]))
print("-" * 68)
print("%-5s %9.0f %9.2f   all nine" % ("", total, total / 1000.0))
if acc:
    print()
    print("Ahl's accuracy, 0 being perfect. This is the port's own software")
    print("float library rather than Microsoft's, so it is a result:")
    print("   arithmetic error  %s" % acc.get("ACC", "?"))
    print("   RND sum error     %s" % acc.get("RER", "?"))
print()
print("A C64, an Apple II or a Spectrum ran at about 1 MHz against this")
print("machine's 8. Divide by 8 to ask whether the INTERPRETER is good;")
print("take the raw figure to ask whether the MACHINE is fast. Tables for")
print("those machines are not reproduced here on purpose.")
PY

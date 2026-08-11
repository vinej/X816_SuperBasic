#!/usr/bin/env bash
# Run BASIC816's own unit-test corpus on the X816 emulator.
#
# The UNITTEST=1 build replaces the REPL with TST_BASIC, which walks the
# suites in basic816/src/tests/ and prints "<name>: PASSED", or, when an
# assertion fails, the macro's message and the offending value in
# brackets. This is the Phase 2 signal that GIF
# scraping of the REPL cannot give: it exercises the software float and
# integer engines directly, operand by operand.
#
# The log is far longer than the 80x60 console, so the screen scrolls.
# A single final frame would therefore hide most of the run -- every
# frame is decoded and the rows are unioned in first-seen order, which
# reconstructs the whole scrollback.
#
#   ./run-tests.sh              build and run the corpus
#   ./run-tests.sh --negative   break one expectation the engine really
#                               satisfies (20.0 + 5.0 is 25) and prove the
#                               harness reports it. Worth running whenever
#                               the pass/fail detection below is touched:
#                               UT_FAIL_AD never prints the word FAILED,
#                               so the obvious grep silently passes.
#
# Requires: pip install pillow pyfatfs, and a built X816_Calypsi
# programs/shell/kernel.bin (sh build.sh there).
set -u

. "$(dirname "$0")/../X816_Calypsi/runtime/calypsi.sh"
cd "$(dirname "$0")"

hostpath () {
    case "$1" in
        /c/*) printf '/mnt/c/%s\n' "${1#/c/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

winpath () {
    cygpath -m "$1" 2>/dev/null || wslpath -m "$(hostpath "$1")" 2>/dev/null || echo "$1"
}

CORE_HOST=$(hostpath "$CORE")
EMU_HOST=$(hostpath "$EMU")

PYTHON_USER=${USER:-$(id -un 2>/dev/null || echo jyv)}
PYTHON_LOCAL=$(hostpath "/c/Users/$PYTHON_USER/AppData/Local/Programs/Python/Python312/python.exe")
PYTHON_CMD=
PYTHON_WIN=0
for candidate in ${PYTHON:-} python python3 python.exe "$PYTHON_LOCAL" py.exe; do
    [ -n "$candidate" ] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -c "import numpy, PIL; from pyfatfs.PyFatFS import PyFatFS" >/dev/null 2>&1; then
        PYTHON_CMD=$candidate
        case "$candidate" in
            *.exe) PYTHON_WIN=1 ;;
        esac
        break
    fi
done
[ -n "$PYTHON_CMD" ] || { echo "python with pillow, numpy and pyfatfs missing"; exit 1; }
EMU_TIMEOUT=${EMU_TIMEOUT:-30}

pypath () {
    if [ "$PYTHON_WIN" -eq 1 ]; then
        winpath "$1"
    else
        hostpath "$1"
    fi
}

mkdir -p build
OUT=$(mktemp -d -p "$(pwd)/build" test-run.XXXXXX)
trap 'rm -rf "$OUT"' EXIT
WOUT=$(winpath "$OUT")

KERNEL="../X816_Calypsi/programs/shell/kernel.bin"
[ -f "$KERNEL" ] || { echo "kernel.bin missing -- run sh build.sh in X816_Calypsi/programs/shell"; exit 1; }

NEG=0
SRC="basic816/src/tests/floattests.s"
if [ "${1:-}" = "--negative" ]; then
    NEG=1
    cp "$SRC" "$OUT/floattests.s.orig"
    # TST_FP_ADD's 20.0 + 5.0 really is 25; demand 26 and it must go red.
    sed -i 's/UT_M_EQ_LIT_D ARGUMENT1,25,"Expected 25"/UT_M_EQ_LIT_D ARGUMENT1,26,"Expected 25"/' "$SRC"
    if ! grep -q 'ARGUMENT1,26,"Expected 25"' "$SRC"; then
        cp "$OUT/floattests.s.orig" "$SRC"
        echo "negative control could not patch its expectation -- aborting"
        exit 1
    fi
    trap 'cp "$OUT/floattests.s.orig" "$SRC"; rm -rf "$OUT"' EXIT
    echo "negative control: asserting 20.0+5.0=26, expecting a failure line"
fi

if [ "$NEG" -eq 1 ]; then
    SUITES="floats:2"
else
    SUITES="eval:1 floats:2 tokens:3 ops-int:4 ops-float:7 ops-str:8 statements:5 funcs:6"
fi

for pair in $SUITES; do
    SUITE=${pair%%:*}
    TEST_SUITE=${pair##*:}
    echo "suite: $SUITE"

    ASMLOG="$OUT/asm-$SUITE.log"
    64tass/64tass.exe \
        -D SYSTEM=3 -D UNITTEST=1 -D TEST_SUITE="$TEST_SUITE" -D TRACE_LEVEL=0 -D UARTSUPPORT=0 \
        --long-address --flat -b --m65816 \
        -o "$WOUT/tests-$SUITE.bin" \
        --list="build/tests-$SUITE.lst" --labels="build/tests-$SUITE.lbl" \
        -I basic816/src \
        basic816/src/basic816.s >"$ASMLOG" 2>&1
    if grep -Eq "^basic816.*error|Error messages" "$ASMLOG"; then
        cat "$ASMLOG"
        exit 1
    fi
    [ -f "$OUT/tests-$SUITE.bin" ] || { echo "assembly produced no binary for $SUITE"; exit 1; }
    ls -l "$OUT/tests-$SUITE.bin"

    cp "$CORE_HOST/boot/fat32.img" "$OUT/scratch-$SUITE.img"
    "$PYTHON_CMD" - "$(pypath "$OUT/scratch-$SUITE.img")" "$(pypath "$OUT/tests-$SUITE.bin")" <<'PY'
import sys, warnings
warnings.filterwarnings("ignore", category=UserWarning)
from pyfatfs.PyFatFS import PyFatFS
img, binpath = sys.argv[1], sys.argv[2]
fs = PyFatFS(img)
with open(binpath, "rb") as f:
    data = f.read()
with fs.open("/TESTS.BIN", "wb") as g:
    g.write(data)
fs.close()
print("card: TESTS.BIN = %d bytes" % len(data))
PY
    [ $? -eq 0 ] || exit 1

    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout "$EMU_TIMEOUT" \
        "$EMU_HOST/build/x16emu.exe" -boot "$(winpath "$CORE_HOST/boot/boot.rom")" \
        -load "F00000,$(winpath "$(pwd)/$KERNEL")" \
        -sdcard "$WOUT/scratch-$SUITE.img" \
        -autokeys 'run TESTS.BIN\n' \
        -warp -gif "$WOUT/out-$SUITE.gif" >/dev/null 2>&1

    "$PYTHON_CMD" - "$(pypath "$OUT/out-$SUITE.gif")" "$(pypath "$(hostpath "$RT")/font_cp437.s")" "$NEG" "$SUITE" <<'PY'
import sys, re, io
import numpy as np
from PIL import Image, ImageFile
ImageFile.LOAD_TRUNCATED_IMAGES = True

gif, fontinc, negative, suite = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]

vals = []
for line in io.open(fontinc, encoding='utf-8'):
    m = re.match(r'\s*\.byte\s+(.*)$', line.split(';')[0])
    if m:
        vals += [int(x.strip().lstrip('$'), 16)
                 for x in m.group(1).split(',') if x.strip()]

# Map the 8-byte glyph bitmap to its character, as a single 64-bit key
# so a whole frame can be looked up vectorised.
def key_of(rows8):
    k = 0
    for b in rows8:
        k = (k << 8) | int(b)
    return k

glyph = {}
for _c in range(0x20, 0x7F):
    glyph[key_of(vals[_c * 8:(_c + 1) * 8])] = chr(_c)

im = Image.open(gif)
BIT = (0x80 >> np.arange(8)).astype(np.uint64)
PLACE = (np.uint64(256) ** np.arange(7, -1, -1, dtype=np.uint64))

def frame_rows(img):
    # (60,80) array of 64-bit glyph keys -> list of 60 text rows.
    a = np.asarray(img.convert('RGB'))[:480, :640]
    on = a.any(axis=2)                                  # non-black = lit
    cells = on.reshape(60, 8, 80, 8).transpose(0, 2, 1, 3)   # r,col,y,x
    bytes8 = (cells * BIT).sum(axis=3).astype(np.uint64)     # r,col,y
    keys = (bytes8 * PLACE).sum(axis=2)                      # r,col
    out = []
    for r in range(60):
        out.append("".join(glyph.get(int(k), '?')
                           for k in keys[r]).rstrip())
    return out

# Union every frame's rows in first-seen order: the console scrolls, so
# no single frame holds the whole log.
#
# A warp-mode run is tens of thousands of frames but only a few hundred
# distinct screens, so hash the raw frame first and only pay for the
# glyph decode when the picture actually changed.
seen, log, frames, decoded = set(), [], 0, 0
prev = None
stop_decode = False
while True:
    try:
        im.seek(frames); im.load()
    except (EOFError, OSError, IndexError):
        break
    frames += 1
    raw = im.tobytes()
    if raw == prev:
        continue
    prev = raw
    decoded += 1
    for t in frame_rows(im):
        if t and t not in seen:
            seen.add(t)
            log.append(t)
            if negative and ("FAILED" in t or re.search(r"\[[0-9A-F]{2,8}\]", t)):
                stop_decode = True
            if not negative and "TST_BASIC" in t and "PASSED" in t:
                stop_decode = True
    if stop_decode:
        break

if frames == 0:
    sys.exit("no decodable frame -- did the emulator run?")

# What a failing assertion actually looks like on screen.
#
# UT_FAIL_AD (tests/unittests.s) logs the macro's message and then the
# offending value in brackets -- "Expected $3aa3d70a [3AA3D708]". It
# never prints the word FAILED, so grepping for FAILED alone reports a
# green run over a corpus full of red. Match the bracketed hex value
# that every UT_FAIL_* path emits, and keep FAILED for the paths that
# do print it.
FAILRE = re.compile(r"\[[0-9A-F]{2,8}\]")
failed = [r for r in log if "FAILED" in r or FAILRE.search(r)]
finished = any("TST_BASIC" in r and "PASSED" in r for r in log)

def dump():
    for r in log:
        print("   ", r)

if negative:
    if not failed:
        print("FAIL (negative control): 20.0+5.0 was asserted to be 26 and")
        print("      nothing was reported -- the harness cannot see failures")
        dump()
        sys.exit(1)
    print("PASS (negative control): the broken expectation was reported")
    for r in failed:
        print("   ", r)
    sys.exit(0)

if failed:
    print("FAIL: %d failing assertion(s) in the %s suite" % (len(failed), suite))
    dump()
    sys.exit(1)
if not finished:
    print("FAIL: the %s suite did not run to completion (no TST_BASIC PASSED)" % suite)
    dump()
    sys.exit(1)

print("PASS: BASIC816's %s suite is green on the X816" % suite)
print("      (%d frames, %d distinct screens, %d log lines)" % (frames, decoded, len(log)))
dump()
PY
    [ $? -eq 0 ] || exit 1
done

if [ "$NEG" -eq 0 ]; then
    echo "PASS: BASIC816's split unit-test corpus is green on the X816"
fi

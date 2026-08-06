#!/usr/bin/env bash
# Boot SuperBasic on the X816 emulator and type at the REPL.
#
# The whole phase-1 stack is under test at once: the resident kernel
# boots from the firmware region, its shell EXECs BASIC.BIN off a real
# FAT32 card, BASIC comes up on the kernel console, and every keystroke
# travels the real SMC path (-autokeys). The checks:
#
#   1. the greeting banner prints    - SCREEN_PUTC crossing works at all
#   2. READY appears                 - the REPL reached its prompt
#   3. `PRINT 1` answers `1`         - tokenizer, interpreter, ITOS and
#                                      the software divide (DIVINT10)
#   4. `XYZZY` answers `Syntax error`- the error path
#   5. float math in direct mode     - the software FP engine
#   6. `10 PRINT 1.5` + `RUN`        - a float literal parsed out of
#                                      STORED program text. Worth its own
#                                      check: PARSENUM counts digits in Y
#                                      and then advances BIP by it, so a
#                                      math routine that clobbers Y sends
#                                      the interpreter into the middle of
#                                      the program. Direct mode hides that
#                                      (the bad pointer lands in INPUTBUF
#                                      and finds a NUL); only RUN shows it.
#
#   ./run-emu.sh              build and run
#   ./run-emu.sh --negative   corrupt the image magic: EXEC must refuse
#                             it and no banner may print, proving check
#                             1 can fail
#
# Requires: pip install pillow pyfatfs, and a built X816_Calypsi
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

# A scratch card with BASIC.BIN on it, written by pyfatfs -- an
# independent FAT32 implementation, as everywhere else in the tree.
cp "$CORE/boot/fat32.img" "$OUT/scratch.img"
python - "$WOUT/scratch.img" "$WOUT/basic.bin" <<'PY'
import sys
from pyfatfs.PyFatFS import PyFatFS
img, binpath = sys.argv[1], sys.argv[2]
fs = PyFatFS(img)
with open(binpath, "rb") as f:
    data = f.read()
with fs.open("/BASIC.BIN", "wb") as g:
    g.write(data)
fs.close()
print("card: BASIC.BIN = %d bytes" % len(data))
PY
[ $? -eq 0 ] || exit 1

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 90 \
    "$EMU/build/x16emu.exe" -boot "$(cygpath -m "$CORE/boot/boot.rom")" \
    -load "F00000,$(cygpath -m "$(pwd)/$KERNEL")" \
    -sdcard "$WOUT/scratch.img" \
    -autokeys 'run BASIC.BIN\n                                        PRINT 1\n                                        XYZZY\n                                        PRINT 10/4\n                                        PRINT 2^10\n                                        PRINT 1/0\n                                        10 PRINT 1.5\n                                        RUN\n' \
    -warp -gif "$WOUT/out.gif" >/dev/null 2>&1

python - "$WOUT/out.gif" "$RT/font_cp437.s" "$NEG" <<'PY'
import sys, re, io
from PIL import Image, ImageFile
ImageFile.LOAD_TRUNCATED_IMAGES = True

gif, fontinc, negative = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

vals = []
for line in io.open(fontinc, encoding='utf-8'):
    m = re.match(r'\s*\.byte\s+(.*)$', line.split(';')[0])
    if m:
        vals += [int(x.strip().lstrip('$'), 16)
                 for x in m.group(1).split(',') if x.strip()]
glyph = {}
for _c in range(0x20, 0x7F):
    glyph[tuple(vals[_c * 8:(_c + 1) * 8])] = chr(_c)

im = Image.open(gif)
n = 0
while True:
    try:
        im.seek(n); im.load(); n += 1
    except (EOFError, OSError, IndexError):
        break
if n == 0:
    sys.exit("no decodable frame -- did the emulator run?")
im.seek(n - 1)
px = im.convert('RGB').load()

def row_text(r):
    out = ""
    for col in range(80):
        bits = []
        for y in range(8):
            b = 0
            for x in range(8):
                if px[col * 8 + x, r * 8 + y] != (0, 0, 0):
                    b |= 0x80 >> x
            bits.append(b)
        out += glyph.get(tuple(bits), '?')
    return out.rstrip()

rows = [row_text(r) for r in range(60)]
body = "\n".join(r for r in rows if r)

def fail(msg):
    print("FAIL:", msg)
    for i, r in enumerate(rows):
        if r:
            print(f"  {i}: {r!r}")
    sys.exit(1)

banner = any("SuperBasic" in r for r in rows)

if negative:
    if banner:
        fail("banner printed despite a corrupted image magic -- "
             "EXEC's magic check is not what admitted the program")
    print("PASS (negative control): corrupted magic, no banner -- "
          "EXEC refused the image as designed")
    sys.exit(0)

if not banner:
    fail("no greeting banner -- BASIC.BIN did not run or SCREEN_PUTC is broken")
if not any("READY" in r for r in rows):
    fail("no READY prompt")
if not any(r.strip() == "1" for r in rows):
    fail("`PRINT 1` did not answer 1")
if not any("Syntax error" in r for r in rows):
    fail("`XYZZY` did not report a syntax error")
# FTOS always emits BASIC816's 6-significant-digit form, with an
# exponent suffix whenever the decimal exponent is not zero -- so 2.5
# prints as "2.50000" and 1024 as "1.02400E03". That is upstream
# formatting, identical on the C256; assert what the interpreter really
# says rather than the shape a calculator would use.
if not any("2.50000" in r for r in rows):
    fail("`PRINT 10/4` did not answer 2.50000 (software float divide)")
if not any("1.02400E03" in r for r in rows):
    fail("`PRINT 2^10` did not answer 1.02400E03 (integer power)")
if not any("Division by zero" in r for r in rows):
    fail("`PRINT 1/0` did not report division by zero")
if not any("1.50000" in r for r in rows):
    fail("`RUN` of a stored float literal did not answer 1.50000")

print("PASS: SuperBasic booted from the card, printed 1, did float math")
print("      in both direct and program mode, and rejected bad input --")
print("      all through the kernel console")
for r in rows:
    if r:
        print("   ", r)
PY

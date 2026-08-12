#!/usr/bin/env bash
# Launch the resident editor from SuperBasic and prove control returns -- and
# that the FILE SuperBasic named was actually opened.
#
# The name used to be BASIC.TX, which is not on the card: that proved the name
# reached the editor and nothing about opening it. It is now /HELLO.TXT, which
# is, so the editor's K_FS_OPEN path runs for real through the K_EDIT crossing.
# The shell exercises the same load and the same save (X816_Calypsi
# programs/shell/run-editfile.sh); what this adds is the language caller's
# register and DBR discipline around it.
set -eu

. "$(dirname "$0")/../X816_Calypsi/runtime/calypsi.sh"
cd "$(dirname "$0")"

hostpath () {
    case "$1" in
        /c/*)
            if [ -d /c ]; then
                printf '%s\n' "$1"
            else
                printf '/mnt/c/%s\n' "${1#/c/}"
            fi
            ;;
        *) printf '%s\n' "$1" ;;
    esac
}

winpath () {
    cygpath -m "$1" 2>/dev/null || wslpath -m "$(hostpath "$1")" 2>/dev/null || echo "$1"
}

pypath () {
    if [ "$PYTHON_WIN" -eq 1 ]; then
        winpath "$1"
    else
        hostpath "$1"
    fi
}

CORE_HOST=$(hostpath "$CORE")
EMU_HOST=$(hostpath "$EMU")

PYTHON_USER=${USER:-$(id -un 2>/dev/null || echo jyv)}
PYTHON_LOCAL_MSYS="/c/Users/$PYTHON_USER/AppData/Local/Programs/Python/Python312/python.exe"
PYTHON_LOCAL_WSL=$(hostpath "$PYTHON_LOCAL_MSYS")
PYTHON_CMD=
PYTHON_WIN=0
for candidate in ${PYTHON:-} python python3 python.exe "$PYTHON_LOCAL_MSYS" "$PYTHON_LOCAL_WSL" py.exe; do
    [ -n "$candidate" ] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -c "import PIL; from pyfatfs.PyFatFS import PyFatFS" >/dev/null 2>&1; then
        PYTHON_CMD=$candidate
        case "$candidate" in
            *.exe) PYTHON_WIN=1 ;;
        esac
        break
    fi
done
[ -n "$PYTHON_CMD" ] || { echo "python with pillow and pyfatfs missing"; exit 1; }

KERNEL="../X816_Calypsi/programs/shell/kernel.bin"
[ -f "$KERNEL" ] || { echo "kernel.bin missing -- run sh build.sh in X816_Calypsi/programs/shell"; exit 1; }

./build.sh >/dev/null 2>&1 || exit 1

mkdir -p build
OUT=$(mktemp -d -p "$(pwd)/build" edit-smoke.XXXXXX)
trap 'rm -rf "$OUT"' EXIT
WOUT=$(winpath "$OUT")

cp "$CORE_HOST/boot/fat32.img" "$OUT/scratch.img"
"$PYTHON_CMD" tools/putfile.py \
    "$(pypath "$OUT/scratch.img")" \
    "$(pypath "$(pwd)/build/basic.bin")" BASIC.BIN >/dev/null || exit 1

POWERSHELL=${POWERSHELL:-powershell.exe}
"$POWERSHELL" -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$(pwd)/run-edit-capture.ps1")" \
    -Emu "$(winpath "$EMU_HOST/build/x16emu.exe")" \
    -Boot "$(winpath "$CORE_HOST/boot/boot.rom")" \
    -Kernel "$(winpath "$(pwd)/$KERNEL")" \
    -Sdcard "$WOUT/scratch.img" \
    -Gif "$WOUT/out.gif" \
    -Keys 'run BASIC.BIN\n          POKE &h7fe,3:EDIT "HELLO.TXT":PRINT 7777+PEEK(&h7fb)\n' >/dev/null

"$PYTHON_CMD" - "$(pypath "$OUT/out.gif")" "$(pypath "$(hostpath "$RT")/font_cp437.s")" <<'PY'
import sys, re, io
from collections import Counter
from PIL import Image, ImageFile
ImageFile.LOAD_TRUNCATED_IMAGES = True

gif, fontinc = sys.argv[1:]

vals = []
for line in io.open(fontinc, encoding="utf-8"):
    m = re.match(r"\s*\.byte\s+(.*)$", line.split(";")[0])
    if m:
        vals += [int(x.strip().lstrip("$"), 16)
                 for x in m.group(1).split(",") if x.strip()]
glyph = {tuple(vals[c * 8:(c + 1) * 8]): chr(c) for c in range(0x20, 0x7F)}

def frame_row(img, r):
    px = img.convert("RGB").load()
    out = ""
    for col in range(80):
        colors = []
        for y in range(8):
            for x in range(8):
                colors.append(px[col * 8 + x, r * 8 + y])
        bg = Counter(colors).most_common(1)[0][0]
        bits = []
        for y in range(8):
            b = 0
            for x in range(8):
                if px[col * 8 + x, r * 8 + y] != bg:
                    b |= 0x80 >> x
            bits.append(b)
        ch = glyph.get(tuple(bits))
        if ch is None:
            # A glyph that lights more than half its cell -- 'B', 'R', 'N' --
            # makes its own ink the most common colour, so the pattern comes
            # out inverted and decodes to '?'. Try the complement before
            # giving up, or "FROM" reads as "F?OM" and a content check on
            # real text can never pass.
            ch = glyph.get(tuple((~b) & 0xFF for b in bits), "?")
        out += ch
    return out.rstrip()

def frame_rows(img):
    return [frame_row(img, r) for r in range(60)]

im = Image.open(gif)
frames = 0
seen_typed = False
seen_length = False
seen_marker = False
seen_file = False
last_rows = []
while frames < 800:
    try:
        im.seek(frames); im.load()
    except (EOFError, OSError, IndexError):
        break
    rows = frame_rows(im)
    body = "\n".join(rows).upper()
    seen_typed = seen_typed or ("ABC" in body or "A?C" in body)
    # "HELLO.TXT" is 9 characters, so the marker moves with the name.
    seen_length = seen_length or "7786" in body
    seen_marker = seen_marker or "7786" in body
    seen_file = seen_file or "HELLO FROM FAT32 ON X816!" in body
    last_rows = rows
    frames += 1

if frames == 0:
    sys.exit("FAIL: no decodable frame -- did the emulator run?")

def fail(msg):
    print("FAIL:", msg)
    for r in last_rows:
        if r:
            print("   ", r)
    sys.exit(1)

if not seen_file:
    fail("the file SuperBasic named was not loaded into the editor's buffer")
if not seen_typed:
    fail("typed text did not render in the resident editor")
if not seen_length:
    fail("filename length copied by the resident editor was not visible after return")
if not seen_marker:
    fail("SuperBasic did not print the filename-length marker after EDIT returned")

print("PASS: SuperBasic opened a named file in the resident editor and resumed after exit")
for r in last_rows:
    if r:
        print("   ", r)
PY

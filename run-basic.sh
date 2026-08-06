#!/usr/bin/env bash
# Boot SuperBasic in X816_Emulator and hand the keyboard to you.
#
# run-emu.sh and run-tests.sh drive the same emulator headless -- dummy
# video, -warp, -autokeys, and a GIF decoded for a pass/fail verdict.
# That is what a test needs and exactly what you do NOT want when you
# just wish to type at the REPL. This one opens a real window, runs at
# real speed, and types nothing on your behalf.
#
#   ./run-basic.sh              build, then boot to the SuperBasic prompt
#   ./run-basic.sh -warp        ... any extra args go to the emulator
#
# The card is kept at build/card.img instead of a temp dir, so whatever
# you SAVE survives to the next run once phase 3 binds K_FS_*.
#
# At the shell prompt the program is launched with:  run BASIC.BIN
# (this script sends that one line for you; everything after is yours).
# ESC after BASIC exits reloads the shell.
#
# Requires: pip install pyfatfs, and a built X816_Calypsi
# examples/shell/kernel.bin (sh build.sh there).
set -eu

. "$(dirname "$0")/../X816_Calypsi/runtime/calypsi.sh"
cd "$(dirname "$0")"

KERNEL="../X816_Calypsi/examples/shell/kernel.bin"
[ -f "$KERNEL" ] || { echo "kernel.bin missing -- run sh build.sh in X816_Calypsi/examples/shell"; exit 1; }

./build.sh

mkdir -p build
CARD="build/card.img"
[ -f "$CARD" ] || cp "$CORE/boot/fat32.img" "$CARD"

if ! python tools/putfile.py \
        "$(cygpath -m "$(pwd)/$CARD")" \
        "$(cygpath -m "$(pwd)/build/basic.bin")" /BASIC.BIN; then
    echo "could not write the card -- if it is corrupt, delete $CARD"
    echo "and run again to rebuild it from fat32.img"
    exit 1
fi

echo
echo "Booting SuperBasic -- close the window or press ESC after QUIT to stop."
echo "Things worth trying (see PORT.md §11 for what is still missing):"
echo "    PRINT 10/4            software float divide      -> 2.50000"
echo "    PRINT 2^10            integer power              -> 1.02400E03"
echo "    A%=-20.0 : PRINT A%   FTOI sign fix              -> -20"
echo "    10 PRINT 1.5 : RUN    float literal from program -> 1.50000"
echo "    PRINT SIN(1)          transcendentals still THROW"
echo

exec "$EMU/build/x16emu.exe" \
    -boot "$(cygpath -m "$CORE/boot/boot.rom")" \
    -load "F00000,$(cygpath -m "$(pwd)/$KERNEL")" \
    -sdcard "$(cygpath -m "$(pwd)/$CARD")" \
    -autokeys 'run BASIC.BIN\n' \
    "$@"

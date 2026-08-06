#!/bin/bash
# Build SuperBasic for the X816: raw binary with the 8-byte "X816"
# header at $01:0000, ready for `run BASIC.BIN` from the shell.
set -e
cd "$(dirname "$0")"
mkdir -p build
64tass/64tass.exe \
    -D SYSTEM=3 -D UNITTEST=0 -D TRACE_LEVEL=0 -D UARTSUPPORT=0 \
    --long-address --flat -b --m65816 \
    -o build/basic.bin \
    --list=build/basic.lst --labels=build/basic.lbl \
    -I basic816/src \
    basic816/src/basic816.s
ls -l build/basic.bin

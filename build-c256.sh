#!/bin/bash
# Assemble the stock C256 FMX target.
#
# This is a COMPILE CHECK and nothing more. It exists because several
# files are shared with the X816 build -- dos.s, interpreter.s, tokens.s,
# statements.s, variables.s -- and a broken label or a syntax error in
# one of them should be caught in five seconds rather than by a reader.
#
# IT DOES NOT CHECK THE SIZE, and that is deliberate: see PORT.md
# section 23. The binary used to be held byte-identical to the upstream
# prebuilt (53,959 bytes) as a way of proving that portable behaviour had
# not moved. The SuperBasic language layer moves it on purpose, so the
# number stopped being a test and became a chore. Nothing consumes this
# binary; SuperBasic is the X816's BASIC.
set -e
cd "$(dirname "$0")"
mkdir -p build
64tass/64tass.exe \
    -D SYSTEM=2 -D C256_SKU=1 -D UNITTEST=0 -D TRACE_LEVEL=0 -D UARTSUPPORT=0 \
    --long-address --flat -b --m65816 \
    -o build/basic_c256.bin \
    -I basic816/src \
    basic816/src/basic816.s > build/c256.log 2>&1 \
  || { echo "C256 target FAILED to assemble -- see build/c256.log"; exit 1; }
echo "C256 target assembles: $(stat -c%s build/basic_c256.bin) bytes (size is not asserted)"

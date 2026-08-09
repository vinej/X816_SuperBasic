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
#   session G -- reading VRAM back, and VRAM to and from the card
#    14. PALGET/PALSAVE/PALLOAD    - a palette entry saved, destroyed and
#                                    restored. Entry 200 and not 5: the
#                                    TEXT colours are entries nothing ever
#                                    wrote, and a faithful round trip of
#                                    those puts junk back over the palette
#                                    the console draws with. The screen
#                                    went black on black and the decoder
#                                    read an empty screen -- help/PAL.TXT
#                                    warns about exactly this
#    15. TILEGET/TILEATTR/TMAP*    - VPOKE writes the cell, TILEGET reads
#                                    it, and the two share no code:
#                                    TILEGET derives the row stride from
#                                    the layer's config register. Layer 1,
#                                    because TMAPLOAD 0 restores the whole
#                                    text screen, assertions included
#    16. SPRITEGET/SPRITE*         - the image round trip is checked with
#                                    VPEEK, which is not how it was written
#
#   session H -- controllers and the mouse, with neither plugged in
#    17. JOYHIT                    - must say NO four times. This is what
#                                    the eight extra clocks are for
#    18. I2CPOKE, MOUSEON          - read back out of the SMC, so the 3
#                                    went to the hardware and returned
#    19. MX/MY after MOUSEAT       - the pointer is SuperBasic's own, and
#                                    MX-1 also proves the minus after a
#                                    no-argument function is not a negation
#
#   session I -- the three audio pages
#    20. FMINST through YMPEEK     - the shadow is a shadow of what was
#                                    WRITTEN, so it reports the patch
#                                    table arriving in the registers the
#                                    chip indexes by operator*8 + channel
#    21. PCMPLAY                   - VERA's AFLOW ENABLE, not the FIFO
#                                    level: reading the control register
#                                    calls audio_render(), and one typed
#                                    line is longer in guest time than
#                                    4 KB takes to drain. The enable is
#                                    set while the feeder runs and clear
#                                    after PCMRESET stops it
#    22. PLAY                      - the last note of "CDE" left in the
#                                    key-code register, so the string was
#                                    parsed and played and not just taken
#
#   session L -- PSG volume envelopes
#    23. ENV / ENVOFF / SOUND      - read straight out of the PSG's own
#                                    volume byte with VPEEK, so every
#                                    number is the hardware's and not
#                                    BASIC's. Two of them are HALVES of a
#                                    sweep, which is what makes this a
#                                    check on the RATE and not merely on
#                                    the level having moved
#
#   session M -- IMA ADPCM, against an independent decoder
#    24. ADPCMPLAY on a WAV        - Python builds the file AND works
#                                    out what it must decode to; BASIC
#                                    PEEKs the decode buffer. The
#                                    nibbles are pseudo-random on
#                                    purpose: a real signal lives in the
#                                    low half of the step table and
#                                    would never reach either clamp,
#                                    which is the arithmetic most likely
#                                    to be wrong
#
#   session N -- the paths session M does not reach
#    25. a RAW headerless stream   - decoded from a predictor of 0, and
#                                    PCMRATE left alone because a raw
#                                    file does not say what it is
#    26. a STEREO IMA WAV          - REFUSED. Everything else about the
#                                    file is well formed, so the channel
#                                    count being looked at is the only
#                                    thing that can refuse it
#
#   session O -- the console's two colour statements
#    27. SETBGCOLOR / SETBORDER    - read back out of the TEXT MATRIX
#                                    ATTRIBUTE BYTE and out of VERA's
#                                    border register. 71 is the one
#                                    that matters: background 4 with
#                                    the foreground STILL 7 from an
#                                    earlier TEXTCOLOR, which is the
#                                    whole point of setting half of a
#                                    pair
#
#   session P -- the third token table, and FOR/NEXT with its name
#    28. VER                      - a keyword in TOKENS3, reached as
#                                   $FF $FF <sub>. It is a NO-ARGUMENT
#                                   function on purpose: the minus
#                                   rule is the one place that has to
#                                   know which TABLE a token came
#                                   from, so VER-1 is the check that
#                                   the third table is UNDERSTOOD and
#                                   not merely reached
#    29. FOR ... NEXT I           - the commonest loop in BASIC, which
#                                   every session before this one
#                                   wrote as bare NEXT. It ran and
#                                   then threw a syntax error on the
#                                   pass that ENDS it
#
#   ./run-emu.sh              build and run
#   ./run-emu.sh --negative   corrupt the image magic: EXEC must refuse
#                             it and no banner may print, proving check
#                             1 can fail
#
# DO NOT EDIT THIS FILE WHILE IT IS RUNNING. Bash reads a script
# incrementally, by file offset, so inserting a line ahead of where it
# has got to moves everything under its feet: the run dies with a syntax
# error pointing at a line that is perfectly valid, and the error has
# nothing to do with what is being tested. It cost two runs of about
# twenty minutes each to notice.
#
# A run takes long enough that wanting to edit it meanwhile is normal, so
# do the obvious thing rather than waiting:
#
#     cp run-emu.sh .run-frozen.sh && bash .run-frozen.sh
#
# and NOT into /tmp: the script finds the emulator, the core and the
# runtime through `dirname $0`, so a copy outside this directory cannot
# see any of them. .run-frozen.sh is gitignored.
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
    'SEEK #1,3' \
    'PRINT LOC(1)' \
    'LINPUT #1,C$' \
    'PRINT C$' \
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

# A source file with NO LINE NUMBERS, and one line that brings its own.
# LOAD gives the rest the next number going, so a program written in an
# editor never has to mention them -- and a file that already had them
# still loads exactly as it did.
printf 'PRINT "NONUM"

LABEL again

100 PRINT "HUNDRED"

PRINT "AFTER"

' > "$OUT/n.bas" 

# Reading VRAM back, and moving it to and from the card.
#
# Every check here is a ROUND TRIP through the card verified by a
# different path from the one that wrote it: VPOKE puts a byte in, the
# save takes it out to a file, VPOKE destroys it, the load brings it
# back, and VPEEK or a GET function reads it. A statement that quietly
# did nothing fails at the step after the destroy, which is the point of
# destroying it.
#
# ENTRY 200, not entry 5, and the range saved is one this program WROTE.
# The first version saved entries 0-7 and loaded them back, and the whole
# screen went black -- not a crash, and not a bug in PALSAVE. Those are
# the TEXT colours, the program never wrote them, and help/PAL.TXT says
# in as many words that an entry nobody wrote does not read back as the
# colour in use. So the round trip faithfully restored junk over the
# palette the console was drawing with, the glyphs became black on black,
# and the decoder read an empty screen. The page's own warning, arrived
# at the hard way. Entry 1 is the one exception here: session C already
# proves it can be changed with the text still readable.
#
# LAYER 1, not the console. TMAPLOAD 0 would restore the whole text
# screen to what it was when saved -- wiping everything printed in
# between, including the assertions still to be read. Layer 1 has a map
# of its own at $12000 and is not being displayed.
#
# LAYERMODE 1,0 makes that map 32x32, which is 2 KB. The first version
# used 128x32 and the 8 KB transfer was long enough that -autokeys DROPPED
# the first two characters of the line after it: "VPOKE" arrived as
# "oKE" and the step that destroys the cell never ran, which would have
# left the reload proving nothing. A smaller map is the fix; the code
# path is identical.
KEYS_G=$(keys_of \
    'PAL 200,&h0F00' \
    'PRINT PALGET(200)' \
    'SETCOLOR 1,&h000F' \
    'PRINT PALGET(1)' \
    'SETCOLOR 200,0' \
    'PALSAVE "P.BIN",200,4' \
    'PAL 200,0' \
    'PRINT PALGET(200)' \
    'PALLOAD "P.BIN",200' \
    'PRINT PALGET(200)' \
    'TILEMAP 1,&h12000' \
    'LAYERMODE 1,0' \
    'VPOKE &h12114,66' \
    'PRINT TILEGET(1,10,4)' \
    'TILEATTR 1,10,4,5' \
    'PRINT VPEEK(&h12115)' \
    'TMAPSAVE 1,"M.BIN"' \
    'VPOKE &h12114,88' \
    'PRINT TILEGET(1,10,4)' \
    'TMAPLOAD 1,"M.BIN"' \
    'PRINT TILEGET(1,10,4)' \
    'TILESET 1,&h16000' \
    'VPOKE &h16000,77' \
    'TILESAVE 1,"G.BIN",16' \
    'VPOKE &h16000,0' \
    'TILELOAD 1,"G.BIN"' \
    'PRINT VPEEK(&h16000)' \
    'SPRITEAT 2,300,200' \
    'PRINT SPRITEGET(2,0)' \
    'PRINT SPRITEGET(2,1)' \
    'SPRITEIMG 2,&h14000' \
    'SPRITESIZE 2,0,0' \
    'VPOKE &h14000,90' \
    'SPRITESAVE 2,"S.BIN"' \
    'VPOKE &h14000,0' \
    'SPRITELOAD 2,"S.BIN"' \
    'PRINT VPEEK(&h14000)')

# Controllers and the mouse, with neither plugged in -- which sounds
# useless and is where the two best checks on this page live.
#
# JOYHIT is the whole point of the eight extra clocks: with no pad in
# the socket every one of the four must answer 0. If the presence read
# were wrong in the obvious way -- clocking zeros out of a register that
# has run dry and calling that "present" -- this is what would catch it.
#
# I2CPOKE and MOUSEON are checked by asking the SYSTEM CONTROLLER what
# it now thinks it is. Writing 3 to register $20 makes it an
# Intellimouse and $22 reports that back, so the 3 has been out to the
# hardware and returned; nothing in BASIC computed it. MOUSEON 1 does
# the same write for itself, which is why it is asserted the same way.
KEYS_H=$(keys_of \
    'PRINT JOY(0)' \
    'JOYSCAN' \
    'PRINT JOYHIT(0)' \
    'PRINT JOYHIT(3)' \
    'PRINT JOYX(0)' \
    'PRINT JOYY(0)' \
    'PRINT JOYFIRE(0)' \
    'I2CPOKE &h42,&h20,3' \
    'PRINT I2CPEEK(&h42,&h22)' \
    'MOUSEON 0' \
    'PRINT I2CPEEK(&h42,&h22)' \
    'MOUSEON 1' \
    'PRINT I2CPEEK(&h42,&h22)' \
    'MOUSEAT 321,50' \
    'PRINT MX' \
    'PRINT MY' \
    'PRINT MB' \
    'PRINT MWHEEL' \
    'PRINT MX-1' \
    'PRINT "JMOK"')

# Audio. The YM2151 answers no reads whatever, so YMPEEK is a shadow of
# what was written -- which makes it exactly the right instrument for
# checking FMINST, because the numbers it hands back came out of the
# patch table by way of FM_APPLY's register arithmetic. $C7, 4 and 32
# are patch 5's bytes landing in registers $20, $40 and $60, and FMINIT
# wrote $01 at $40 first, so a 4 there is FMINST having changed it.
#
# PCMPLAY is checked through VERA's AFLOW ENABLE BIT rather than through
# the FIFO level, and the first version got that wrong: reading the
# control register calls audio_render(), which drains the FIFO by
# however much guest time has passed -- and one typed line, padded to
# forty characters, is longer in guest time than 4 KB takes to drain at
# 24 kHz. The level is simply not observable a statement later.
#
# The enable bit is. It is SET while the feeder is running and the
# handler clears it itself when the sample runs out, so 8 after PCMPLAY
# says the interrupt-driven feeder started, and 0 after PCMRESET says it
# can be stopped. Rate 1 is about 381 Hz, which makes eight kilobytes
# twenty seconds long -- comfortably longer than the session.
KEYS_I=$(keys_of \
    'FMINIT' \
    'FMINST 0,5' \
    'PRINT YMPEEK(&h20)' \
    'PRINT YMPEEK(&h40)' \
    'PRINT YMPEEK(&h60)' \
    'PCMCTRL 10' \
    'PRINT PEEK(&h9F3B) AND 15' \
    'PRINT PCMEMPTY' \
    'PCMRATE 1' \
    'PCMPLAY "W.RAW"' \
    'PRINT PEEK(&h9F26) AND 8' \
    'PRINT PCMEMPTY+1' \
    'PCMRESET' \
    'PRINT PEEK(&h9F26) AND 8' \
    'PLAY "T240 L16 CDE"' \
    'PRINT YMPEEK(&h28)' \
    'PRINT "AUDOK"')

# The SuperBasic language layer. A program rather than typed lines,
# because the block form of IF is about LINES: the scanner reads the
# first token of each one, so IF, ELSE and ENDIF have to start their own.
#
# Four BAD markers, none of which may appear, and they fail from
# different directions: a true branch that also ran its ELSE, a false
# branch that ran anyway, an inner IF whose ENDIF was taken for the
# outer one, and the classic THEN <line> form breaking.
KEYS_J=$(keys_of     '10 A=1'     '20 IF A=1 THEN'     '30 PRINT "TRUE1"'     '40 ELSE'     '50 PRINT "BAD1"'     '60 ENDIF'     '70 IF A=2 THEN'     '80 PRINT "BAD2"'     '90 ELSE'     '100 PRINT "TRUE2"'     '110 ENDIF'     '120 IF A=1 THEN'     '130 IF A=2 THEN'     '140 PRINT "BAD3"'     '150 ENDIF'     '160 PRINT "NEST"'     '170 ENDIF'     '180 IF A=1 THEN 200'     '190 PRINT "BAD4"'     '200 COUNTER=5'     '210 COUNTX=7'     '220 PRINT COUNTER+COUNTX'     '230 X=42'     '240 PROC show(7)'     '250 PRINT X'     '300 DEFPROC show(X)'     '310 PRINT X'     '320 ENDPROC'     'RUN'
    )

# Labels, in all three places one can be used, and AUTO.
#
# AUTO is checked by what it PUTS ON THE SCREEN: it prints the number
# before the line is typed, so 400 and 405 appear at the head of two
# lines that were never given one. The whitespace line after them is the
# exit -- and LIST proves it worked, because a line 410 would exist if
# it had not.
KEYS_K=$(keys_of \
    '10 GOTO start' \
    '20 PRINT "BADG"' \
    '30 LABEL start' \
    '40 GOSUB helper' \
    '50 A=1' \
    '60 IF A=1 THEN finish' \
    '70 PRINT "BADT"' \
    '80 LABEL finish' \
    '90 PRINT "ATFINISH"' \
    '100 END' \
    '200 LABEL helper' \
    '210 PRINT "INHELPER"' \
    '220 RETURN' \
    'RUN' \
    'NEW' \
    'AUTO 400,5' \
    'PRINT "AUTOONE"' \
    ' ' \
    'LIST' \
    'NEW' \
    'LOAD "N.BAS"' \
    'LIST')

# PSG volume envelopes, read back out of the PSG's own volume byte.
#
# VPEEK, because the PSG IS VRAM -- $1F9C0 plus four bytes a voice, and
# the volume is the third of the four. So every number below came out of
# the hardware; nothing here asks BASIC what it thinks it wrote. The two
# channel bits live above the volume in the same byte, which is why the
# readings are 192 plus a level rather than a level.
#
# A PROGRAM and not typed lines, and that is the whole reason this can
# assert anything. Envelopes move in real time, so a check on where one
# has GOT to is a check on how long ago the line before it ran -- and
# under -autokeys that is however long the SMC took to deliver forty
# padding characters. Inside a program the interval is WAIT's, which is
# the same clock the envelope is stepping off.
#
# The two halves are the point. Voice 1 is read 60 frames into a
# 120-frame attack and voice 4 30 frames into a 60-frame release, and
# both must be at 31 and 30 of 63. A level that merely MOVED would pass
# every other line here; a rate that was out by a factor of two would
# read 255 or 207 and fail only these.
KEYS_L=$(keys_of \
    '10 ENV 0,0,0,63,0' \
    '20 SOUND 0,440,63' \
    '30 PRINT VPEEK(&h1F9C2)' \
    '40 ENVOFF 0' \
    '50 PRINT VPEEK(&h1F9C2)' \
    '60 ENV 1,120,0,63,0' \
    '70 SOUND 1,440,63' \
    '80 A=VPEEK(&h1F9C6)' \
    '90 WAIT 1000' \
    '100 B=VPEEK(&h1F9C6)' \
    '110 WAIT 3000' \
    '120 PRINT VPEEK(&h1F9C6)' \
    '130 PRINT A' \
    '140 PRINT B' \
    '150 ENV 2,0,60,20,0' \
    '160 SOUND 2,440,63' \
    '170 WAIT 2000' \
    '180 PRINT VPEEK(&h1F9CA)' \
    '190 ENV 4,0,0,63,60' \
    '200 SOUND 4,440,63' \
    '210 ENVOFF 4' \
    '220 WAIT 500' \
    '230 PRINT VPEEK(&h1F9D2)' \
    '240 WAIT 2000' \
    '250 PRINT VPEEK(&h1F9D2)' \
    '260 ENV 3,30,0,63,30' \
    '270 ENV 3,0,0,0,0' \
    '280 SOUND 3,440,40' \
    '290 PRINT VPEEK(&h1F9CE)' \
    '300 PRINT "ENVOK"' \
    'RUN')

# IMA ADPCM, checked against a decoder that is not this one.
#
# Python builds the file AND works out what it has to decode to, writing
# the answers to adpexp.txt for the check below to read. So the numbers
# BASIC prints are compared against arithmetic done somewhere else, in
# another language, from the published tables -- not against anything
# this port computed.
#
# THE NIBBLES ARE PSEUDO-RANDOM ON PURPOSE. A real signal spends its
# whole life in the low half of the step table, and the predictor clamps
# at +32767 and -32768 would never run. They are the arithmetic most
# likely to be wrong -- the intermediate reaches 1.875 * 32767, which
# fits a 16-bit word but not a signed one -- and the least likely to be
# reached by a well-behaved test tone. With random nibbles both clamps
# fire within the first few hundred samples.
#
# Forty blocks, each with its own starting predictor, because an IMA WAV
# RESTARTS at every block. Sample 505 is the second block's header
# predictor and it is the one that says so.
python - "$OUT/t.wav" "$OUT/adpexp.txt" "$OUT/raw.ima" "$OUT/bad.wav" <<'PYADP'
import sys, struct

STEP = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,
        66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,
        371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,
        1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,
        5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,
        16818,18500,20350,22385,24623,27086,29794,32767]
IDX = [-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8]

BLOCK, NBLOCK, RATE = 256, 40, 11025

def nibbles(seed, n):
    x, out = seed, []
    for _ in range(n):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        out.append((x >> 16) & 15)
    return out

def decode(nb, pred, index, out):
    for n in nb:
        step = STEP[index]
        diff = step >> 3
        if n & 4: diff += step
        if n & 2: diff += step >> 1
        if n & 1: diff += step >> 2
        pred = pred - diff if n & 8 else pred + diff
        pred = max(-32768, min(32767, pred))
        index = max(0, min(88, index + IDX[n]))
        out.append(pred)

# ---- the WAV, in blocks ----
data, samples = bytearray(), []
for b in range(NBLOCK):
    pred, index = (b * 1000) - 8000, (b * 7) % 89
    data += struct.pack('<hBB', pred, index, 0)
    samples.append(pred)                 # the header's predictor IS sample 0
    nb = nibbles(b + 1, (BLOCK - 4) * 2)
    for i in range(0, len(nb), 2):
        data.append(nb[i] | (nb[i + 1] << 4))
    decode(nb, pred, index, samples)

fmt = struct.pack('<HHIIHHHH', 17, 1, RATE, RATE // 2, BLOCK, 4, 2,
                  1 + (BLOCK - 4) * 2)
chunks = b'fmt ' + struct.pack('<I', len(fmt)) + fmt
chunks += b'data' + struct.pack('<I', len(data)) + bytes(data)
open(sys.argv[1], 'wb').write(
    b'RIFF' + struct.pack('<I', 4 + len(chunks)) + b'WAVE' + chunks)

# ---- a RAW stream: no RIFF, no blocks, predictor 0 by convention ----
nb = nibbles(99, 8000)
raw = bytearray()
for i in range(0, len(nb), 2):
    raw.append(nb[i] | (nb[i + 1] << 4))
open(sys.argv[3], 'wb').write(bytes(raw))
rawsamples = []
decode(nb, 0, 0, rawsamples)

# ---- and a STEREO IMA WAV, which has to be refused ----
badfmt = struct.pack('<HHIIHHHH', 17, 2, 11025, 11025, 512, 4, 2, 1017)
d = bytes(1024)
bad = b'fmt ' + struct.pack('<I', len(badfmt)) + badfmt
bad += b'data' + struct.pack('<I', len(d)) + d
open(sys.argv[4], 'wb').write(
    b'RIFF' + struct.pack('<I', 4 + len(bad)) + b'WAVE' + bad)

# The bytes BASIC will be asked to PEEK, in the order it prints them.
with open(sys.argv[2], 'w') as f:
    for k in (0, 100, 504, 505):
        v = samples[k] & 0xFFFF
        f.write("%d\n%d\n" % (v & 0xFF, v >> 8))
    f.write("%d\n" % ((RATE + 190) // 381))      # VERA's rate register
    f.write("32\n")                              # 16-bit mode
    f.write("8\n")                               # AFLOW armed
    f.write("-\n")                               # the raw session starts here
    for k in (0, 50):
        v = rawsamples[k] & 0xFFFF
        f.write("%d\n%d\n" % (v & 0xFF, v >> 8))
    f.write("20\n")                              # PCMRATE, untouched
PYADP

# Sample k is two bytes at $0A:0000 + 2k, so 0, 100, 504 and 505 are
# $A0000, $A00C8, $A03F0 and $A03F2. 504 is the last sample of the first
# block and 505 the first of the second, which is where a decoder that
# ran on through the block header instead of restarting would part
# company with the reference.
# The console's two colour statements.
#
# The console map is at VRAM $00000, 128 cells wide, each cell a glyph
# and an attribute -- so (col,row)'s ATTRIBUTE is at row*256 + col*2 + 1,
# and 10241 and 10497 are rows 40 and 41 of column 0. The attribute is
# the kernel's layout, background in the HIGH nibble: 7 is white on
# black and $47 is white on blue.
#
# Rows 40 and 41 are chosen to be below the typed program and above
# where its output lands. The row printed on background 4 decodes as
# BLANK -- the reader treats any lit pixel as ink and a coloured
# background lights every pixel of the cell -- which is harmless,
# because what is asserted is the ATTRIBUTE and not the glyph, and is
# why the colours go back to 0 before anything is printed to be read.
# The third token table, and the FOR/NEXT bug it turned up.
#
# VER answers the kernel's version, (major << 8) | minor, and the
# kernel this was written against answers 1. It lives in TOKENS3 --
# three bytes in the line, $FF $FF $80 -- so every number below has
# come back through an escape that did not exist before.
#
# VER-1 is not padding. A minus after a no-argument function is a
# NEGATION unless the tokenizer asks what kind of token preceded it,
# and asking means knowing which table the sub-id belongs to: the
# same number means a different keyword in each. 0 is the answer
# only if all of that works.
#
# The FOR loops are the OTHER half. NEXT I ran correctly and then
# reported a syntax error, on the pass that ends the loop and only
# then -- so 6 (three times two, nested, with the inner loop closed
# by name) and the countdown 5 3 1 are what a fixed NEXT looks like.
# Bare NEXT is kept beside them because it always worked and must
# go on working.
KEYS_P=$(keys_of \
    '10 PRINT VER' \
    '20 PRINT VER-1' \
    '30 T=0' \
    '40 FOR I=1 TO 3' \
    '50 FOR J=1 TO 2' \
    '60 T=T+VER' \
    '70 NEXT J' \
    '80 NEXT I' \
    '90 PRINT T' \
    '100 FOR K=1 TO 2' \
    '110 NEXT' \
    '120 PRINT "BARE"' \
    '130 FOR L=5 TO 1 STEP -2' \
    '140 PRINT L' \
    '150 NEXT L' \
    '160 PRINT "TOKOK"' \
    'RUN' \
    'LIST')

KEYS_O=$(keys_of \
    '10 TEXTCOLOR 7,0' \
    '20 LOCATE 0,40' \
    '30 PRINT "A"' \
    '40 SETBGCOLOR 4' \
    '50 LOCATE 0,41' \
    '60 PRINT "B"' \
    '70 SETBGCOLOR 0' \
    '80 SETBORDER 5' \
    '90 A=PEEK(&h9F2C)' \
    '100 BORDER 9' \
    '110 B=PEEK(&h9F2C)' \
    '120 SETBORDER 0' \
    '130 LOCATE 0,45' \
    '140 PRINT VPEEK(10241)' \
    '150 PRINT VPEEK(10497)' \
    '160 PRINT A' \
    '170 PRINT B' \
    '180 PRINT "CONOK"' \
    'RUN')

KEYS_M=$(keys_of \
    '10 ADPCMPLAY "T.WAV"' \
    '20 PRINT PEEK(&hA0000)' \
    '30 PRINT PEEK(&hA0001)' \
    '40 PRINT PEEK(&hA00C8)' \
    '50 PRINT PEEK(&hA00C9)' \
    '60 PRINT PEEK(&hA03F0)' \
    '70 PRINT PEEK(&hA03F1)' \
    '80 PRINT PEEK(&hA03F2)' \
    '90 PRINT PEEK(&hA03F3)' \
    '100 PRINT PEEK(&h9F3C)' \
    '110 PRINT PEEK(&h9F3B) AND 32' \
    '120 PRINT PEEK(&h9F26) AND 8' \
    '130 PRINT "ADPOK"' \
    'RUN')

# The two paths session M does not reach. PCMRATE 20 first, and 20 again
# at the end: a raw stream carries no header and so must leave the rate
# where the program put it -- the WAV in session M moves it to 29, so
# the pair of sessions says the rate is taken from a header when there
# is one and only then.
#
# Line 90 must NOT print. The stereo file is well formed in every other
# way, so nothing but the channel count can refuse it.
KEYS_N=$(keys_of \
    '10 PCMRATE 20' \
    '20 ADPCMPLAY "RAW.IMA"' \
    '30 PRINT PEEK(&hA0000)' \
    '40 PRINT PEEK(&hA0001)' \
    '50 PRINT PEEK(&hA0064)' \
    '60 PRINT PEEK(&hA0065)' \
    '70 PRINT PEEK(&h9F3C)' \
    '80 ADPCMPLAY "BAD.WAV"' \
    '90 PRINT "NOTREACHED"' \
    'RUN')

# Eight kilobytes of square wave: more than the 4 KB FIFO, so the primer
# fills it, and about a third of a second at rate 64, so it is over well
# inside the WAIT that follows.
python - "$OUT/w.raw" <<'PYWAV'
import sys
d = bytearray()
for i in range(8192):
    d.append(0x60 if (i // 24) % 2 else 0xA0)
open(sys.argv[1], "wb").write(bytes(d))
PYWAV

# Each session gets its own card, written by pyfatfs -- an independent
# FAT32 implementation, as everywhere else in the tree -- so neither can
# be fooled by what the other left behind.
run_session () {        # $1 = tag, $2 = keys, then (path, name) pairs
    local tag="$1" keys="$2"
    cp "$CORE/boot/fat32.img" "$OUT/card$tag.img"
    python tools/putfile.py "$(cygpath -m "$OUT/card$tag.img")" \
        "$(cygpath -m "$OUT/basic.bin")" BASIC.BIN >/dev/null || return 1
    shift 2
    while [ $# -ge 2 ]; do      # any number of them: session N needs two,
        python tools/putfile.py "$(cygpath -m "$OUT/card$tag.img")" \
            "$(cygpath -m "$1")" "$2" >/dev/null || return 1
        shift 2
    done
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 90 \
        "$EMU/build/x16emu.exe" -boot "$(cygpath -m "$CORE/boot/boot.rom")" \
        -load "F00000,$(cygpath -m "$(pwd)/$KERNEL")" \
        -sdcard "$WOUT/card$tag.img" \
        -autokeys "$keys" \
        -warp -gif "$WOUT/out$tag.gif" >/dev/null 2>&1
    [ -f "$OUT/out$tag.gif" ]
}

run_session A "$KEYS_A" || { echo "session A produced no recording"; exit 1; }
if [ "$NEG" = "0" ]; then
    run_session B "$KEYS_B" || { echo "session B produced no recording"; exit 1; }
    run_session C "$KEYS_C" || { echo "session C produced no recording"; exit 1; }
    run_session D "$KEYS_D" || { echo "session D produced no recording"; exit 1; }
    run_session E "$KEYS_E" || { echo "session E produced no recording"; exit 1; }
    run_session F "$KEYS_F" "$OUT/t.bin" T.BIN || { echo "session F produced no recording"; exit 1; }
    run_session G "$KEYS_G" || { echo "session G produced no recording"; exit 1; }
    run_session H "$KEYS_H" || { echo "session H produced no recording"; exit 1; }
    run_session I "$KEYS_I" "$OUT/w.raw" W.RAW || { echo "session I produced no recording"; exit 1; }
    run_session J "$KEYS_J" || { echo "session J produced no recording"; exit 1; }
    run_session K "$KEYS_K" "$OUT/n.bas" N.BAS || { echo "session K produced no recording"; exit 1; }
    run_session L "$KEYS_L" || { echo "session L produced no recording"; exit 1; }
    run_session M "$KEYS_M" "$OUT/t.wav" T.WAV || { echo "session M produced no recording"; exit 1; }
    run_session N "$KEYS_N" "$OUT/raw.ima" RAW.IMA "$OUT/bad.wav" BAD.WAV || { echo "session N produced no recording"; exit 1; }
    run_session O "$KEYS_O" || { echo "session O produced no recording"; exit 1; }
    run_session P "$KEYS_P" || { echo "session P produced no recording"; exit 1; }
else
    cp "$OUT/outA.gif" "$OUT/outB.gif"      # unused: the check ends early
    cp "$OUT/outA.gif" "$OUT/outC.gif"
    cp "$OUT/outA.gif" "$OUT/outD.gif"
    cp "$OUT/outA.gif" "$OUT/outE.gif"
    cp "$OUT/outA.gif" "$OUT/outF.gif"
    cp "$OUT/outA.gif" "$OUT/outG.gif"
    cp "$OUT/outA.gif" "$OUT/outH.gif"
    cp "$OUT/outA.gif" "$OUT/outI.gif"
    cp "$OUT/outA.gif" "$OUT/outJ.gif"
    cp "$OUT/outA.gif" "$OUT/outK.gif"
    cp "$OUT/outA.gif" "$OUT/outL.gif"
    cp "$OUT/outA.gif" "$OUT/outM.gif"
    cp "$OUT/outA.gif" "$OUT/outN.gif"
    cp "$OUT/outA.gif" "$OUT/outO.gif"
    cp "$OUT/outA.gif" "$OUT/outP.gif"
fi

python - "$WOUT/outA.gif" "$WOUT/outB.gif" "$WOUT/outC.gif" "$WOUT/outD.gif" "$WOUT/outE.gif" "$WOUT/outF.gif" "$WOUT/outG.gif" "$WOUT/outH.gif" "$WOUT/outI.gif" "$WOUT/outJ.gif" "$WOUT/outK.gif" "$WOUT/outL.gif" "$WOUT/outM.gif" "$WOUT/outN.gif" "$WOUT/outO.gif" "$WOUT/outP.gif" "$RT/font_cp437.s" "$WOUT/adpexp.txt" "$NEG" <<'PY'
import sys, re, io
import numpy as np
from PIL import Image, ImageFile
ImageFile.LOAD_TRUNCATED_IMAGES = True

(gif_a, gif_b, gif_c, gif_d, gif_e, gif_f, gif_g, gif_h, gif_i, gif_j,
 gif_k, gif_l, gif_m, gif_n, gif_o, gif_p, fontinc, adpexp) = (
                    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4],
                    sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8],
                    sys.argv[9], sys.argv[10], sys.argv[11], sys.argv[12],
                    sys.argv[13], sys.argv[14], sys.argv[15], sys.argv[16],
                    sys.argv[17], sys.argv[18])
negative = sys.argv[19] == "1"

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
rows_g = [] if negative else last_screen(gif_g)
rows_h = [] if negative else last_screen(gif_h)
rows_i = [] if negative else last_screen(gif_i)
rows_j = [] if negative else last_screen(gif_j)
rows_k = [] if negative else last_screen(gif_k)
rows_l = [] if negative else last_screen(gif_l)
rows_m = [] if negative else last_screen(gif_m)
rows_n = [] if negative else last_screen(gif_n)
rows_o = [] if negative else last_screen(gif_o)
rows_p = [] if negative else last_screen(gif_p)
rows = (rows_a + rows_b + rows_c + rows_d + rows_e + rows_f + rows_g +
        rows_h + rows_i + rows_j + rows_k + rows_l + rows_m + rows_n +
        rows_o + rows_p)

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
# SEEK moved the channel to byte 3 of the file, whose first line is
# " 1234" -- so LOC says 3, and the line read from there is what is left
# of it. Both numbers come from the kernel's own position minus what the
# buffer still holds, which is the only part of this that can be wrong.
if not any(r.strip() == "3" for r in rows_d):
    fail("LOC did not report the position SEEK moved the channel to")
if not any(r.strip() == "34" for r in rows_d):
    fail("LINPUT did not read the rest of the line from where SEEK left it")
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

# ---- session G: reading VRAM back, and VRAM to and from the card --------
# 3840 is $0F00, pure red. It has to appear TWICE: once read straight back
# after PAL wrote it, and once AFTER the entry was overwritten with black
# and restored from a file -- so the second one can only have come off the
# card. The 0 between them is what proves the overwrite happened.
if len([r for r in rows_g if r.strip() == "3840"]) != 2:
    fail("PALGET did not read $0F00 back, or PALSAVE/PALLOAD did not "
         "round-trip a palette entry through the card")
if not any(r.strip() == "15" for r in rows_g):
    fail("SETCOLOR did not write a text palette entry PALGET can read")
if not any("Out of range" in r for r in rows_g):
    fail("SETCOLOR 200 was accepted -- its whole point is that 0-15 are "
         "the text palette and 200 is a mistake")

# The tilemap, on layer 1 so the console is not disturbed. VPOKE writes
# the cell and TILEGET reads it, which share no code: TILEGET derives the
# row stride from the layer's own config register, VPOKE is told the
# address outright. 66 twice and 88 once between them is the round trip.
if len([r for r in rows_g if r.strip() == "66"]) != 2:
    fail("TILEGET did not read a cell VPOKE wrote, or TMAPSAVE/TMAPLOAD "
         "did not round-trip the map through the card")
if not any(r.strip() == "88" for r in rows_g):
    fail("the cell was not overwritten before the reload, so the reload "
         "proves nothing")
if not any(r.strip() == "5" for r in rows_g):
    fail("TILEATTR did not write the attribute byte of the cell")
# And the tile graphics, whose length nothing can infer -- which is why
# TILESAVE is the one statement here that asks for one.
if not any(r.strip() == "77" for r in rows_g):
    fail("TILESAVE/TILELOAD did not round-trip tile graphics through the "
         "card")

# ---- session H: controllers and the mouse, with neither plugged in ------
# JOYHIT has to say NO for every pad. This is the check the eight extra
# clocks exist for, and the one that fails if presence is read the
# obvious wrong way -- an empty socket and an idle pad both shift out
# "no buttons", and only the clocks after the sixteenth tell them apart.
if len([r for r in rows_h if r.strip() == "0"]) < 6:
    fail("with no pad and no mouse attached, JOY, JOYHIT, JOYX, JOYY, "
         "JOYFIRE, MB and MWHEEL should all be 0")
# 3 twice: once because I2CPOKE wrote it to the system controller, once
# because MOUSEON 1 made the same request for itself. Both are read back
# out of the SMC, so neither number was computed in BASIC.
if len([r for r in rows_h if r.strip() == "3"]) != 2:
    fail("I2CPOKE and MOUSEON did not both set the SMC's mouse device ID "
         "to 3 -- the I2C WRITE path is what this proves")
# MX and MY read back what MOUSEAT set, which is the whole of what a
# position means here: the controller reports movement and never a
# position, so the pointer is SuperBasic's own.
if not any(r.strip() == "321" for r in rows_h):
    fail("MX did not report the column MOUSEAT set")
if not any(r.strip() == "50" for r in rows_h):
    fail("MY did not report the row MOUSEAT set")
# MX-1 rather than another MX: MX takes no parentheses, and a minus after
# a token is a NEGATION unless the tokenizer asks what kind of token it
# was. This is the same trap TIMER-A fell into, on a new keyword.
if not any(r.strip() == "320" for r in rows_h):
    fail("MX-1 did not answer 320 -- the minus after a no-argument "
         "function was tokenized as a negation")
if not any(r.strip() == "JMOK" for r in rows_h):
    fail("session H did not reach the end")

# ---- session I: the three audio pages -----------------------------------
# 199 is $C7, 4 and 32 are patch 5's operator bytes. All three come back
# through YMPEEK, which is a shadow of what was WRITTEN -- so they say
# FM_APPLY put the patch table into the registers the chip indexes by
# operator*8 + channel, which is the only hard part of an instrument.
if not any(r.strip() == "199" for r in rows_i):
    fail("FMINST did not write the patch connection byte to $20")
if not any(r.strip() == "4" for r in rows_i):
    fail("FMINST did not write patch 5 operator 0 to $40 -- FMINIT left "
         "1 there, so a 4 is the instrument having changed it")
if not any(r.strip() == "32" for r in rows_i):
    fail("FMINST did not write the total level to $60")
if not any(r.strip() == "10" for r in rows_i):
    fail("PCMCTRL did not write the control byte")
# The FIFO is empty before PCMPLAY, and PCMEMPTY+1 is 1 after it: the
# statement primed it before enabling the interrupt, which it has to --
# AFLOW fires on a FIFO that has DRAINED, and an empty one never drains.
if not any(r.strip() == "-1" for r in rows_i):
    fail("PCMEMPTY did not report an empty FIFO before anything played")
if not any(r.strip() == "1" for r in rows_i):
    fail("the FIFO was still empty after PCMPLAY -- it did not prime it, "
         "so AFLOW would never have fired")
# 8 is VERA's AFLOW enable, set by PCMPLAY and cleared by PCMRESET. It is
# the feeder starting and stopping, seen from outside.
if not any(r.strip() == "8" for r in rows_i):
    fail("PCMPLAY did not arm AFLOW -- the interrupt feeder never started")
# 68 is $44: octave 4, and $04 is E in the key-code table that skips 3,
# 7, 11 and 15. It is the last note of "CDE", so it says the whole
# string was parsed and played rather than merely accepted.
if not any(r.strip() == "68" for r in rows_i):
    fail("PLAY did not leave E of octave 4 in the key-code register")
if not any(r.strip() == "AUDOK" for r in rows_i):
    fail("session I did not reach the end")

# ---- session J: the SuperBasic language layer ---------------------------
# Not one of the four BAD markers may appear, and each fails from its own
# direction: a taken branch that ran its ELSE too, a false branch that ran
# anyway, an inner ENDIF mistaken for the outer one, and the classic
# THEN <line> form breaking.
for bad in ("BAD1", "BAD2", "BAD3", "BAD4"):
    if any(r.strip() == bad for r in rows_j):
        fail("block IF took a branch it should not have: %s printed" % bad)
for good in ("TRUE1", "TRUE2", "NEST"):
    if not any(r.strip() == good for r in rows_j):
        fail("block IF did not take a branch it should have: %s missing" % good)
# 12 is COUNTER+COUNTX with both names kept whole. If only the first two
# characters were significant they would be one variable and this would
# be 14 -- so the number says the names are distinct, not merely that
# assignment works.
if not any(r.strip() in ("12", "1.20000E01") for r in rows_j):
    fail("COUNTER and COUNTX did not stay separate variables")

# PROC, and the two things about it that can actually be wrong.
#
# 7.00000 EXACTLY ONCE. Once because the parameter bound, and only once
# because execution runs off line 250 into the DEFPROC on 300 and has to
# step over the body to its ENDPROC -- a definition that ran where it
# sits would print it a second time.
if len([r for r in rows_j if r.strip() == "7.00000"]) != 1:
    fail("PROC did not bind its parameter, or falling into the DEFPROC "
         "ran the body where it sits instead of stepping over it")
# And 42 back afterwards: the procedure's parameter is called X and so is
# the caller's variable, so this is the whole of what LOCAL means.
if not any(r.strip() == "4.20000E01" for r in rows_j):
    fail("the caller's X was not restored -- a parameter is supposed to "
         "be local to the procedure that declares it")

# ---- session K: labels, and AUTO ----------------------------------------
for bad in ("BADG", "BADT"):
    if any(r.strip() == bad for r in rows_k):
        fail("a jump to a label did not skip what it was supposed to: "
             "%s printed" % bad)
for good in ("INHELPER", "ATFINISH"):
    if not any(r.strip() == good for r in rows_k):
        fail("a label was not reached: %s missing" % good)
# AUTO is checked by what it puts on the screen BEFORE anything is typed.
# 400 heads the line that becomes the program; 405 heads the line the
# user leaves empty to stop.
if not any(r.strip().startswith("400") for r in rows_k):
    fail("AUTO did not offer the first line number")
if not any(r.strip() == "405" for r in rows_k):
    fail("AUTO did not offer the second line number, or did not stop when "
         "the line after it was left empty")
# And LIST shows one line, not two: the empty numbered line must not have
# become a line of its own.
if not any(r.strip() == "400 PRINT \"AUTOONE\"" for r in rows_k):
    fail("AUTO did not put its number into the line that was typed")
if any(r.strip().startswith("405 ") for r in rows_k):
    fail("the line left empty under AUTO became a program line")

# A source file with no line numbers. The LIST afterwards is the whole
# check: 10 and 20 were given to lines that had none, 100 is the one that
# brought its own, and 110 shows the numbering carried on FROM IT rather
# than from where it had got to.
for want in ('10 PRINT "NONUM"', "20 LABEL again",
             '100 PRINT "HUNDRED"', '110 PRINT "AFTER"'):
    if not any(r.strip() == want for r in rows_k):
        fail("LOAD did not number a numberless source file as expected: "
             "%r missing" % want)

# Sprites. SPRITEGET reads the attribute record back through the port;
# 300 and 200 are ten-bit values, so they also check that the high two
# bits are being masked rather than dropped.
if not any(r.strip() == "300" for r in rows_g):
    fail("SPRITEGET(n,0) did not read the sprite X position back")
if not any(r.strip() == "200" for r in rows_g):
    fail("SPRITEGET(n,1) did not read the sprite Y position back")
# 90 comes back only if SPRITESAVE worked out the image address and its
# size from the sprite's own attributes, wrote that file, and SPRITELOAD
# put it back where it came from.
if not any(r.strip() == "90" for r in rows_g):
    fail("SPRITESAVE/SPRITELOAD did not round-trip sprite pixels through "
         "the card")

# ---- session L: PSG volume envelopes ------------------------------------
# Every number here is VPEEK of the PSG's own volume byte, so it is the
# hardware's answer and not BASIC's. The top two bits are the channel
# bits, so a reading is 192 + the level: 255 is full, 192 is silence,
# and the envelope's whole job is what happens between them.
#
# 255 TWICE, and they mean different things. The first is ENV 0,0,0,63,0
# -- an envelope of all instants, which must behave exactly like plain
# SOUND and reach the peak inside the statement. The second is voice 1
# arriving at the top of a 120-frame attack after WAIT 3000.
if len([r for r in rows_l if r.strip() == "255"]) != 2:
    fail("a voice under an envelope did not reach its peak: either the "
         "instant envelope ENV 0,0,0,63,0 failed to behave like plain "
         "SOUND, or the 120-frame attack never finished")
# 192 twice as well: the instant release on voice 0, and voice 4's
# 60-frame release having run out. Both are silence with the channel
# bits intact -- a 0 here would be an envelope that wrote the level
# without them and killed the voice.
if len([r for r in rows_l if r.strip() == "192"]) != 2:
    fail("ENVOFF did not bring a voice to silence, or it wrote the level "
         "without the two channel bits above it")
# Voice 1 read the statement AFTER SOUND: still at zero, because a
# 120-frame attack has moved half a level. This is what says the attack
# ramps rather than jumping, and it fails if SOUND still writes the
# volume it was given.
if not any(r.strip() in ("192", "1.92000E02") for r in rows_l):
    fail("SOUND on a voice with an envelope started at full volume -- the "
         "volume it was given should have become the PEAK, and the note "
         "should have started from silence")
# THE ONE THAT MATTERS. 60 frames into a 120-frame attack is level 31 of
# 63, so 223. A level that merely moved would pass every other check
# here; a step computed at twice the rate reads 255 and at half reads
# 207, and only this line can tell.
if not any(r.strip() in ("223", "2.23000E02") for r in rows_l):
    fail("half way through a 120-frame attack the level was not half: "
         "the envelope is moving, but not at the rate it was asked for")
# And the same again on the way down: 30 frames into a 60-frame release
# is level 30.
if not any(r.strip() == "222" for r in rows_l):
    fail("half way through a 60-frame release the level was not half -- "
         "ENVOFF is not walking the level down at its release rate")
# 212 is 192+20: the decay stopped at the sustain level and held there.
if not any(r.strip() == "212" for r in rows_l):
    fail("the decay did not stop at the sustain level -- it either ran "
         "past it to silence or never left the peak")
# 232 is 192+40, a plain SOUND volume. It comes after ENV 3,0,0,0,0 on a
# voice that HAD been armed, so it is the disarm form working: without
# it the voice would be attacking from silence and read 192.
if not any(r.strip() == "232" for r in rows_l):
    fail("ENV v,0,0,0,0 did not disarm the voice -- SOUND should be the "
         "statement it always was afterwards")
if not any(r.strip() == "ENVOK" for r in rows_l):
    fail("session L did not reach the end")

# ---- sessions M and N: IMA ADPCM ----------------------------------------
# The expected values were computed by the Python decoder above -- the
# published step and index tables, in another language, from the same
# nibbles. Nothing here compares SuperBasic against itself.
#
# IN ORDER, not merely present. Every value is a byte 0-255 and several
# repeat, so "does 255 appear anywhere" would pass on almost any wrong
# answer; the sequence is what carries the information.
adp_want = [l.strip() for l in io.open(adpexp, encoding='utf-8')
            if l.strip()]
adp_m = adp_want[:adp_want.index("-")]
adp_n = adp_want[adp_want.index("-") + 1:]

def digits(rows_x):
    return [r.strip() for r in rows_x if r.strip().isdigit()]

got_m = digits(rows_m)
if got_m[:len(adp_m)] != adp_m:
    fail("ADPCMPLAY did not decode the WAV as an independent decoder "
         "says it must: wanted %r, got %r. Bytes 3 and 4 are sample 100 "
         "and bytes 5 and 6 sample 504, which are the two PREDICTOR "
         "CLAMPS; bytes 7 and 8 are sample 505, the second block's own "
         "starting predictor, which is wrong if the decoder ran on "
         "through the block header instead of restarting at it. The "
         "last three are VERA's rate register out of the WAV header, "
         "the 16-bit mode bit, and AFLOW armed."
         % (adp_m, got_m[:len(adp_m)]))
if not any(r.strip() == "ADPOK" for r in rows_m):
    fail("session M did not reach the end")

got_n = digits(rows_n)
if got_n[:len(adp_n)] != adp_n:
    fail("a RAW headerless IMA stream did not decode from a predictor "
         "of 0, or ADPCMPLAY moved PCMRATE for a file that says nothing "
         "about its rate: wanted %r, got %r" % (adp_n, got_n[:len(adp_n)]))
# The stereo WAV. It is well formed in every other way, so nothing but
# the channel count can refuse it -- and a decoder that shrugged would
# turn a stereo file into noise and leave the speaker to report it.
if not any("Illegal argument" in r for r in rows_n):
    fail("a STEREO IMA WAV was accepted -- it cannot be decoded by this "
         "and has to be refused rather than played as noise")
if any(r.strip() == "NOTREACHED" for r in rows_n):
    fail("the line after the refused ADPCMPLAY ran: it threw nothing")

# ---- session O: the console's two colour statements ---------------------
# Out of the text matrix attribute byte, which is the console's own
# memory: 7 is foreground 7 on background 0, the pair TEXTCOLOR set.
if not any(r.strip() == "7" for r in rows_o):
    fail("TEXTCOLOR 7,0 did not put foreground 7 on background 0 into "
         "the attribute of the cell it then printed")
# 71 IS THE ONE THAT MATTERS. $47: background 4, and the foreground
# STILL 7 from the TEXTCOLOR three lines earlier. Setting half of a pair
# through a kernel call that only takes both is the whole of this
# statement, and a SETBGCOLOR working from an unseeded shadow -- or one
# that took the background for the foreground -- lands on almost any
# other number.
if not any(r.strip() == "71" for r in rows_o):
    fail("SETBGCOLOR did not change the background while keeping the "
         "foreground: the attribute should be $47, background 4 under "
         "the 7 that TEXTCOLOR set")
# 5 and 9 out of $9F2C itself, and it is the SAME register both times:
# SETBORDER and BORDER are one statement under two names, so a 9 that
# did not follow the 5 would mean one of them writes somewhere else.
if not any(r.strip() in ("5", "5.00000") for r in rows_o):
    fail("SETBORDER did not reach VERA's border register")
if not any(r.strip() in ("9", "9.00000") for r in rows_o):
    fail("BORDER did not write the same register SETBORDER does -- they "
         "are meant to be one statement under two names")
if not any(r.strip() == "CONOK" for r in rows_o):
    fail("session O did not reach the end")

# ---- session P: the third token table, and NEXT with its name ----------
# 1 is the kernel's version through a keyword that lives in TOKENS3 --
# three bytes in the line, $FF $FF <sub>, an escape inside an escape.
if not any(r.strip() == "1" for r in rows_p):
    fail("VER did not answer through the third token table: $FF $FF "
         "<sub> was not decoded, or the record was fetched from the "
         "wrong table")
# 0 is VER-1, and it is the check that the third table is UNDERSTOOD
# rather than merely reached. A minus after a no-argument function is a
# NEGATION unless the tokenizer asks what kind of token came before it,
# and asking means knowing which TABLE the sub-id belongs to -- the same
# number means a different keyword in each of the three.
if not any(r.strip() in ("0", "0.00000") for r in rows_p):
    fail("VER-1 did not answer 0: the minus after a no-argument function "
         "in TOKENS3 was tokenized as a negation, which means PREVEXT "
         "did not count the escapes")
# 6 is three times two with the inner loop closed BY NAME, and it is the
# whole of the NEXT fix: before it, the loop ran correctly and then
# threw a syntax error on the pass that ENDS it, so the total never
# printed at all.
if not any(r.strip() in ("6", "6.00000") for r in rows_p):
    fail("nested FOR loops closed with NEXT <name> did not complete -- "
         "NEXT is not consuming its variable, so the name is left in the "
         "line for the statement checker")
if not any(r.strip() == "BARE" for r in rows_p):
    fail("bare NEXT stopped working, which is a regression: it is the "
         "form every session before this one used")
# 5, 3, 1: a countdown, so the STEP sign and the end test still agree
# with each other now that NEXT parses something.
for want in ("5", "3", "1"):
    if not any(r.strip() in (want, want + ".00000") for r in rows_p):
        fail("FOR ... STEP -2 did not count down through %s" % want)
if not any(r.strip() == "TOKOK" for r in rows_p):
    fail("session P did not reach the end")
# And LIST detokenizes a three-byte token back to its keyword.
if not any(r.strip() == "10 PRINT VER" for r in rows_p):
    fail("LIST did not turn a TOKENS3 token back into its keyword")

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

# X816 SuperBasic

A structured BASIC for the **X816** — a 65816-based FPGA retro computer (MiSTer /
Cyclone V). SuperBasic is a port of Peter Weingartner's
[BASIC816](https://github.com/pweingar/BASIC816), the 65816-native BASIC
interpreter of the C256 Foenix, retargeted to the X816 kernel and console, with
a structured-programming feature layer (named procedures, multi-line IF,
proper loops) added on top.

Status: **planning**. No code yet — see [PORT.md](PORT.md) for the full port
sketch (memory map, kernel I/O bindings, math-layer rewrite, phased plan).

## Platform

- CPU: 65C816 soft core, native mode, flat 16 MB address space (no banking)
- Console: 80×60 text, CP437/ASCII, via the X816 kernel jump table at `$00:FE00`
- Storage: FAT32 SD through kernel `K_FS_*` calls
- Interpreter loads at `$01:0000` as an ordinary program (8-byte `"X816"` header)

## License

This project as a whole is licensed under the **GNU General Public License,
version 3** (see [LICENSE](LICENSE)).

- The interpreter core is derived from
  [pweingar/BASIC816](https://github.com/pweingar/BASIC816), © Peter
  Weingartner, licensed under GPLv3.
- New modules written for this port that contain no BASIC816-derived code
  (platform bindings, software math, etc.) are © Jean-Yves Vinet and, where
  their file header says so, are **dual-licensed GPLv3 / MIT** — so they can
  also be reused under MIT terms in the other X816 projects. Within this
  repository and in the combined binary they are distributed under GPLv3.

Complete corresponding source for every released binary is this repository.

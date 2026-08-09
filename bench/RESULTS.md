# SuperBasic vs durexForth — the period's benchmarks, one machine

Measured 2026-08-09 on the X816 emulator at 8 MHz, SuperBasic at commit
`0875270` plus the `TOK_FUNC_OPEN` fix, durexForth at its 2026-08-06
state. Same emulator, same kernel, same millisecond counter
(cycle-driven, so `-warp` cannot distort it). The cycle model was
checked against the FPGA the same day: the MiSTer measured BM1 about 8%
slower than the emulator, so treat every number here as ~8% optimistic
in absolute terms; ratios are unaffected. TURBO (14 MHz) scales times
by exactly 8/14 — measured to within 0.3%.

Harnesses: `run-bench.sh` here and in `../X816_DurexForth`. Programs:
`bench/*.BAS` here, `bench/*.fs` there.

## The grid

Milliseconds at 8 MHz; smaller is faster. "SB int" is the loop written
on `K%`; only BM1 has that twin today.

| bench | SuperBasic | SB int (K%) | durexForth | Forth is | what it measures |
|-------|-----------:|------------:|-----------:|---------:|------------------|
| BM1   |        675 |         303 |         24 |   12.6×* | empty counted loop, 1000 passes |
| BM2   |       2002 |           — |         67 |    30×   | named counter + conditional branch |
| BM3   |       4968 |           — |        670 |   7.4×   | + `K/K*K+K-K` (5 reads, 4 ops) |
| BM4   |       5141 |           — |        669 |   7.7×   | + constants instead of K (the classic) |
| BM5   |       5785 |           — |        671 |   8.6×   | + an empty subroutine call each pass |
| BM6   |      10337 |           — |        793 |    13×   | + an empty inner loop of 5 |
| BM7   |      14990 |           — |       1960 |   7.6×   | + an array store inside that loop |
| BM8   |      11791 |           — |    525759† | **BASIC 45×** | `K^2`, `LN(K)`, `SIN(K)` × 1000 |
| AHL   |       9230 |           — |    382919† | **BASIC 41×** | Ahl: 1000 SQR, 1000 ^, 2000 RND |

\* the honest BM1 ratio is against SB int (both integer loops): 12.6×.
Against BASIC's float loop as the 1977 program wrote it: 28×.

† computed **wrong values while being timed** — see the float note.

## Ahl's accuracy (0 is perfect)

| | SuperBasic (IEEE-754 single, truncating) | durexForth (MFLPT, ~9 digits) |
|---|---:|---:|
| arithmetic error | **0.176** | **3.4e+37** |
| RND sum error    | 13.0 | 20.4 |

## How to read it

**Compiled Forth against interpreted BASIC is the point, not a
distortion** — that is the gap the two languages actually offer a
program. On integer work it is 7–30×, largest where the interpreter's
per-statement overhead dominates (BM2) and smallest where both sides
spend their time in the same place (BM3–BM5, BM7 — division and memory
traffic).

**BM1–BM7 are integer in Forth and float in BASIC**, because each
language's counter is what it is. The one like-for-like row (BM1 vs SB
int) says the honest loop gap is 12.6×.

**The float rows invert the story, 40× the other way.** durexForth's
FLOAT module codes MFLPT arithmetic in high-level Forth; SuperBasic's
IEEE library is hand assembly. And the durexForth times were measured
computing **wrong answers**: `F**` explodes for bases near 1.0 — ten
`FSQRT`s of 2 give 1.00067713 (correct to every printed digit), and
ten `F**`-squarings of that give 1.55e+38 instead of 2. Single calls at
ordinary arguments are fine (`FSQRT(2)`=1.41421356, `F**(2,2)`=4); the
defect is in `fln`/`fexp` range reduction near 1, amplified 1024× by
Ahl's round trip. Ahl's accuracy row is the bug's signature, and the
benchmark did exactly what Ahl designed it to do. Filed as a
durexForth `float.fs` issue; the times stand as measured.

**RND differs by construction**: SuperBasic's 16-bit xorshift against
rnd.fs's 1977 LCG scaled from its middle bits. Both mean-errors are
ordinary for 2000 draws.

## The period anchor

A stock C64 (1 MHz, Microsoft BASIC V2) runs BM1 in about 1.2 s. This
machine at 8 MHz: SuperBasic 0.68 s (float) / 0.30 s (integer), and
durexForth 0.024 s. At TURBO's 14 MHz, scale by 8/14. Published tables
for other period machines are deliberately not reproduced here — take
the comparison column from a source you trust.

## Hardware measurements so far (MiSTer, DE10-Nano)

| | 8 MHz | 14 MHz (TURBO) |
|---|---:|---:|
| BM1, SuperBasic at commit `60f6ecd` | 946 ms | 539 ms |

(That binary predates the FOR/NEXT pointer; its emulator BM1 was
871 ms, hence the ~8% rule. The current binary predicts ~730 ms /
~420 ms; a re-run on the card in `build/bench-card/` will say.)

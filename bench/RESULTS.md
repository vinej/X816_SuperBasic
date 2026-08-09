# SuperBasic vs durexForth — the period's benchmarks, one machine

Measured 2026-08-09 on the X816 emulator at 8 MHz. Same emulator, same
kernel, same millisecond counter (cycle-driven, so `-warp` cannot
distort it). The cycle model was checked against the FPGA the same day:
the MiSTer measured BM1 about 8% slower than the emulator, so treat
absolute numbers as ~8% optimistic; ratios are unaffected. TURBO
(14 MHz) scales times by exactly 8/14 — measured to within 0.3%.

**Both languages compute floats with the same implementation.** As of
this evening durexForth's FLOAT module is SuperBasic's engine —
`floats_x816.s` and `transcendentals_x816.s` assembled unchanged into
`fpengine.bin` (X816_DurexForth/fpengine/) and called through a jump
table at $00:5000. IEEE-754 singles, one Forth cell each. The old
Forth-coded MFLPT numbers are kept below because they are the honest
record of what the port replaced.

Harnesses: `run-bench.sh` here and in `../X816_DurexForth`. Programs:
`bench/*.BAS` here, `bench/*.fs` there.

## The grid

Milliseconds at 8 MHz; smaller is faster. "SB int" is the loop written
on `K%`; only BM1 has that twin today.

| bench | SuperBasic | SB int (K%) | durexForth | Forth is | what it measures |
|-------|-----------:|------------:|-----------:|---------:|------------------|
| BM1   |        675 |         303 |         25 |   12×*   | empty counted loop, 1000 passes |
| BM2   |       2002 |           — |         67 |    30×   | named counter + conditional branch |
| BM3   |       4968 |           — |        669 |   7.4×   | + `K/K*K+K-K` (5 reads, 4 ops) |
| BM4   |       5141 |           — |        670 |   7.7×   | + constants instead of K (the classic) |
| BM5   |       5785 |           — |        671 |   8.6×   | + an empty subroutine call each pass |
| BM6   |      10337 |           — |        793 |    13×   | + an empty inner loop of 5 |
| BM7   |      14990 |           — |       1961 |   7.6×   | + an array store inside that loop |
| BM8   |      11791 |           — |      17418 | BASIC 1.5×† | `K^2`, `LN(K)`, `SIN(K)` × 1000 |
| AHL   |       9230 |           — |      15619 | BASIC 1.7×† | Ahl: 1000 SQR, 1000 ^, 2000 RND |

\* the honest BM1 ratio is against SB int (both integer loops).
Against BASIC's float loop as the 1977 program wrote it: 27×.

† same float engine on both sides now. BASIC still wins these two
because its `^` takes the integer-exponent fast path (`K^2` is one
multiply) where Forth's `F**` runs the full `exp(2·ln x)`, and each
Forth float word pays a few dozen cells of marshalling around the
engine call. With MFLPT these rows read 525,759 and 382,919 ms —
the engine is 30× and 24× faster than the Forth-coded library it
replaced, and correct where it was not (below).

## Ahl's accuracy (0 is perfect)

| | SuperBasic | durexForth (fpengine) | durexForth (old MFLPT) |
|---|---:|---:|---:|
| arithmetic error | **0.176** | **0.180** | 3.4e+37 |
| RND sum error    | 13.0 | 20.4 | 20.4 |

0.176 vs 0.180 is the same engine giving the same truncation error
through two different languages — the point of sharing it. The old
MFLPT's 3.4e+37 was a real defect: its `F**` exploded for bases near
1.0 (`fln`/`fexp` range reduction), which ten squarings amplify without
mercy. X816_Library's `f_ln`/`f_exp` share those algorithms verbatim
and are UNTESTED against the same probe — treat its `f_pow` as suspect
until someone runs `1.000677^1024` through it. The RND columns differ
because each language keeps its own generator; both are ordinary for
2000 draws.

## What the day's benchmarks found besides numbers

Six ancestral bugs, all found by these programs and fixed the same day
(PORT.md §36–§39): the break check's I2C poll at every statement (30%
of BM1); right-to-left evaluation of equal-precedence operators
(`10-5+2` was 3); `FOR K=J TO 4` assigning J; `NEXT` searching the
variable list twice per pass; `FTOI` throwing overflow for every value
≥ 2^24 (its shift-left branch was commented out — found because
Forth's `F.` converts through it); and the still-open float PRINT bug:
BASIC prints values ≥ 1e5 ten times too large with a digit dropped.
The durexForth side found its own: MFLPT `F**` above, replaced rather
than patched.

## The period anchor

A stock C64 (1 MHz, Microsoft BASIC V2) runs BM1 in about 1.2 s. This
machine at 8 MHz: SuperBasic 0.68 s (float) / 0.30 s (integer), and
durexForth 0.025 s. At TURBO's 14 MHz, scale by 8/14. Published tables
for other period machines are deliberately not reproduced here — take
the comparison column from a source you trust.

## Hardware measurements so far (MiSTer, DE10-Nano)

| | 8 MHz | 14 MHz (TURBO) |
|---|---:|---:|
| BM1, SuperBasic at commit `60f6ecd` | 946 ms | 539 ms |

(That binary predates the FOR/NEXT pointer; its emulator BM1 was
871 ms, hence the ~8% rule. The current binary predicts ~730 ms /
~420 ms; a re-run on the card in `build/bench-card/` will say.)

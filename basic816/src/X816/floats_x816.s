;;;
;;; Floating point stubs for the X816 (phase 1)
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The C256 build implements these against the memory-mapped FP
;;; coprocessor (src/C256/floats.s). The X816 has no such hardware;
;;; phase 2 replaces these with software IEEE-754-single routines.
;;; Until then every float entry point throws a type-mismatch error so
;;; no silently-wrong arithmetic can escape. Note: division (/) always
;;; promotes to floating point in BASIC816, so integer division also
;;; errors until phase 2 — use \ or MOD-free constructs meanwhile.
;;;

OP_FP_ADD   .proc
            THROW ERR_TYPE
            .pend

OP_FP_SUB   .proc
            THROW ERR_TYPE
            .pend

OP_FP_MUL   .proc
            THROW ERR_TYPE
            .pend

OP_FP_DIV   .proc
            THROW ERR_TYPE
            .pend

FP_DIV10    .proc
            THROW ERR_TYPE
            .pend

FP_MUL10    .proc
            THROW ERR_TYPE
            .pend

FP_TO_FIXINT .proc
            THROW ERR_TYPE
            .pend

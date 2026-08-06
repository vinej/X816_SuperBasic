;;;
;;; Transcendental function stubs for the X816 (phase 2)
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The C256 transcendentals.s drives the FP coprocessor inline (90
;;; register accesses); on the X816 those registers are plain SDRAM, so
;;; running it would produce silent garbage. Until the software port of
;;; the polynomial evaluators lands, every function throws rather than
;;; lie. (Q_FP_POW_INT, used by ^, already has a software version in
;;; floats_x816.s.)
;;;

FP_SIN      .proc
            THROW ERR_TYPE
            .pend

FP_COS      .proc
            THROW ERR_TYPE
            .pend

FP_TAN      .proc
            THROW ERR_TYPE
            .pend

FP_LN       .proc
            THROW ERR_TYPE
            .pend

FP_EXP      .proc
            THROW ERR_TYPE
            .pend

FP_ASIN     .proc
            THROW ERR_TYPE
            .pend

FP_ACOS     .proc
            THROW ERR_TYPE
            .pend

FP_ATAN     .proc
            THROW ERR_TYPE
            .pend

FP_SQR      .proc
            THROW ERR_TYPE
            .pend

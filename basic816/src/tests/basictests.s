;;;
;;; Top Level Unit Test for BASIC816
;;;

TST_SUITE_ALL       = 0
TST_SUITE_EVAL      = 1
TST_SUITE_FLOATS    = 2
TST_SUITE_TOKENS    = 3
TST_SUITE_OPS       = 4
TST_SUITE_STMNTS    = 5
TST_SUITE_FUNCS     = 6
TST_SUITE_OPS_FLOAT = 7
TST_SUITE_OPS_STR   = 8

; Get the unit test framework
.include "unittests.s"
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_EVAL
.include "evaltests.s"
.endif
; .include "heaptests.s"
; .include "stringtests.s"
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_FLOATS
.include "floattests.s"
.endif
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_TOKENS
.include "tokentests.s"
.endif
; .include "interptests.s"
;.include "cmdtests.s"
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_STMNTS
.include "statementtests.s"
.endif
;.include "variabletests.s"
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_FUNCS
.include "functests.s"
.endif
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_OPS || TEST_SUITE == TST_SUITE_OPS_FLOAT || TEST_SUITE == TST_SUITE_OPS_STR
.include "optests.s"
.endif
;.include "arraytests.s"

.section globals
TST_TEMP1       .dword ?
TST_TEMP2       .dword ?
TST_TEMP3       .dword ?
.send

TMP_BUFF_ORG = $014000
TMP_BUFF_SIZ = $100

TST_BASIC       .proc
                CALL UT_MSGCOLOR
                TRACE "TST_BASIC"
                ; CALL TST_HEAP
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_EVAL
                CALL TST_EVAL
.endif
                ; CALL TST_STRINGS
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_FLOATS
                CALL TST_FLOATS
.endif
                ; CALL TST_VARIABLES
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_TOKENS
                CALL TST_TOKENS
.endif
                ; CALL TST_INTERP
                ; CALL TST_CMD
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_OPS || TEST_SUITE == TST_SUITE_OPS_FLOAT || TEST_SUITE == TST_SUITE_OPS_STR
                CALL TST_OPS
.endif
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_STMNTS
                CALL TST_STMNTS
.endif
.if TEST_SUITE == TST_SUITE_ALL || TEST_SUITE == TST_SUITE_FUNCS
                CALL TST_FUNCS
.endif
                ; CALL TST_ARRAY

                UT_PASSED "TST_BASIC"
                RETURN
                .pend

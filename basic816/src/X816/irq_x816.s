;;;
;;; Interrupts: the machine-code hook and the deferred BASIC handlers
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; TWO LEVELS, AND THE REASON THERE ARE TWO
;;;
;;; `IRQ slot,addr` installs machine code in one of the kernel's eleven
;;; slots (K_IRQ_SET). It has no problem to solve: the kernel dispatches
;;; by source, hands the handler a normative environment -- native mode,
;;; M=0/X=0, D=$0000, DBR=$00, reached by JSL and finished with RTL --
;;; and the whole of SuperBasic is uninvolved. That is the level PCM
;;; refill and a raster split actually want.
;;;
;;; ONVSYNC / ONRASTER / ONCOLLISION run a BASIC line, and there the
;;; problem is real: an interrupt lands in the middle of whatever
;;; statement was executing, with the evaluation stacks half-built and
;;; ARGUMENT1 half-written. The interpreter is not re-entrant and making
;;; it so would mean saving and restoring every scratch global at an
;;; ASYNCHRONOUS boundary -- which is the exact shape of the width bug
;;; that has cost this port four separate days (PORT.md 14, 15, 19).
;;;
;;; So dispatch is DEFERRED: the handler is entered from IRQ_POLL below,
;;; which runs at the statement boundary in EXECSTMT, right after the
;;; break check and in the same place and for the same reason. Nothing
;;; re-enters anything, no state is saved beyond what GOSUB already
;;; saves, and no code of ours runs in interrupt context at all.
;;;
;;; WHICH IS WHY NOTHING HERE INSTALLS A HANDLER FOR THE THREE.
;;;
;;; That was the first design and it was worse. Detection can be a poll
;;; too, because the hardware and the kernel are already latching
;;; everything needed:
;;;
;;;   VSYNC      the kernel counts frames whether or not anybody has a
;;;              handler (K_IRQ_FRAMES), so a changed count IS the tick
;;;   LINE       VERA sets ISR bit 1 at the compare scanline whether or
;;;              not the source is enabled in IEN; the kernel's
;;;              dispatcher only acknowledges `ISR & IEN`, so with the
;;;              source disabled the bit SURVIVES until we clear it
;;;   SPRCOL     the same, on ISR bit 2
;;;
;;; Polling those beats installing a stub in three ways: the kernel's
;;; blinking cursor keeps KIRQ_VSYNC (installing there would take the
;;; slot off it, and worse, the next K_CON_CURSOR call would take it
;;; straight back and silently unhook us); no chaining is needed; and
;;; there is no interrupt-context code to get the widths wrong in.
;;;
;;; WHAT DEFERRED HONESTLY COSTS. The handler runs at the next statement
;;; boundary, so its latency is one statement -- and a statement can be
;;; arbitrarily long. WAIT 5000, INPUT and a long PRINT all hold it off,
;;; and a program slower than 60 statements a second drops ticks rather
;;; than queueing them. "Every frame" here means "at most once a frame,
;;; as soon as the interpreter next comes up for air". For a raster
;;; split -- where the point is to change a register WHILE the beam is
;;; at that line -- that is not good enough and never will be; use
;;; `IRQ 1,addr` and assembly. ONRASTER is for pacing to a point in the
;;; frame, not for splitting the screen.
;;;

;
; IRQ_POLL -- the deferred dispatch, called from EXECSTMT before every
; statement of a running program.
;
; Outputs:
;   EXECACTION = EXEC_GOTO if a handler was entered (CURLINE is its line)
;
; Enters and leaves at the caller's register widths: EXECSTMT is 8 bits
; wide on both sides of the call site and reads single-byte globals
; immediately after it.
;
IRQ_POLL    .proc
            PHP

            setal                       ; The fast path is one 16-bit read:
            LDA @l IRQ_STATE            ;  ARMED in the low byte, BUSY in
            BEQ out                     ;  the high one. Nothing armed and
                                        ;  nothing running is the case that
                                        ;  happens on every statement of
                                        ;  every program ever written, so it
                                        ;  pays for none of the setup below.
            JMP work

out         PLP
            RETURN

            ; ---- something is armed, or a handler is running ----

work        PHD
            PHB
            setdp <>GLOBAL_VARS
            setdbr BASIC_BANK
            setaxl

            ; Volume envelopes first, and BEFORE the two gates below.
            ;
            ; They belong on the near side of both because they re-enter
            ; nothing: ENV_POLL walks its own table and writes VERA, and
            ; touches no interpreter state at all. Behind the BUSY guard
            ; an ONVSYNC handler would freeze every envelope for as long
            ; as it ran, and behind the ST_RUNNING test a note started at
            ; the READY prompt would never move.
            setas
            LDA @l ENV_ANY
            BEQ noenv
            CALL ENV_POLL
noenv
            setal
            LDA @l IRQ_STATE
            AND #$FF00
            BNE done                    ; A handler is running: the re-entry
                                        ;  guard. A tick arriving now is
                                        ;  DROPPED, not queued -- queueing
                                        ;  guarantees a death spiral the
                                        ;  moment the handler is slower than
                                        ;  the source.

            setas
            LDA STATE                   ; Only from a running program. At the
            CMP #ST_RUNNING             ;  REPL there is no line to come back
            BNE done                    ;  to: EXECCMD leaves EXEC_GOTO to
                                        ;  abandon the rest of the typed line
                                        ;  and the handler would never run.

            ; ---- VSYNC: has the kernel's frame counter moved? ----
            setal
            LDA @l IRQ_VLINE
            BEQ chk_line
            JSL KERN_IRQ_FRAMES         ; C = frames, 16-bit, wraps
            CMP @l IRQ_FRAME
            BEQ chk_line
            STA @l IRQ_FRAME            ; One dispatch per frame however many
                                        ;  frames went by: a program that
                                        ;  fell behind does not then get a
                                        ;  burst of catch-up calls.
            LDA @l IRQ_VLINE
            JMP dispatch

            ; ---- LINE: VERA latched the compare scanline ----
chk_line    setal
            LDA @l IRQ_RLINE
            BEQ chk_coll
            setas
            LDA @l VERA_ISR
            AND #VERA_IRQ_LINE
            BEQ chk_coll
            STA @l VERA_ISR             ; Write 1 to clear, and A is exactly
                                        ;  the one bit -- so this cannot
                                        ;  acknowledge somebody else's.
            setal
            LDA @l IRQ_RLINE
            JMP dispatch

            ; ---- SPRCOL: VERA latched a sprite collision ----
chk_coll    setal
            LDA @l IRQ_CLINE
            BEQ done
            setas
            LDA @l VERA_ISR
            AND #VERA_IRQ_SPRCOL
            BEQ done
            STA @l VERA_ISR
            setal
            LDA @l IRQ_CLINE
            JMP dispatch

done        setal                       ; Reached 8 and 16 bits wide, and the
            PLB                         ;  PLP below only restores the
            PLD                         ;  CALLER's width, not the one the
            PLP                         ;  instructions between here and it
            RETURN                      ;  are assembled for.

            ;
            ; Enter the handler at the line number in A.
            ;
            ; Everything GOSUB saves, plus GOSUBDEPTH, which is then
            ; zeroed: that is what makes a stray RETURN inside a handler
            ; a clean stack underflow instead of a return through this
            ; frame into a line the program was not at.
            ;
dispatch    setaxl
            STA ARGUMENT1               ; What FINDLINE looks for
            LDA #0
            STA ARGUMENT1+2

            LDA GOSUBDEPTH
            CALL PHRETURN
            LDA CURLINE+2
            CALL PHRETURN
            LDA CURLINE
            CALL PHRETURN
            LDA BIP+2
            CALL PHRETURN
            LDA BIP                     ; BIP still points AT the statement
            CALL PHRETURN               ;  we are deferring, so RETIRQ
                                        ;  resumes by executing it.

            CALL FINDLINE               ; Sets CURLINE if it is found
            BCC no_line

            setaxl
            STZ GOSUBDEPTH
            setas
            LDA #1
            STA @l IRQ_BUSY
            LDA #EXEC_GOTO              ; EXECLINE stops here and EXECPROGRAM
            STA EXECACTION              ;  restarts at CURLINE
            JMP done

            ; The handler's line has been deleted since it was armed.
            ; Unwind the five words, disarm everything -- leaving it armed
            ; would throw this same error at every statement from now on --
            ; and report it.
no_line     setaxl
            CALL PLRETURN
            CALL PLRETURN
            CALL PLRETURN
            CALL PLRETURN
            CALL PLRETURN
            CALL IRQ_DISARM
            PLB
            PLD
            PLP
            THROW ERR_NOLINE
            .pend

;
; RETIRQ -- return from a deferred handler.
;
; A separate keyword rather than RETURN, deliberately. A handler can fire
; between any two statements, including while the program has its own
; GOSUBs pending, and RETURN reaching this frame would unwind to the
; wrong place with nothing to warn anybody. With the depth zeroed on
; entry and this as the only way out, each mistake reports itself: a
; RETURN inside a handler underflows, and a RETIRQ outside one does too.
;
S_RETIRQ    .proc
            PHP
            TRACE "S_RETIRQ"

            setaxl
            setas
            LDA @l IRQ_BUSY
            BEQ underflow

            setaxl
            CALL PLRETURN               ; The exact reverse of the pushes in
            STA BIP                     ;  IRQ_POLL's dispatch
            CALL PLRETURN
            STA BIP+2
            CALL PLRETURN
            STA CURLINE
            CALL PLRETURN
            STA CURLINE+2
            CALL PLRETURN
            STA GOSUBDEPTH

            setas
            LDA #0                      ; STZ has no long addressing mode
            STA @l IRQ_BUSY
            LDA #EXEC_RETURN            ; BIP is already set, so EXECLINE
            STA EXECACTION              ;  must not reset it to the line head

            PLP
            RETURN
underflow   THROW ERR_STACKUNDER
            .pend

;
; Disarm every deferred handler and clear the re-entry guard.
;
; Called from CLRINTERP, which is RUN, NEW and (through NEW) LOAD. A
; handler surviving any of those is a line number pointing into a program
; that no longer exists -- FINDLINE would fail on it, or worse, find a
; DIFFERENT line that now has that number.
;
IRQ_DISARM  .proc
            PHP
            setaxl

            CALL ENV_CLEAR              ; and the volume envelopes with them:
                                        ;  same reasoning, and this is also
                                        ;  the path INITBASIC takes, which is
                                        ;  what zeroes the table at boot
            setaxl
            LDA #0
            STA @l IRQ_STATE            ; ARMED and BUSY together
            STA @l IRQ_VLINE
            STA @l IRQ_RLINE
            STA @l IRQ_CLINE

            PLP
            RETURN
            .pend

;
; Check that a handler's line number exists, before arming it.
;
; Inputs:
;   A = the line number, or 0 to disarm
;
; Outputs:
;   A = unchanged, so the caller can store it
;
; Worth the trouble because the alternative is finding out later: an
; ONVSYNC pointing at a line that is not there would throw ERR_NOLINE
; from IRQ_POLL, at whatever statement the frame happened to land on,
; which reads as that statement's fault.
;
; FINDLINE overwrites CURLINE when it succeeds and the program is
; standing on that line, so it is saved and put back. Its answer is in
; the CARRY, which is why nothing here restores P until the branch is
; taken -- see the note about PHP/PLP and flag returns in
; X816/input_x816.s.
;
IRQ_CHKLINE .proc
            PHP
            setaxl

            CMP #0
            BEQ ok                      ; 0 disarms: nothing to look for

            PHA                         ; The caller's line number
            STA ARGUMENT1
            LDA #0
            STA ARGUMENT1+2

            LDA CURLINE
            PHA
            LDA CURLINE+2
            PHA

            CALL FINDLINE

            setaxl
            PLA                         ; PLA moves N and Z but not C
            STA CURLINE+2
            PLA
            STA CURLINE
            PLA                         ; ...and back to the line number
            BCC notfound

ok          PLP
            RETURN
notfound    THROW ERR_NOLINE
            .pend

;
; Recompute IRQ_ARMED from the three line numbers, after one of them
; changed. IRQ_POLL's fast path tests this one byte and nothing else.
;
IRQ_REARM   .proc
            PHP
            setaxl

            LDA @l IRQ_VLINE
            ORA @l IRQ_RLINE
            ORA @l IRQ_CLINE
            BNE some

            setas                       ; An armed envelope wants the same
            LDA @l ENV_ANY              ;  fast path, so it is folded in here
            BEQ none                    ;  rather than costing IRQ_POLL a
                                        ;  second load on every statement of
                                        ;  every program.
some        setas
            LDA #1
            BRA store
none        setas
            LDA #0
store       STA @l IRQ_ARMED

            PLP
            RETURN
            .pend

;
; ONVSYNC line -- run a subroutine once a frame. 0 disarms it.
;
S_ONVSYNC   .proc
            PHP
            TRACE "S_ONVSYNC"

            setaxl
            CALL EVALEXPR
            CALL ASS_ARG1_INT

            setal
            LDA ARGUMENT1
            CALL IRQ_CHKLINE
            STA @l IRQ_VLINE

            JSL KERN_IRQ_FRAMES         ; Arm from the CURRENT frame, so the
            STA @l IRQ_FRAME            ;  first call is at the next one and
                                        ;  not immediately.
            CALL IRQ_REARM

            PLP
            RETURN
            .pend

;
; ONRASTER scanline, line -- run a subroutine when the beam passes a
; scanline. 0 for the line number disarms it.
;
; Read the warning at the top of this file: the subroutine runs at the
; next statement boundary, which is long after the beam has moved on. A
; split screen wants IRQ 1,addr.
;
; The compare line is programmed into VERA but its interrupt is left
; DISABLED in IEN, which is what keeps ISR bit 1 latched for the poll
; instead of being acknowledged by the kernel's dispatcher.
;
S_ONRASTER  .proc
            PHP
            TRACE "S_ONRASTER"

            setaxl
            CALL EVALEXPR               ; The scanline
            CALL ASS_ARG1_INT

            setal
            LDA ARGUMENT1
            CMP #512                    ; Nine bits is all VERA compares
            BCS range_err
            STA @l IRQ_TMP              ; Park it: EVALEXPR owns ARGUMENT1

            setas
            LDA #','
            CALL EXPECT_TOK

            setaxl
            CALL EVALEXPR               ; The BASIC line number
            CALL ASS_ARG1_INT

            setal
            LDA ARGUMENT1
            CALL IRQ_CHKLINE
            STA @l IRQ_RLINE

            setas
            LDA @l IRQ_TMP              ; Low eight bits of the scanline
            STA @l VERA_IRQLINE

            LDA @l VERA_IEN             ; The ninth bit lives in IEN bit 7.
            AND #$8F                    ;  Keep the four enables, drop bit 6
                                        ;  (the read-only scanline bit) and
                                        ;  bit 7, which is about to be set.
            STA @l IRQ_TMP+2
            LDA @l IRQ_TMP+1            ; The scanline's high byte
            AND #$01
            BEQ line_lo
            LDA @l IRQ_TMP+2
            ORA #$80
            BRA line_set
line_lo     LDA @l IRQ_TMP+2
line_set    STA @l VERA_IEN

            LDA #VERA_IRQ_LINE          ; Drop a compare that already
            STA @l VERA_ISR             ;  happened, or the handler fires on
                                        ;  the very next statement.
            CALL IRQ_REARM

            PLP
            RETURN
range_err   THROW ERR_RANGE
            .pend

;
; ONCOLLISION line -- run a subroutine when sprites collide. 0 disarms.
;
; VERA raises the collision at the end of the frame, so this is at best a
; once-a-frame answer to "did anything hit anything", not a report of
; what hit what. The collision MASK is in the top nibble of the ISR and
; is not exposed yet.
;
S_ONCOLLISION .proc
            PHP
            TRACE "S_ONCOLLISION"

            setaxl
            CALL EVALEXPR
            CALL ASS_ARG1_INT

            setal
            LDA ARGUMENT1
            CALL IRQ_CHKLINE
            STA @l IRQ_CLINE

            setas
            LDA #VERA_IRQ_SPRCOL        ; Discard a stale collision
            STA @l VERA_ISR

            CALL IRQ_REARM

            PLP
            RETURN
            .pend

;
; IRQ slot, address -- install a machine-code interrupt handler.
;
; Eleven slots (0-10). Address 0 clears the slot. The handler is entered
; by JSL in native mode with 16-bit registers, D = $0000 and DBR = $00,
; must leave by RTL, and MUST NOT enable interrupts -- the kernel's
; dispatcher has one scratch pointer and one ISR snapshot.
;
; Slots 1, 2 and 3 have their VERA enable bit set here, AFTER the
; install, because the kernel's stuck-source defence turns off any source
; that asserts with no handler behind it -- arming the hardware first
; works right up until the scanline comes round in between.
;
; Slot 0 is VSYNC and its enable is NEVER touched: the kernel's frame
; counter and its blinking cursor both hang off it, and clearing that bit
; would stop FRAMES, WAIT and VSYNC dead. Installing a handler there is
; still allowed -- it just takes the slot off the cursor, which then
; stops blinking until K_CON_CURSOR is called again.
;
S_IRQ       .proc
            PHP
            TRACE "S_IRQ"

            setaxl
            CALL EVALEXPR               ; The slot
            CALL ASS_ARG1_INT

            setal
            LDA ARGUMENT1
            CMP #11                     ; KIRQ_COP is the last one
            BCS range_err
            STA @l IRQ_TMP              ; Park it across the second EVALEXPR

            setas
            LDA #','
            CALL EXPECT_TOK

            setaxl
            CALL EVALEXPR               ; The handler address
            CALL ASS_ARG1_INT

            setaxl
            LDX ARGUMENT1               ; X = handler, low 16
            LDA ARGUMENT1+2
            AND #$00FF
            TAY                         ; Y = handler bank
            LDA @l IRQ_TMP              ; C = slot
            JSL KERN_IRQ_SET            ; Carry SET is failure here: this is
            BCS bad_slot                ;  the kernel's convention, not the
                                        ;  Foenix FK_* one.

            ; ---- enable or disable the source, for the three that need it
            setal
            LDA @l IRQ_TMP
            BEQ done                    ; Slot 0: never touch VSYNC's enable
            CMP #4
            BCS done                    ; Slots 4-10 are not VERA's

            TAX                         ; mask := 1 << slot. LDX has no long
            setas                       ;  addressing mode, so the count goes
            LDA #1                      ;  through A -- the same reason
shift       ASL A                       ;  FK_LOAD passes a bank that way.
            DEX
            BNE shift
            STA @l IRQ_TMP+2            ; The bit this slot owns

            setal
            LDA ARGUMENT1               ; Was a handler installed, or removed?
            ORA ARGUMENT1+2
            BEQ disable

            setas
            LDA @l VERA_IEN
            AND #$8F                    ; Keep IRQLINE's ninth bit, drop the
            ORA @l IRQ_TMP+2            ;  read-only scanline bit
            STA @l VERA_IEN
            BRA done

disable     setas
            LDA @l IRQ_TMP+2
            EOR #$FF                    ; ~mask, bit 7 still set
            STA @l IRQ_TMP+3
            LDA @l VERA_IEN
            AND #$8F
            AND @l IRQ_TMP+3
            STA @l VERA_IEN

done        PLP
            RETURN
range_err   THROW ERR_RANGE
bad_slot    THROW ERR_ARGUMENT
            .pend

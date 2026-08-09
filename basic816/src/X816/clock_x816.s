;;;
;;; A soft clock over the millisecond counter
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; THERE IS NO RTC ON THIS MACHINE, and that is not going to change --
;;; nothing keeps time while the power is off. What there IS is a
;;; free-running 1 kHz counter in hardware and a kernel call that can
;;; MOVE ITS ORIGIN (K_TIME_SET), which help/TIME.TXT already identified
;;; as "the only part of this that is real". That is enough to build a
;;; clock that is told the time once and is right afterwards.
;;;
;;;     SETTIME "14:30:00"      move the origin so the counter reads
;;;                             milliseconds since midnight
;;;     PRINT GETTIME$          14:30:07
;;;
;;; So the counter stops being "milliseconds since boot" and becomes
;;; "milliseconds since midnight". TIMER still reads the same register
;;; and still measures intervals correctly -- a difference of two
;;; readings is unaffected by where the origin sits -- but after SETTIME
;;; it is no longer an uptime. help/TIME.TXT says so.
;;;
;;; THE CLOCK SURVIVES MORE THAN YOU WOULD EXPECT. The counter belongs
;;; to the kernel, not to BASIC, so the time set here outlives RUN, NEW,
;;; a program crash and even QUIT to the shell. It does not outlive a
;;; reset, because nothing does.
;;;
;;; AND IT IS RIGHT FOR 49 DAYS. The counter is 32 bits of
;;; milliseconds, which wraps after 49.7 of them, and 86,400,000 does
;;; not divide 2^32 -- so at the wrap the clock jumps rather than
;;; rolling over cleanly. A machine left on for seven weeks needs
;;; SETTIME again. Saying that is cheaper than pretending otherwise.
;;;
;;; THE DATE IS NOT DERIVED FROM THE CLOCK, it is CARRIED. SETDATE
;;; records a date and the day number the counter was on at that moment;
;;; GETDATE$ adds however many midnights have passed since. That makes
;;; the date roll at midnight and exactly at midnight, because the day
;;; boundary is a multiple of 86,400,000 in the same counter SETTIME
;;; aligned. Before SETDATE the date is genuinely unknown and reads
;;; 0000-00-00, which is meant to look wrong.
;;;

CLK_DAY         = 86400000      ; milliseconds in a day
CLK_HOUR        = 3600000
CLK_MIN         = 60000
CLK_SEC         = 1000

;
; Days in each month, in a common year. February is corrected in
; CLK_MLEN rather than in a second table.
;
clk_mtab        .byte 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

;
; CLK_T := the millisecond counter.
;
CLK_NOW         .proc
                PHP
                setaxl
                JSL KERN_TIME_GET           ; C = low 16, X = high 16
                STA @l CLK_T
                TXA
                STA @l CLK_T+2
                PLP
                RETURN
                .pend

;
; CLK_V := CLK_T / CLK_U, and CLK_T := the remainder.
;
; The whole of the formatting below is this called four times, which is
; why it is worth a routine: hours out of the day, minutes out of what
; is left, and so on down to seconds.
;
CLK_DIVT        .proc
                PHP
                setaxl

                LDA @l CLK_T
                STA ARGUMENT1
                LDA @l CLK_T+2
                STA ARGUMENT1+2
                LDA @l CLK_U
                STA ARGUMENT2
                LDA @l CLK_U+2
                STA ARGUMENT2+2
                CALL UDIV32

                setaxl
                LDA ARGUMENT1               ; the quotient, which every
                STA @l CLK_V                ;  caller here knows is small
                LDA ARGUMENT2               ; and the remainder, back into
                STA @l CLK_T                ;  CLK_T for the next divide
                LDA ARGUMENT2+2
                STA @l CLK_T+2

                PLP
                RETURN
                .pend

;
; Set CLK_U to a 32-bit constant. A macro because the alternative is
; four lines repeated eight times.
;
; >> 16 and NOT the ` operator: ` gives the BANK byte, bits 16-23, and
; 86,400,000 is $05265C00 -- so the day divisor came out as $00265C00
; and every time of day was reduced by the wrong number. The other three
; constants are under 2^24, where the two spellings agree, which is why
; only the day was wrong and only inside GETTIME$.
CLKDIV          .macro
                setaxl
                LDA #<>\1
                STA @l CLK_U
                LDA #(\1) >> 16
                STA @l CLK_U+2
                .endm

;
; Append the low byte of A to the string being built.
;
CLK_PUTC        .proc
                PHP
                setaxl
                PHY

                PHA                         ; LDY has no long addressing
                LDA @l CLK_N                ;  mode, so the index goes
                TAY                         ;  through A -- and A is holding
                PLA                         ;  the character, hence the push
                setas
                STA [STRPTR],Y

                setaxl
                LDA @l CLK_N
                INC A
                STA @l CLK_N

                PLY
                PLP
                RETURN
                .pend

;
; Append CLK_V as exactly two digits, leading zero and all.
;
; "9:05" is not a time and "09:05" is: a clock that dropped the zero
; would be shorter and wrong, and every caller here wants a fixed width
; so that two of these can be compared as strings.
;
CLK_PUT2        .proc
                PHP
                setaxl

                LDA @l CLK_V
                STA ARGUMENT1
                LDA #0
                STA ARGUMENT1+2
                LDA #10
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2
                CALL UDIV32

                setaxl
                LDA ARGUMENT1               ; tens
                CLC
                ADC #'0'
                CALL CLK_PUTC
                setaxl
                LDA ARGUMENT2               ; and units, out of the remainder
                CLC
                ADC #'0'
                CALL CLK_PUTC

                PLP
                RETURN
                .pend

;
; Append CLK_V as four digits, for the year.
;
CLK_PUT4        .proc
                PHP
                setaxl

                LDA @l CLK_V
                STA ARGUMENT1
                LDA #0
                STA ARGUMENT1+2
                LDA #100
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2
                CALL UDIV32

                setaxl
                LDA ARGUMENT2               ; keep the low pair before the
                STA @l CLK_W                ;  next divide overwrites it
                LDA ARGUMENT1
                STA @l CLK_V
                CALL CLK_PUT2

                setaxl
                LDA @l CLK_W
                STA @l CLK_V
                CALL CLK_PUT2

                PLP
                RETURN
                .pend

;
; GETTIME$ -- the time of day, "HH:MM:SS".
;
; No parentheses, like TIMER and FRAMES. The stub this replaces was a
; FUNCTION WITH AN ARGUMENT that returned the INTEGER 0 -- from
; something named with a dollar sign -- so a program that used it got a
; type error rather than a wrong time, which is the one merciful thing
; about it.
;
F_GETTIME       .proc
                TRACE "F_GETTIME"
                PHP
                setaxl

                CALL CLK_NOW
                CLKDIV CLK_DAY              ; drop whole days: what is left
                CALL CLK_DIVT               ;  is the time of day

                CALL TEMPSTRING
                setaxl
                LDA #0
                STA @l CLK_N

                CLKDIV CLK_HOUR
                CALL CLK_DIVT
                CALL CLK_PUT2
                setaxl
                LDA #':'
                CALL CLK_PUTC

                CLKDIV CLK_MIN
                CALL CLK_DIVT
                CALL CLK_PUT2
                setaxl
                LDA #':'
                CALL CLK_PUTC

                CLKDIV CLK_SEC
                CALL CLK_DIVT
                CALL CLK_PUT2

                setaxl
                LDA @l CLK_N                ; SB_RETSTR wants the length in Y
                TAY
                CALL SB_RETSTR

                PLP
                RETURN
                .pend

;
; Days in month CLK_M of year CLK_Y, into A.
;
; The leap rule in full -- divisible by 4, except centuries, except
; every fourth century. 2000 was a leap year and 1900 was not, and a
; clock that got that wrong would be wrong for a day every hundred
; years, which is exactly long enough for nobody to have tested it.
;
CLK_MLEN        .proc
                PHP
                setaxl
                PHX

                LDA @l CLK_M
                DEC A
                AND #$000F
                TAX
                setas
                LDA @l clk_mtab,X
                setal
                AND #$00FF
                STA @l CLK_W

                LDA @l CLK_M                ; February is the only one that
                CMP #2                      ;  ever moves
                BNE ml_done

                LDA @l CLK_Y                ; divisible by 4?
                AND #3
                BNE ml_done

                LDA @l CLK_Y                ; ...and by 100?
                STA ARGUMENT1
                LDA #0
                STA ARGUMENT1+2
                LDA #100
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2
                CALL UDIV32
                setaxl
                LDA ARGUMENT2
                BNE ml_leap                 ; not a century: it is a leap year

                LDA @l CLK_Y                ; a century, so it must divide
                STA ARGUMENT1               ;  by 400 as well
                LDA #0
                STA ARGUMENT1+2
                LDA #400
                STA ARGUMENT2
                LDA #0
                STA ARGUMENT2+2
                CALL UDIV32
                setaxl
                LDA ARGUMENT2
                BNE ml_done

ml_leap         LDA #29
                STA @l CLK_W

ml_done         setaxl
                LDA @l CLK_W
                PLX
                PLP
                RETURN
                .pend

;
; Advance CLK_Y/CLK_M/CLK_D by one day.
;
CLK_NEXTDAY     .proc
                PHP
                setaxl

                LDA @l CLK_D
                INC A
                STA @l CLK_D

                CALL CLK_MLEN
                setaxl
                CMP @l CLK_D                ; still inside the month?
                BCS nd_done

                LDA #1                      ; no: the first of the next one
                STA @l CLK_D
                LDA @l CLK_M
                INC A
                STA @l CLK_M
                CMP #13
                BCC nd_done
                LDA #1
                STA @l CLK_M
                LDA @l CLK_Y
                INC A
                STA @l CLK_Y

nd_done         PLP
                RETURN
                .pend

;
; GETDATE$ -- the date, "YYYY-MM-DD".
;
; The stored date plus however many midnights have gone by since
; SETDATE recorded it. The day boundary is a multiple of 86,400,000 in
; the same counter SETTIME aligned, so this rolls over AT midnight and
; not merely 24 hours after the date was set.
;
; Advancing one day at a time rather than by arithmetic: the counter
; wraps after 49 days, so the loop can never run more than about fifty
; times, and a closed-form civil-date conversion is a great deal more
; code to get wrong for no gain anybody could measure.
;
F_GETDATE       .proc
                TRACE "F_GETDATE"
                PHP
                setaxl

                LDA @l CLK_DSET             ; never set: the machine does not
                BEQ gd_format               ;  know, and 0000-00-00 is meant
                                            ;  to look wrong
                CALL CLK_NOW
                CLKDIV CLK_DAY
                CALL CLK_DIVT               ; CLK_V = today's day number

                setaxl
                LDA @l CLK_V
                SEC
                SBC @l CLK_BASE             ; how many midnights since
                STA @l CLK_R                ;  SETDATE. Unsigned: the counter
                                            ;  wrapping backwards would give a
                                            ;  huge number, and the cap below
                                            ;  is what stops it mattering
                CMP #64
                BCC gd_roll
                LDA #0                      ; the counter wrapped: the date is
                STA @l CLK_R                ;  no longer knowable, so leave it
                                            ;  where it was rather than
gd_roll                                     ;  inventing a future
                LDA @l CLK_R                ; CLK_R and not CLK_W: CLK_MLEN
                BEQ gd_format               ;  uses CLK_W as scratch and the
gd_loop         CALL CLK_NEXTDAY            ;  loop below calls it, so the
                setaxl                      ;  counter was overwritten with a
                LDA @l CLK_R                ;  month length on the first pass
                DEC A                       ;  and walked a month forward
                STA @l CLK_R
                BNE gd_loop

                LDA @l CLK_V                ; today becomes the new base, so
                STA @l CLK_BASE             ;  the walk above is never redone

gd_format       CALL TEMPSTRING
                setaxl
                LDA #0
                STA @l CLK_N

                LDA @l CLK_Y
                STA @l CLK_V
                CALL CLK_PUT4
                setaxl
                LDA #'-'
                CALL CLK_PUTC

                LDA @l CLK_M
                STA @l CLK_V
                CALL CLK_PUT2
                setaxl
                LDA #'-'
                CALL CLK_PUTC

                LDA @l CLK_D
                STA @l CLK_V
                CALL CLK_PUT2

                setaxl
                LDA @l CLK_N                ; SB_RETSTR wants the length in Y
                TAY
                CALL SB_RETSTR

                PLP
                RETURN
                .pend

;
; Step the parse cursor one character on.
;
CLK_STEP        .proc
                PHP
                setal
                INC MTEMP
                BNE cs_done
                INC MTEMP+2
cs_done         PLP
                RETURN
                .pend

;
; Read the next decimal number out of the string into CLK_V, skipping
; whatever separates it from the last one.
;
; ANY non-digit separates, so "14:30:00", "14-30-00" and "14 30 00" all
; read the same. A clock statement is not the place to be strict about
; punctuation, and the alternative is three spellings of the same
; error message.
;
CLK_NUM         .proc
                PHP
                setaxl

                LDA #0
                STA @l CLK_V

cn_skip         setas
                LDA [MTEMP]
                BEQ cn_done                 ; end of string
                CMP #'0'
                BCC cn_sep
                CMP #'9'+1
                BCC cn_digits
cn_sep          CALL CLK_STEP
                BRA cn_skip

cn_digits       setas
                LDA [MTEMP]
                CMP #'0'
                BCC cn_done
                CMP #'9'+1
                BCS cn_done

                SEC
                SBC #'0'
                setal
                AND #$00FF
                STA @l CLK_W

                LDA @l CLK_V                ; v = v*10 + digit
                ASL A
                STA @l CLK_X
                ASL A
                ASL A
                CLC
                ADC @l CLK_X
                CLC
                ADC @l CLK_W
                STA @l CLK_V

                CALL CLK_STEP
                BRA cn_digits

cn_done         PLP
                RETURN
                .pend

;
; Point MTEMP at the string argument of a SETTIME/SETDATE.
;
CLK_ARGSTR      .proc
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_STR
                setal
                LDA ARGUMENT1               ; MTEMP is the cursor: [ptr] lives
                STA MTEMP                   ;  in the direct page and a string
                LDA ARGUMENT1+2             ;  can be in any bank. Set AFTER
                STA MTEMP+2                 ;  the EVALEXPR, never before.

                PLP
                RETURN
                .pend

;
; CLK_ACC += CLK_V * <the 32-bit constant>.
;
CLKADD          .macro
                setaxl
                LDA @l CLK_V
                STA ARGUMENT1
                LDA #0
                STA ARGUMENT1+2
                LDA #<>\1
                STA ARGUMENT2
                LDA #(\1) >> 16             ; see the note by CLKDIV
                STA ARGUMENT2+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                STA ARGTYPE2
                setal
                CALL OP_INT_MUL
                setaxl
                CLC
                LDA @l CLK_ACC
                ADC ARGUMENT1
                STA @l CLK_ACC
                LDA @l CLK_ACC+2
                ADC ARGUMENT1+2
                STA @l CLK_ACC+2
                .endm

;
; SETTIME "HH:MM:SS" -- tell the machine what time it is.
;
; It does not set a clock; it MOVES THE ORIGIN of the millisecond
; counter, so that the counter itself reads milliseconds since
; midnight. Everything else here is arithmetic on that one number.
;
S_SETTIME       .proc
                PHP
                TRACE "S_SETTIME"
                setaxl

                CALL CLK_ARGSTR

                LDA #0
                STA @l CLK_ACC
                STA @l CLK_ACC+2

                CALL CLK_NUM                ; hours
                CLKADD CLK_HOUR
                CALL CLK_NUM                ; minutes
                CLKADD CLK_MIN
                CALL CLK_NUM                ; seconds
                CLKADD CLK_SEC

                setaxl                      ; C = low 16, X = high 16
                LDA @l CLK_ACC+2
                TAX
                LDA @l CLK_ACC
                JSL KERN_TIME_SET

                PLP
                RETURN
                .pend

;
; SETDATE "YYYY-MM-DD" -- tell it the date.
;
; Stored, together with the day number the counter is on right now, so
; that GETDATE$ can tell how many midnights have gone by. SETTIME
; first, then SETDATE: setting the time moves the day boundary, and a
; date recorded against the old boundary would roll over at the wrong
; moment. help/TIME.TXT says so in as many words.
;
S_SETDATE       .proc
                PHP
                TRACE "S_SETDATE"
                setaxl

                CALL CLK_ARGSTR

                CALL CLK_NUM                ; year
                setaxl
                LDA @l CLK_V
                STA @l CLK_Y

                CALL CLK_NUM                ; month
                setaxl
                LDA @l CLK_V
                BNE sd_mok
                LDA #1
sd_mok          CMP #13
                BCC sd_mput
                LDA #12
sd_mput         STA @l CLK_M

                CALL CLK_NUM                ; day
                setaxl
                LDA @l CLK_V
                BNE sd_dok
                LDA #1
sd_dok          STA @l CLK_D
                CALL CLK_MLEN               ; clamped to the month's length,
                setaxl                      ;  so a 31st of February cannot
                CMP @l CLK_D                ;  sit there waiting to confuse
                BCS sd_dput                 ;  the roll-over
                STA @l CLK_D
sd_dput
                CALL CLK_NOW                ; and the day the counter is on
                CLKDIV CLK_DAY
                CALL CLK_DIVT
                setaxl
                LDA @l CLK_V
                STA @l CLK_BASE

                LDA #1
                STA @l CLK_DSET

                PLP
                RETURN
                .pend

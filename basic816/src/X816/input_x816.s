;;;
;;; Joystick, I2C, and the mouse
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; Neither device has a kernel call, so both are bit-banged, and both
;;; hang off the same VIA port -- $9F01, with its direction register at
;;; $9F03. PA0 and PA1 are the I2C data and clock lines to the system
;;; controller; PA2 and PA3 are the latch and clock of the controller
;;; shift register; PA4 to PA7 are the four controllers' data lines.
;;;
;;; The two halves must not disturb each other. Everything below
;;; therefore touches only the direction bits it owns, and the joystick
;;; code never writes a 1 into PA0 or PA1: while those are inputs the
;;; VIA reads them as pulled up whatever the output register says, and
;;; the moment the keyboard's I2C traffic resumes it needs them exactly
;;; as it left them.
;;;
;;; I2C here is genuine open-drain. A line is pulled low by making it an
;;; OUTPUT (its output bit is always 0), and released by making it an
;;; INPUT so the pull-up takes it high. Driving a 1 would fight the
;;; devices on the bus.
;;;
;;; No delays are inserted between edges. The emulator advances its bus
;;; state machine on the writes themselves, so it needs none; real
;;; hardware at 100 kHz would, and this is the file where they go.
;;;

VIA1_PA         = $9F01     ; I2C 1:0, joystick latch 2 clock 3, data 7:4
VIA1_DDRA       = $9F03     ; 1 = output

I2C_SDA         = $01
I2C_SCL         = $02
JOY_LATCH       = $04
JOY_CLK         = $08

I2C_SMC         = $42       ; the system controller: keyboard, mouse, power

;;;
;;; Controllers
;;;

;
; One pass of the shift register: all four pads at once, and whether each
; of them is really there.
;
; The register is SNES-shaped: pulse the latch to snapshot every
; controller, then read a bit and clock for the next, sixteen times. The
; wire is active low and the top four bits are tied high, so the word is
; inverted on the way out -- which is what makes an absent controller
; read as no buttons rather than as every button at once.
;
; Reading one pad and reading four cost exactly the same, because they
; shift out TOGETHER on their own data lines -- so the scan always does
; all four and JOY(n) picks one out afterwards. That is also what makes
; JOYSCAN worth having.
;
; PRESENCE, which is the part that is not obvious. A present pad with
; nothing pressed and an empty socket both read as "no buttons", so the
; sixteen data bits cannot tell them apart. The eight clocks AFTER them
; can: the SNES register keeps shifting out ZEROS once it is empty,
; while an absent line floats HIGH. Confirmed in the emulator's
; joystick.c -- do_shift() sets the line for a missing slot and shifts a
; 16-bit register that has run out for a present one -- rather than
; assumed from the X16.
;
JOY_DOSCAN      .proc
                PHP
                setaxl                  ; BEFORE the pushes: the pops below
                                        ;  are 16-bit, so the pushes must be
                PHX
                PHY

                setas
                LDA @l VIA1_DDRA        ; latch and clock are ours; the two
                ORA #JOY_LATCH|JOY_CLK  ;  I2C bits below are not
                STA @l VIA1_DDRA

                LDA #JOY_CLK            ; clock high, latch low: the resting
                STA @l VIA1_PA          ;  state the sequence starts from
                LDA #JOY_LATCH|JOY_CLK  ; latch high snapshots every pad and
                STA @l VIA1_PA          ;  presents bit 0
                LDA #JOY_CLK
                STA @l VIA1_PA

                setal                   ; four accumulators, and the one the
                LDA #0                  ;  presence bits are ORed into
                STA @l JOY_P
                STA @l JOY_P+2
                STA @l JOY_P+4
                STA @l JOY_P+6
                setas
                STA @l JOY_H
                LDA #16
                STA @l JOY_C

                ; ---- the sixteen data bits ----
js_bit          setas
                LDA @l VIA1_PA          ; every pad's line in one read
                STA @l JOY_W

                ; Pad n sits on bit 7-n, so n+1 shifts left put its bit in
                ; the carry. Unrolled: an inner loop would have to rebuild
                ; the count every pass for four instructions of work.
                ASL A                   ; pad 0, bit 7
                setal
                LDA @l JOY_P            ; LDA does not touch the carry, so
                ROR A                   ;  the bit survives the width change
                STA @l JOY_P            ;  and the load between

                setas
                LDA @l JOY_W
                ASL A
                ASL A                   ; pad 1, bit 6
                setal
                LDA @l JOY_P+2
                ROR A
                STA @l JOY_P+2

                setas
                LDA @l JOY_W
                ASL A
                ASL A
                ASL A                   ; pad 2, bit 5
                setal
                LDA @l JOY_P+4
                ROR A
                STA @l JOY_P+4

                setas
                LDA @l JOY_W
                ASL A
                ASL A
                ASL A
                ASL A                   ; pad 3, bit 4
                setal
                LDA @l JOY_P+6
                ROR A
                STA @l JOY_P+6

                CALL JOY_CLOCK

                setas
                LDA @l JOY_C
                DEC A
                STA @l JOY_C
                BNE js_bit

                ; ---- eight more, which say who answered ----
                setas
                LDA #8
                STA @l JOY_C
js_more         setas
                LDA @l VIA1_PA
                AND #$F0                ; only the four data lines
                ORA @l JOY_H            ; any high bit, any time, is silence
                STA @l JOY_H

                CALL JOY_CLOCK

                setas
                LDA @l JOY_C
                DEC A
                STA @l JOY_C
                BNE js_more

                setas                   ; release the two lines we drove
                LDA @l VIA1_DDRA
                AND #$FF-JOY_LATCH-JOY_CLK
                STA @l VIA1_DDRA

                ; ---- and turn the wire into buttons ----
                ; Active low, and the top nibble is tied high, so this
                ; makes "not held" 0 and drops the four that are never
                ; buttons.
                setaxl
                LDX #0
js_flip         LDA @l JOY_P,X
                EOR #$FFFF
                AND #$0FFF
                STA @l JOY_P,X
                INX
                INX
                CPX #8
                BCC js_flip

                PLY
                PLX
                PLP
                RETURN
                .pend

;
; One clock: low, then high, and the next bit is presented.
;
JOY_CLOCK       .proc
                PHP
                setas
                LDA #0
                STA @l VIA1_PA
                LDA #JOY_CLK
                STA @l VIA1_PA
                PLP
                RETURN
                .pend

;
; X := (ARGUMENT1 AND 3) * 2 -- which pad, as an offset into JOY_P.
;
JOY_SEL         .proc
                PHP
                setaxl
                LDA ARGUMENT1
                AND #$0003
                ASL A
                TAX
                PLP
                RETURN
                .pend

;
; JOY(n) -- the buttons held on controller 0 to 3, one per bit, 1 held.
;
;   bit 0 A       bit 4 up      bit 8  B
;   bit 1 X       bit 5 down    bit 9  Y
;   bit 2 select  bit 6 left    bit 10 left shoulder
;   bit 3 start   bit 7 right   bit 11 right shoulder
;
; Takes a fresh scan every time, so it is always live. JOYX, JOYY and
; JOYFIRE do the same; only JOYHIT reports the last scan rather than
; taking one, because "was that pad there" is a question about a reading
; already made.
;
FN_JOY          .proc
                FN_START "FN_JOY"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                CALL JOY_DOSCAN
                CALL JOY_SEL

                LDA @l JOY_P,X
                STA ARGUMENT1
                STZ ARGUMENT1+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

;
; JOYSCAN -- take one snapshot of all four pads.
;
; What it is for is JOYHIT: four separate JOYHIT() calls would otherwise
; each be asking about whatever scan happened to have run last. One
; JOYSCAN and four JOYHITs all describe the same instant.
;
S_JOYSCAN       .proc
                PHP
                TRACE "S_JOYSCAN"
                setaxl
                CALL JOY_DOSCAN
                PLP
                RETURN
                .pend

;
; JOYHIT(n) -- did pad n answer the last scan? -1 yes, 0 no.
;
; Does NOT scan. An absent pad and a present pad with nothing pressed
; both read as no buttons, so this is the only way to tell a controller
; that is unplugged from one that is merely idle.
;
FN_JOYHIT       .proc
                FN_START "FN_JOYHIT"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setaxl                  ; the mask in 16 bits, because TAX
                LDA ARGUMENT1           ;  with an 8-bit A and a 16-bit X
                AND #$0003              ;  carries the HIDDEN high byte into
                TAX                     ;  X, and it can be anything
                setas
                LDA @l JOY_H            ; pad n is on bit 7-n
jh_shift        CPX #0
                BEQ jh_test
                ASL A
                DEX
                BRA jh_shift

jh_test         AND #$80                ; set means the line was high, which
                BEQ jh_present          ;  means nobody was driving it
                setal
                LDA #0
                STA ARGUMENT1
                STZ ARGUMENT1+2
                BRA jh_type

jh_present      setal
                LDA #$FFFF              ; true, the way this BASIC spells it
                STA ARGUMENT1
                STA ARGUMENT1+2

jh_type         setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

;
; The beginner's layer: JOYX and JOYY as -1, 0 or 1, and JOYFIRE.
;
; The bitmap is the wrong first thing to hand somebody -- "IF JOYX(0)=1"
; is one line in a game loop where AND-ing a mask is three. Both layers
; are worth having, which is why the bitmap did not go away.
;
; Inputs:
;   A = the mask for the negative direction, X = for the positive
;
JOY_AXIS        .proc
                PHP
                setaxl

                STA @l JOY_MN           ; the two masks, parked somewhere
                TXA                     ;  the scan does not touch
                STA @l JOY_MP

                CALL JOY_DOSCAN
                CALL JOY_SEL
                LDA @l JOY_P,X
                STA @l JOY_V            ; the pad, parked past the next AND

                AND @l JOY_MN           ; negative?
                BNE ja_minus

                LDA @l JOY_V
                AND @l JOY_MP           ; positive?
                BNE ja_plus

                LDA #0                  ; neither, or both
                STA ARGUMENT1
                STZ ARGUMENT1+2
                BRA ja_type

ja_minus        LDA #$FFFF
                STA ARGUMENT1
                STA ARGUMENT1+2
                BRA ja_type

ja_plus         LDA #1
                STA ARGUMENT1
                STZ ARGUMENT1+2

ja_type         setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                PLP
                RETURN
                .pend

;
; JOYX(n) -- -1 left, 1 right, 0 neither.
;
FN_JOYX         .proc
                FN_START "FN_JOYX"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                LDA #$0040              ; bit 6 left
                LDX #$0080              ; bit 7 right
                CALL JOY_AXIS

                FN_END
                PLP
                RETURN
                .pend

;
; JOYY(n) -- -1 up, 1 down, 0 neither. Y counts DOWN the screen, so down
; is the positive one.
;
FN_JOYY         .proc
                FN_START "FN_JOYY"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                LDA #$0010              ; bit 4 up
                LDX #$0020              ; bit 5 down
                CALL JOY_AXIS

                FN_END
                PLP
                RETURN
                .pend

;
; JOYFIRE(n) -- -1 if the main button is held, 0 if not.
;
; A or B, because which of the two is "the" button is a matter of taste
; and a game that cares can read the bitmap.
;
FN_JOYFIRE      .proc
                FN_START "FN_JOYFIRE"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                CALL JOY_DOSCAN
                CALL JOY_SEL

                LDA @l JOY_P,X
                AND #$0101              ; bit 0 is A, bit 8 is B
                BEQ jf_no

                LDA #$FFFF
                STA ARGUMENT1
                STA ARGUMENT1+2
                BRA jf_type

jf_no           LDA #0
                STA ARGUMENT1
                STZ ARGUMENT1+2

jf_type         setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

;;;
;;; I2C, bit-banged on PA0 and PA1
;;;

;
; Every routine from here to I2C_GETREG runs with an 8-bit accumulator
; and returns its answer in the CARRY, and for that reason NONE of them
; saves the processor status.
;
; The first draft did. It cost an afternoon: I2C_TXBYTE ended with a PLP
; after reading the acknowledge bit, so the flags -- carry included --
; were restored to what they had been on entry and the answer was thrown
; away. Every transfer then looked acknowledged whether or not anything
; was listening. PHP and a result in the carry cannot both be had, so
; only I2C_GETREG brackets the width, once, around the lot.
;

;
; Release a line: make it an input, and the pull-up takes it high.
; A = the pin mask.
;
I2C_HI          .proc
                EOR #$FF
                AND @l VIA1_DDRA
                STA @l VIA1_DDRA
                RETURN
                .pend

;
; Pull a line low: make it an output, its output bit being always 0.
; A = the pin mask.
;
I2C_LO          .proc
                ORA @l VIA1_DDRA
                STA @l VIA1_DDRA
                RETURN
                .pend

;
; Both lines idle, and the output bits zeroed so that "output" can only
; ever mean "pulled low".
;
I2C_IDLE        .proc
                LDA @l VIA1_PA
                AND #$FF-I2C_SDA-I2C_SCL
                STA @l VIA1_PA
                LDA #I2C_SDA|I2C_SCL
                CALL I2C_HI
                RETURN
                .pend

;
; START: data falls, then clock.
;
I2C_START       .proc
                CALL I2C_IDLE
                LDA #I2C_SDA
                CALL I2C_LO
                LDA #I2C_SCL
                CALL I2C_LO
                RETURN
                .pend

;
; STOP: clock rises, then data.
;
I2C_STOP        .proc
                LDA #I2C_SDA
                CALL I2C_LO
                LDA #I2C_SCL
                CALL I2C_HI
                LDA #I2C_SDA
                CALL I2C_HI
                RETURN
                .pend

;
; Clock out the one bit in the carry.
;
I2C_TXBIT       .proc
                BCC tx_zero
                LDA #I2C_SDA
                CALL I2C_HI
                BRA tx_clock
tx_zero         LDA #I2C_SDA
                CALL I2C_LO
tx_clock        LDA #I2C_SCL
                CALL I2C_HI
                LDA #I2C_SCL
                CALL I2C_LO
                RETURN
                .pend

;
; Clock in one bit, returned in the carry.
;
I2C_RXBIT       .proc
                LDA #I2C_SDA            ; let the device drive the line
                CALL I2C_HI
                LDA #I2C_SCL
                CALL I2C_HI
                LDA @l VIA1_PA
                AND #I2C_SDA
                STA @l I2C_W
                LDA #I2C_SCL
                CALL I2C_LO
                LDA @l I2C_W
                CMP #1                  ; nonzero sets the carry
                RETURN
                .pend

;
; Send the byte in A. Carry CLEAR on return means the device answered.
;
I2C_TXBYTE      .proc
                PHY
                STA @l I2C_B
                LDY #8
tb_loop         LDA @l I2C_B            ; ASL has no long addressing mode, so
                ASL A                   ;  the byte is shifted in A and put
                STA @l I2C_B            ;  back; STA leaves the carry alone,
                CALL I2C_TXBIT          ;  so the bit reaches TXBIT intact
                DEY
                BNE tb_loop

                CALL I2C_RXBIT          ; the acknowledge: 0 means yes
                PLY                     ; PLY touches N and Z, never C
                RETURN
                .pend

;
; Read a byte into A. Carry set on entry asks for a NACK, which is how a
; master says "that was the last one".
;
I2C_RXBYTE      .proc
                PHY
                LDA #0
                ROL A                   ; keep the caller's ack choice
                STA @l I2C_ACK
                LDA #0
                STA @l I2C_B

                LDY #8
rb_loop         CALL I2C_RXBIT          ; bit arrives in the carry
                LDA @l I2C_B
                ROL A
                STA @l I2C_B
                DEY
                BNE rb_loop

                LDA @l I2C_ACK          ; and answer
                LSR A
                CALL I2C_TXBIT

                LDA @l I2C_B
                PLY
                RETURN
                .pend

;
; Read one register of an I2C device.
;
; Two transactions: write the register number, then read the byte.
;
; A REPEATED start will not do, even though that is the textbook way and
; what the register number being remembered across the gap is normally
; for. This bus recognises a start only from the stopped state, so a
; repeated one is silently taken for a data bit and everything after it
; is nonsense. A full stop in the middle is what works, and the device
; keeps the register number across it.
;
; Device in I2C_DEV, register in I2C_REG, result in A. Carry set if
; nobody answered.
;
I2C_GETREG      .proc
                PHP
                setas

                CALL I2C_START
                LDA @l I2C_DEV          ; address, write
                ASL A
                CALL I2C_TXBYTE
                BCS ig_fail
                LDA @l I2C_REG
                CALL I2C_TXBYTE
                BCS ig_fail
                CALL I2C_STOP           ; a full stop, not a repeated start

                CALL I2C_START          ; and round again, now reading
                LDA @l I2C_DEV
                ASL A
                ORA #$01
                CALL I2C_TXBYTE
                BCS ig_fail

                SEC                     ; one byte only, so NACK it
                CALL I2C_RXBYTE
                STA @l I2C_B
                CALL I2C_STOP
                CALL I2C_IDLE

                LDA @l I2C_B
                PLP
                CLC
                RETURN

ig_fail         CALL I2C_STOP
                CALL I2C_IDLE
                PLP
                SEC
                RETURN
                .pend

;
; Write one register: I2C_DEV, I2C_REG, and the byte in I2C_V.
;
; I2C_V and NOT I2C_B, which is the obvious place and is wrong: I2C_B is
; I2C_TXBYTE's own shift register, and the address and register bytes
; leave it at zero on their way out. A value parked there before them
; arrived as 0, so I2CPOKE quietly wrote zeros -- and the one thing it
; was tested against, the SMC's mouse device ID, has 0 as a legal value,
; so it looked like a write that had not happened rather than one that
; had happened wrongly.
;
; Simpler than the read, and for the reason the read is complicated: a
; write is one transfer. There is no direction change, so none of the
; stop-and-start-again dance in I2C_GETREG is needed.
;
; Carry set on failure, like everything else here -- and set AFTER the
; PLP, because the answer IS the carry.
;
I2C_SETREG      .proc
                PHP
                setas

                CALL I2C_START
                LDA @l I2C_DEV          ; address, write
                ASL A
                CALL I2C_TXBYTE
                BCS is_fail
                LDA @l I2C_REG
                CALL I2C_TXBYTE
                BCS is_fail
                LDA @l I2C_V
                CALL I2C_TXBYTE
                BCS is_fail

                CALL I2C_STOP
                CALL I2C_IDLE
                PLP
                CLC
                RETURN

is_fail         CALL I2C_STOP
                CALL I2C_IDLE
                PLP
                SEC
                RETURN
                .pend

;
; I2CPOKE dev, reg, val -- write one register of any device on the bus.
;
; The other half of I2CPEEK, and what MOUSEON needs: asking the system
; controller for a wheel-capable mouse is a write to register $20.
;
S_I2CPOKE       .proc
                PHP
                TRACE "S_I2CPOKE"
                setaxl

                CALL EVALEXPR           ; the device
                CALL ASS_ARG1_BYTE
                setas
                LDA ARGUMENT1
                STA @l I2C_DEV

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; the register
                CALL ASS_ARG1_BYTE
                setas
                LDA ARGUMENT1
                STA @l I2C_REG

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR           ; the value
                CALL ASS_ARG1_BYTE
                setas
                LDA ARGUMENT1
                STA @l I2C_V

                CALL I2C_SETREG         ; a device that is not there NACKs,
                                        ;  and there is nothing useful to do
                                        ;  about it: a poke has no answer
                PLP
                RETURN
                .pend

;
; I2CPEEK(dev, reg) -- read one register of any device on the bus.
;
; The escape hatch, and also the only part of this file that can be
; checked without a mouse plugged in: the system controller reports its
; own firmware version at registers $30 to $32, so
;
;   PRINT I2CPEEK(&h42,&h30)
;
; exercises start, address, register, repeated start, eight shifted-in
; bits, NACK and stop, and compares the result against a number that was
; not produced by this code. Returns -1 if the device does not answer.
;
FN_I2CPEEK      .proc
                FN_START "FN_I2CPEEK"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                setas
                LDA ARGUMENT1
                STA @l I2C_DEV

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                setas
                LDA ARGUMENT1
                STA @l I2C_REG

                CALL I2C_GETREG
                BCS ip_none

                setal
                AND #$00FF
                STA ARGUMENT1
                STZ ARGUMENT1+2
                BRA ip_type

ip_none         setal
                LDA #$FFFF
                STA ARGUMENT1
                STA ARGUMENT1+2

ip_type         setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

;;;
;;; Mouse
;;;
;;; The system controller buffers PS/2 movement packets and hands them
;;; over three bytes at a time at register $21: flags, then a signed X
;;; step, then a signed Y step. It answers with a single zero when no
;;; whole packet is waiting, which is the only "no data" signal there
;;; is -- so a first byte of zero ends the poll.
;;;
;;; Steps are relative, so the position below is SuperBasic's, not the
;;; hardware's: it is accumulated here and clamped to the screen.
;;;

;
; Drain every packet the controller has and fold them into MOUSE_X,
; MOUSE_Y and MOUSE_B.
;
MOUSE_POLL      .proc
                PHP
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHX
                PHY

                ; How long is a packet? The controller serves FOUR bytes
                ; for a wheel mouse and three for a plain one, and it is
                ; counting them, not us -- so reading three of a four-byte
                ; packet leaves a byte behind and every packet after it is
                ; read one byte out of step. Ask, once per poll, rather
                ; than remember: MOUSEON is not the only thing that can
                ; change the device ID (I2CPOKE can, and so can a mouse
                ; being plugged in).
                setas
                LDA #I2C_SMC
                STA @l I2C_DEV
                LDA #$22                ; the device ID
                STA @l I2C_REG
                CALL I2C_GETREG
                BCS mp_three
                CMP #3                  ; 3 and 4 are the wheel mice
                BEQ mp_four
                CMP #4
                BEQ mp_four
mp_three        LDA #3
                BRA mp_size
mp_four         LDA #4
mp_size         STA @l MOUSE_PK

                LDY #0                  ; a bounded number of packets, so a
mp_packet       CPY #16                 ;  controller that always has one
                BCC mp_run              ;  cannot wedge the interpreter
                JMP mp_done

                ; The fourth byte made the body longer than a relative
                ; branch can cross, so the two exits get a trampoline
                ; each. Control never falls into them: the JMP above is
                ; unconditional.
mp_tostop       JMP mp_stop

mp_run          PHY

                setas
                LDA #I2C_SMC
                STA @l I2C_DEV
                LDA #$21
                STA @l I2C_REG
                CALL I2C_GETREG
                BCS mp_tostop
                CMP #0
                BEQ mp_tostop             ; a lone zero: nothing buffered

                STA @l MOUSE_B          ; flags: buttons in bits 2:0

                LDA #$21                ; the packet continues at the same
                STA @l I2C_REG          ;  register; the controller is
                CALL I2C_GETREG         ;  counting the bytes, not us
                BCS mp_tostop
                STA @l MOUSE_D

                LDA #$21
                STA @l I2C_REG
                CALL I2C_GETREG
                BCS mp_tostop
                STA @l MOUSE_D+1

                setal                   ; X step, signed 8 bits
                LDA @l MOUSE_D
                AND #$00FF
                CMP #$0080
                BCC mp_xpos
                ORA #$FF00
mp_xpos         CLC
                ADC @l MOUSE_X
                STA @l MOUSE_X

                setal                   ; Y step, and the sign is flipped:
                LDA @l MOUSE_D+1        ;  the mouse counts up away from the
                AND #$00FF              ;  user, the screen counts down
                CMP #$0080
                BCC mp_ypos
                ORA #$FF00
mp_ypos         EOR #$FFFF
                INC A
                CLC
                ADC @l MOUSE_Y
                STA @l MOUSE_Y

                ; The fourth byte, when there is one: wheel movement,
                ; signed, and ACCUMULATED rather than stored -- a packet
                ; reports a step and MWHEEL reports the total since it was
                ; last asked.
                setas
                LDA @l MOUSE_PK
                CMP #4
                BNE mp_next

                LDA #$21
                STA @l I2C_REG
                CALL I2C_GETREG
                BCS mp_wstop
                STA @l MOUSE_D

                setal
                LDA @l MOUSE_D
                AND #$00FF
                CMP #$0080
                BCC mp_wpos
                ORA #$FF00
mp_wpos         CLC
                ADC @l MOUSE_WH
                STA @l MOUSE_WH

mp_next         setal                   ; reached 8 and 16 bits wide
                PLY
                INY
                JMP mp_packet           ; the loop is longer than a branch

mp_wstop        PLY
                BRA mp_done

mp_stop         PLY
mp_done         CALL MOUSE_CLAMP
                PLY
                PLX
                PLP
                RETURN
                .pend

;
; Keep the pointer on a 640x480 screen.
;
MOUSE_CLAMP     .proc
                PHP
                setal

                LDA @l MOUSE_X
                BPL mc_xtop
                LDA #0
                STA @l MOUSE_X
                BRA mc_y
mc_xtop         CMP #640
                BCC mc_y
                LDA #639
                STA @l MOUSE_X

mc_y            LDA @l MOUSE_Y
                BPL mc_ytop
                LDA #0
                STA @l MOUSE_Y
                BRA mc_done
mc_ytop         CMP #480
                BCC mc_done
                LDA #479
                STA @l MOUSE_Y

mc_done         PLP
                RETURN
                .pend

;
; MOUSE(n) -- 0 the X position, 1 the Y, 2 the buttons.
;
; One function with an argument rather than three without, because a
; function that takes no parentheses cannot be tokenized yet -- see the
; note beside CURSORX in tokens.s.
;
; Buttons are a bitmask: 1 left, 2 right, 4 middle.
;
; Every call polls first, so a program that reads X and then Y can see
; a packet arrive between the two. Reading MOUSE(2) first and then the
; coordinates costs one more poll and is no better; if that matters,
; the answer is MOUSEPOS, which reads all three from one poll.
;
FN_MOUSE        .proc
                FN_START "FN_MOUSE"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1
                AND #$00FF
                CMP #3
                BCS mo_bad
                STA @l MOUSE_N

                CALL MOUSE_POLL

                setal
                LDA @l MOUSE_N
                BEQ mo_x
                CMP #1
                BEQ mo_y

                setas                   ; buttons
                LDA @l MOUSE_B
                setal
                AND #$0007
                BRA mo_ret

mo_x            LDA @l MOUSE_X
                BRA mo_ret
mo_y            LDA @l MOUSE_Y

mo_ret          STA ARGUMENT1
                STZ ARGUMENT1+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN

mo_bad          PLP
                THROW ERR_ARGUMENT
                .pend

;
; MOUSEON n -- switch the mouse on (any non-zero) or off (0).
;
; MOUSEON and not "MOUSE on", which is what help/MOUSE.TXT asked for: a
; keyword is one token with one type, and MOUSE is already the FUNCTION
; MOUSE(n). The page's spelling is available by retiring MOUSE(n) in
; favour of MX/MY/MB below, which is a decision about breaking a shipped
; keyword rather than one about tokens, so it is left alone.
;
; "On" means asking the controller for device ID 3 -- an Intellimouse,
; which is the one that reports a wheel. The position is SuperBasic's, so
; switching on also zeroes it and the wheel accumulator.
;
S_MOUSEON       .proc
                PHP
                TRACE "S_MOUSEON"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE

                setas
                LDA #I2C_SMC
                STA @l I2C_DEV
                LDA #$20                ; "be this kind of device"
                STA @l I2C_REG

                LDA ARGUMENT1
                BEQ mn_off
                LDA #3                  ; wheel-capable
                BRA mn_set
mn_off          LDA #0                  ; a plain three-byte mouse
mn_set          STA @l I2C_V
                CALL I2C_SETREG

                setal                   ; the pointer is ours, so this is
                LDA #0                  ;  the only place it can be reset
                STA @l MOUSE_X
                STA @l MOUSE_Y
                STA @l MOUSE_WH
                setas
                STA @l MOUSE_B

                PLP
                RETURN
                .pend

;
; MX, MY, MB, MWHEEL -- the mouse without an index.
;
; What help/MOUSE.TXT always wanted and could not have: a function taking
; no parentheses could not be tokenized until TKPREVFN started asking a
; token's TYPE instead of comparing against a list of ids. MOUSE(n) stays
; because programs use it.
;
; Each polls, so reading MX and then MY can see a packet arrive between
; the two. That is the same trade MOUSE(n) documents, and the cure is the
; same: read MOUSE(0) and MOUSE(1) if it matters.
;
FN_MX           .proc
                TRACE "FN_MX"
                PHP
                setaxl
                CALL MOUSE_POLL
                LDA @l MOUSE_X
                STA ARGUMENT1
                STZ ARGUMENT1+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                PLP
                RETURN
                .pend

FN_MY           .proc
                TRACE "FN_MY"
                PHP
                setaxl
                CALL MOUSE_POLL
                LDA @l MOUSE_Y
                STA ARGUMENT1
                STZ ARGUMENT1+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                PLP
                RETURN
                .pend

FN_MB           .proc
                TRACE "FN_MB"
                PHP
                setaxl
                CALL MOUSE_POLL
                setas
                LDA @l MOUSE_B
                setal
                AND #$0007              ; left, right, middle
                STA ARGUMENT1
                STZ ARGUMENT1+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                PLP
                RETURN
                .pend

;
; MWHEEL -- wheel movement since the last read, signed.
;
; READING CLEARS IT. A wheel reports steps, not a position, so the only
; useful thing to hand back is the total since somebody last asked --
; which means two reads in a row give the second one nothing. Read it
; once a pass and keep the value.
;
; It stays 0 unless MOUSEON has asked for a wheel-capable device: a plain
; mouse serves three-byte packets with no wheel byte in them.
;
FN_MWHEEL       .proc
                TRACE "FN_MWHEEL"
                PHP
                setaxl
                CALL MOUSE_POLL

                LDA @l MOUSE_WH
                STA ARGUMENT1
                BPL mw_pos              ; sign-extend into the top half, so
                LDA #$FFFF              ;  a wheel rolled backwards is a
                STA ARGUMENT1+2         ;  negative number and not four
                BRA mw_clear            ;  billion
mw_pos          STZ ARGUMENT1+2

mw_clear        LDA #0
                STA @l MOUSE_WH

                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1
                PLP
                RETURN
                .pend

;
; MOUSEAT x, y -- put the pointer somewhere.
;
; There is nothing to tell the hardware: the position is SuperBasic's,
; because the controller only ever reports movement. This is how a
; program centres the pointer at the start of a game.
;
S_MOUSEAT       .proc
                PHP
                TRACE "S_MOUSEAT"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l MOUSE_X

                setas
                LDA #','
                CALL EXPECT_TOK
                setal
                CALL EVALEXPR
                CALL ASS_ARG1_INT
                LDA ARGUMENT1
                STA @l MOUSE_Y

                CALL MOUSE_CLAMP

                PLP
                RETURN
                .pend

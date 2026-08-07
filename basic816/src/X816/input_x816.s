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
; JOY(n) -- the buttons held on controller 0 to 3, one per bit, 1 held.
;
;   bit 0 A       bit 4 up      bit 8  B
;   bit 1 X       bit 5 down    bit 9  Y
;   bit 2 select  bit 6 left    bit 10 left shoulder
;   bit 3 start   bit 7 right   bit 11 right shoulder
;
; The shift register is SNES-shaped: pulse the latch to snapshot every
; controller at once, then read one bit and clock for the next, sixteen
; times. All four controllers shift in parallel on their own data lines,
; which is why the port is read and then masked rather than selected.
;
; The wire is active low and the top four bits are tied high, so the
; whole word is inverted on the way out and an absent controller reads
; as 0 -- no buttons -- rather than as every button at once.
;
FN_JOY          .proc
                FN_START "FN_JOY"
                PHP
                setaxl                  ; BEFORE the pushes: the pops below are
                                        ;  16-bit, so the pushes must be too
                PHX
                PHY

                CALL EVALEXPR
                CALL ASS_ARG1_BYTE
                LDA ARGUMENT1           ; controller n is on bit 7-n, and LDX
                AND #$0003              ;  has no long addressing mode, so the
                TAY                     ;  bit is turned into a mask once here
                setas                   ;  instead of shifted on every pass
                LDA #$80
joy_mask        CPY #0
                BEQ joy_ready
                LSR A
                DEY
                BRA joy_mask
joy_ready       STA @l JOY_MASK

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

                setal
                LDA #0
                STA @l JOY_W
                LDY #0

joy_bit         setas
                LDA @l VIA1_PA
                AND @l JOY_MASK
                CMP #1                  ; nonzero sets the carry: not held

                setal                   ; REP does not touch the carry, so
                LDA @l JOY_W            ;  the bit survives the width change.
                ROR A                   ; bits arrive least significant first;
                STA @l JOY_W            ;  sixteen of these put the first one
                                        ;  back at bit 0
                setas                   ; clock low, then high: next bit
                LDA #0
                STA @l VIA1_PA
                LDA #JOY_CLK
                STA @l VIA1_PA

                setal
                INY
                CPY #16
                BCC joy_bit

                setas                   ; release the two lines we drove
                LDA @l VIA1_DDRA
                AND #$FF-JOY_LATCH-JOY_CLK
                STA @l VIA1_DDRA

                setal
                LDA @l JOY_W            ; active low on the wire, and the top
                EOR #$FFFF              ;  nibble is tied high, so this turns
                AND #$0FFF              ;  "not held" into 0 and drops the
                STA ARGUMENT1           ;  four bits that are never buttons
                STZ ARGUMENT1+2
                setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                PLY
                PLX
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

                LDY #0                  ; a bounded number of packets, so a
mp_packet       CPY #16                 ;  controller that always has one
                BCS mp_done             ;  cannot wedge the interpreter
                PHY

                setas
                LDA #I2C_SMC
                STA @l I2C_DEV
                LDA #$21
                STA @l I2C_REG
                CALL I2C_GETREG
                BCS mp_stop
                CMP #0
                BEQ mp_stop             ; a lone zero: nothing buffered

                STA @l MOUSE_B          ; flags: buttons in bits 2:0

                LDA #$21                ; the packet continues at the same
                STA @l I2C_REG          ;  register; the controller is
                CALL I2C_GETREG         ;  counting the bytes, not us
                BCS mp_stop
                STA @l MOUSE_D

                LDA #$21
                STA @l I2C_REG
                CALL I2C_GETREG
                BCS mp_stop
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

                PLY
                INY
                BRA mp_packet

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

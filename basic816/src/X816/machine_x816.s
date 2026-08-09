
;;;
;;; The machine itself: REBOOT, RESET, POWEROFF, ALLOC and FREE
;;;
;;; Copyright (C) 2026 Jean-Yves Vinet
;;; Dual-licensed: GPLv3 (as part of SuperBasic) and MIT.
;;;
;;; The first three are one I2C write each, to the system controller at
;;; $42 -- the same device MOUSEON configures and I2CPEEK reads. Its
;;; command set is a register and a value:
;;;
;;;     $01 $00     power off
;;;     $01 $01     hard reboot
;;;     $02 $00     the reset button
;;;     $03 $00     the NMI button
;;;
;;; They are keywords rather than three I2CPOKEs on the help page
;;; because a beginner should not have to know a device address to turn
;;; the machine off, and because getting the second byte wrong turns a
;;; reboot into a power cut.
;;;
;;; NONE OF THE THREE RETURNS. There is no error path to write: the
;;; write either reaches the SMC, in which case the machine is already
;;; going, or it does not, in which case the statement quietly did
;;; nothing and the next one runs. A device that is not there NACKs and
;;; I2C_SETREG has no answer to give -- the same rule I2CPOKE states.
;;;
;;; ALLOC AND FREE are the kernel's allocator, and the shape of it
;;; matters more than the call: the arena is 13.6 MB and the table holds
;;; 32 LIVE BLOCKS. So the pattern is one big block sub-allocated by
;;; hand, not a thousand small ones -- a program that allocates in a
;;; loop runs out of BLOCKS with megabytes free, and the error it gets
;;; says nothing about that. help/MEMORY.TXT says so.
;;;

;
; Send one command to the system controller.
;
; Inputs:
;   A (8-bit) = the register, X (8-bit) = the value
;
MCH_SMC         .proc
                PHP
                setas
                STA @l I2C_REG
                TXA
                STA @l I2C_V
                LDA #I2C_SMC
                STA @l I2C_DEV
                CALL I2C_SETREG
                PLP
                RETURN
                .pend

;
; POWEROFF -- $01 $00.
;
S_POWEROFF      .proc
                PHP
                TRACE "S_POWEROFF"
                setas
                setxs
                LDX #$00
                LDA #$01
                CALL MCH_SMC
                PLP
                RETURN
                .pend

;
; REBOOT -- $01 $01, the SMC's hard reboot. Power to the board is cycled,
; so this is a colder start than RESET and the closest thing here to
; switching it off and on again.
;
S_REBOOT        .proc
                PHP
                TRACE "S_REBOOT"
                setas
                setxs
                LDX #$01
                LDA #$01
                CALL MCH_SMC
                PLP
                RETURN
                .pend

;
; RESET -- $02 $00, the reset button. The same one Ctrl+Alt+Del raises,
; which is why it is a separate keyword from REBOOT rather than a
; spelling of it: the CPU restarts and the board does not.
;
S_RESET         .proc
                PHP
                TRACE "S_RESET"
                setas
                setxs
                LDX #$00
                LDA #$02
                CALL MCH_SMC
                PLP
                RETURN
                .pend

;
; ALLOC(size) -- a block out of the kernel's arena, or -1.
;
; -1 AND NOT AN ERROR. Running out of memory is a thing a program can
; reasonably plan for -- fall back to a smaller level, a shorter sample
; -- and a thrown error gives it nowhere to put that plan. It is the
; same answer I2CPEEK gives for a device that is not there.
;
FN_ALLOC        .proc
                FN_START "FN_ALLOC"
                PHP
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT

                setaxl
                LDA ARGUMENT1+2             ; C = size low, X = size high
                TAX
                LDA ARGUMENT1
                JSL KERN_MEM_ALLOC
                BCS al_none

                STA ARGUMENT1               ; C:X = the 24-bit address
                TXA
                AND #$00FF
                STA ARGUMENT1+2
                BRA al_type

al_none         LDA #$FFFF
                STA ARGUMENT1
                STA ARGUMENT1+2

al_type         setas
                LDA #TYPE_INTEGER
                STA ARGTYPE1

                FN_END
                PLP
                RETURN
                .pend

;
; FREE addr -- give one back.
;
; An address the allocator never handed out is the kernel's business to
; refuse, and it does; there is nothing this layer could add by checking
; first that would not be a second, worse copy of its table.
;
S_FREE          .proc
                PHP
                TRACE "S_FREE"
                setaxl

                CALL EVALEXPR
                CALL ASS_ARG1_INT

                setaxl
                LDA ARGUMENT1+2             ; C:X = the address
                TAX
                LDA ARGUMENT1
                JSL KERN_MEM_FREE

                PLP
                RETURN
                .pend

@echo off
REM ===========================================================================
REM  run-basic.bat -- build SuperBasic and boot it in X816_Emulator, then hand
REM  the keyboard to you. Double-click it, or run it from cmd.
REM
REM  This is the interactive counterpart to run-emu.sh / run-tests.sh, which
REM  drive the SAME emulator headless (dummy video, -warp, -autokeys, and a
REM  decoded GIF for a pass/fail verdict). That is what a test needs and
REM  exactly what you do not want when you just wish to type at the REPL.
REM
REM      run-basic.bat                boot to the SuperBasic prompt
REM      run-basic.bat -warp          ... any extra args go to the emulator
REM      run-basic.bat /buildonly     build and write the card, do not launch
REM
REM  The sibling X816 projects are located relative to this file, so a moved
REM  checkout moves once (same rule as runtime/calypsi.sh).
REM
REM  Needs: python with pyfatfs (pip install pyfatfs), and a built
REM  X816_Calypsi\examples\shell\kernel.bin (sh build.sh there).
REM ===========================================================================
setlocal EnableExtensions

set "PROJ=%~dp0"
if "%PROJ:~-1%"=="\" set "PROJ=%PROJ:~0,-1%"
for %%I in ("%PROJ%\..") do set "SIBLINGS=%%~fI"

set "EMUEXE=%SIBLINGS%\X816_Emulator\build\x16emu.exe"
set "BOOTROM=%SIBLINGS%\X816_core\boot\boot.rom"
set "FATIMG=%SIBLINGS%\X816_core\boot\fat32.img"
set "KERNEL=%SIBLINGS%\X816_Calypsi\examples\shell\kernel.bin"
set "TASS=%PROJ%\64tass\64tass.exe"
set "CARD=%PROJ%\build\card.img"
set "BIN=%PROJ%\build\basic.bin"

set "BUILDONLY="
if /I "%~1"=="/buildonly" (
    set "BUILDONLY=1"
    shift
)

for %%F in ("%EMUEXE%" "%BOOTROM%" "%FATIMG%" "%TASS%") do (
    if not exist "%%~F" (
        echo [X] missing: %%~F
        goto :fail
    )
)
if not exist "%KERNEL%" (
    echo [X] missing: %KERNEL%
    echo     Build it first:  sh build.sh   in X816_Calypsi\examples\shell
    goto :fail
)

if not exist "%PROJ%\build" mkdir "%PROJ%\build"

echo [1/3] assembling SuperBasic ...
"%TASS%" -D SYSTEM=3 -D UNITTEST=0 -D TRACE_LEVEL=0 -D UARTSUPPORT=0 ^
    --long-address --flat -b --m65816 ^
    -o "%BIN%" --list="%PROJ%\build\basic.lst" --labels="%PROJ%\build\basic.lbl" ^
    -I "%PROJ%\basic816\src" "%PROJ%\basic816\src\basic816.s" >"%PROJ%\build\build.log" 2>&1
if errorlevel 1 (
    echo [X] assembly failed -- see build\build.log
    goto :fail
)
if not exist "%BIN%" (
    echo [X] assembly produced no binary -- see build\build.log
    goto :fail
)
for %%S in ("%BIN%") do echo       basic.bin = %%~zS bytes

REM The card persists in build\ rather than a temp dir, so whatever you SAVE
REM survives to the next run once phase 3 binds K_FS_*.
if not exist "%CARD%" (
    echo [2/3] creating card from fat32.img ...
    copy /Y "%FATIMG%" "%CARD%" >nul
    if errorlevel 1 (
        echo [X] could not create the card image
        goto :fail
    )
) else (
    echo [2/3] reusing existing card build\card.img
)

python "%PROJ%\tools\putfile.py" "%CARD%" "%BIN%" "/BASIC.BIN"
if errorlevel 1 (
    echo [X] could not write BASIC.BIN onto the card
    echo     If the card is corrupt, delete build\card.img and run again
    echo     to rebuild it from fat32.img.
    goto :fail
)

if defined BUILDONLY (
    echo [3/3] /buildonly -- not launching the emulator
    goto :done
)

echo [3/3] booting X816_Emulator ...
echo.
echo   The shell is sent "run BASIC.BIN" for you; everything after is yours.
echo   Worth trying (PORT.md section 11 lists what is still missing):
echo.
echo       PRINT 10/4             software float divide       -^> 2.50000
echo       PRINT 2^^10             integer power               -^> 1.02400E03
echo       A%%=-20.0 : PRINT A%%    FTOI sign fix               -^> -20
echo       10 PRINT 1.5           then RUN, float from program -^> 1.50000
echo       PRINT SIN(1)           transcendentals still THROW
echo.
echo   ESC after BASIC exits reloads the shell; close the window to stop.
echo.

"%EMUEXE%" -boot "%BOOTROM%" -load "F00000,%KERNEL%" -sdcard "%CARD%" ^
    -autokeys "run BASIC.BIN\n" %*

:done
endlocal
REM Keep the window up when double-clicked so the output stays readable.
echo.
pause
exit /b 0

:fail
endlocal
echo.
pause
exit /b 1

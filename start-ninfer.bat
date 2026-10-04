@echo off
REM ============================================================
REM  start-ninfer.bat -- ONE double-click to bring the local AI up.
REM
REM  [ADDED BY THE DEPLOYING AGENT 2026-10-04. Not part of the shipped
REM   pack, changes nothing in it: this file only CALLS two launchers
REM   that live in this same folder.]
REM
REM  WHAT IT DOES, in order:
REM    1) something already listening on 8095?  -> say so and stop.
REM       One 8 GB card runs exactly ONE engine instance (a second one
REM       "loads" through WDDM over-commit and then dies).
REM    2) otherwise try start-ptq1-mtp-igpu.bat, --kv-capacity 15360. That is
REM       the best pool this card allows once the PANEL IS ON THE iGPU
REM       (BIOS hybrid / discrete-direct off): measured 2026-10-04, that mode
REM       gives 1,003,487,232 B (957 MiB) of runtime reservation and a 15,360
REM       pool needs 940,457,728 B (896.8 MiB), 60 MiB spare. With the dGPU
REM       driving the panel only ~740 MB were available, which is why the
REM       8,192 profile could not start at all (4.1-4.6 MiB short, twice).
REM    3) if that returns, retry the same launcher with POOL=12288 (856.5 MiB),
REM       which still fits if about 100 MB of that budget went away.
REM    4) then the old small-pool profiles: start-ptq1-mtp-8gb-pool7168.bat,
REM       and last resort start-ptq1-mtp-8gb-tight.bat (which fits almost
REM       always but sets --device-state-slots 0 and can answer
REM       HTTP 500 "published MTP checkpoint is not materializable").
REM       A fallback pool is SMALLER than the contextWindow declared in
REM       cordis.patch.yml (15360), so lower that line if you have to live
REM       on one of them.
REM
REM  WHY THE FALLBACK EXISTS -- measured on this machine 2026-10-04:
REM    desktop compositor + ZCode + Edge WebView2 holding ~1 GB:
REM      FATAL server failed during startup | requested Engine runtime
REM      reservation requires 744513280 bytes, but only 630804480
REM      bytes are available for runtime capacity
REM    The tight profile adds --device-state-slots 0 and does fit, BUT
REM    that same flag is what makes the engine answer
REM      HTTP 500 published MTP checkpoint is not materializable
REM    on some multi-turn requests. So the "already running" message
REM    below tells you which profile you ended up with: if you see the
REM    fallback warning, close browser/ZCode windows and run this file
REM    again -- the first profile is the good one.
REM
REM  TO STOP THE ENGINE: close the console window that printed
REM    "engine ready" (or: taskkill /IM ninfer-serve-120a.exe /F).
REM    Closing THIS window after the engine is up also stops it,
REM    because this window IS the engine's console.
REM
REM  ASCII-only on purpose: cmd parses a .bat in the OEM/ANSI codepage.
REM ============================================================
setlocal
set "ROOT=%~dp0"

set "RUNNING="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr ":8095 " ^| findstr "LISTENING"') do if not defined RUNNING set "RUNNING=%%P"
if defined RUNNING (
  echo.
  echo [ALREADY RUNNING] the local AI is already up on port 8095 ^(pid %RUNNING%^).
  echo   Nothing to start. In DeepSeek Harness pick:  qwen / qwen3.8-27b
  echo   To stop it, close the window that printed "engine ready".
  echo.
  pause
  exit /b 0
)

echo.
echo [1/4] trying the iGPU-desktop profile: --kv-capacity 15360 ...
echo.
call "%ROOT%start-ptq1-mtp-igpu.bat" < NUL

echo.
echo [2/4] 15360 did NOT stay up -- retrying the same profile with POOL=12288
echo       ^(856.5 MiB: still fits if about 100 MB of the budget went away^).
echo.
set "POOL=12288"
call "%ROOT%start-ptq1-mtp-igpu.bat" < NUL
set "POOL="

echo.
echo [3/4] that did not fit either -- falling back to the SMALL-pool profile.
echo       ^(the engine's pool is now BELOW the contextWindow declared in
echo        cordis.patch.yml, so expect much less usable history, and lower
echo        that line if you have to stay here^)
echo.
call "%ROOT%start-ptq1-mtp-8gb-pool7168.bat" < NUL

echo.
echo [4/4] last resort: the TIGHT profile.
echo       ^(if DeepSeek Harness then reports "published MTP checkpoint is not
echo        materializable", free GPU memory and run this file again^)
echo.
call "%ROOT%start-ptq1-mtp-8gb-tight.bat"

echo.
echo [engine exited] errorlevel=%ERRORLEVEL%
pause
@echo off
setlocal
REM ============================================================
REM  NInfer panel - double-click this file.
REM
REM  It serves the dashboard on http://127.0.0.1:8098/ and can
REM  start / stop / restart the engine from that page.
REM
REM  ASCII ONLY. cmd.exe parses .bat files in the OEM codepage,
REM  so a single non-ASCII byte here can make cmd execute nothing
REM  at all, silently. Check with:
REM    powershell -NoProfile -Command "$b=[IO.File]::ReadAllBytes('panel.bat');($b|?{$_-gt127}).Count"
REM
REM  Optional overrides before running:
REM    set NINFER_PY=C:\path\python.exe
REM    set NINFER_POOL=12288
REM ============================================================

set "ROOT=%~dp0"
set "PANEL_PORT=8093"
set "ENGINE_PORT=8095"
set "PAGE_PORT=8097"
set "POOL=15360"
if defined NINFER_POOL set "POOL=%NINFER_POOL%"

REM ---- locate a python interpreter -------------------------------------
set "PY="
if defined NINFER_PY set "PY=%NINFER_PY%"
if not defined PY if exist "%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe" set "PY=%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if not defined PY for %%P in (python.exe) do if not defined PY set "PY=%%~$PATH:P"
if not defined PY for %%P in (py.exe) do if not defined PY set "PY=%%~$PATH:P"
if not defined PY (
  echo [panel] python interpreter not found.
  echo [panel] set NINFER_PY=C:\path\to\python.exe and run this file again.
  pause
  exit /b 3
)

if not exist "%ROOT%panel.py" (
  echo [panel] panel.py not found next to this file.
  pause
  exit /b 4
)

REM ---- only one panel at a time ----------------------------------------
set "HAS="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr ":%PANEL_PORT% " ^| findstr "LISTENING"') do if not defined HAS set "HAS=%%P"
if defined HAS (
  echo [panel] a panel is already running on port %PANEL_PORT% ^(pid %HAS%^).
  echo [panel] opening the browser instead.
  start "" "http://127.0.0.1:%PANEL_PORT%/"
  timeout /t 2 >nul
  exit /b 0
)

echo ============================================================
echo  NInfer panel : http://127.0.0.1:%PANEL_PORT%/
echo  engine       : 127.0.0.1:%ENGINE_PORT%   target pool %POOL%
echo  chat page    : 127.0.0.1:%PAGE_PORT%
echo  python       : %PY%
echo ============================================================
echo  Leave this window open while you use the panel.
echo  Closing it stops the panel; an engine the panel started
echo  keeps running, and a new panel re-attaches to it.
echo.

start "" /min powershell -NoProfile -WindowStyle Hidden -Command "Start-Sleep -Seconds 2; Start-Process 'http://127.0.0.1:%PANEL_PORT%/'"
"%PY%" "%ROOT%panel.py" --port %PANEL_PORT% --engine-port %ENGINE_PORT% --page-port %PAGE_PORT% --pool %POOL% --root "%ROOT%." --python "%PY%"

echo.
echo [panel] server exited.
pause
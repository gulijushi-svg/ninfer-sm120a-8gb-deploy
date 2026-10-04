@echo off
setlocal
REM ============================================================
REM  NInfer control panel AS A DESKTOP APP
REM
REM  Double-click this file and the panel opens in its own
REM  app window (Edge/Chrome --app mode): no address bar, no
REM  tabs, its own taskbar entry and icon.
REM
REM  It also makes sure the panel server is running first, so a
REM  desktop shortcut to this file behaves like an application:
REM  one click = panel window ready to start the engine.
REM
REM  ASCII ONLY (cmd reads .bat in the OEM codepage).
REM
REM  Optional overrides:
REM    set NINFER_PY=C:\path\python.exe
REM    set NINFER_POOL=12288
REM    set NINFER_WIN=1200,800
REM ============================================================

set "ROOT=%~dp0"
set "PANEL_PORT=8093"
set "ENGINE_PORT=8095"
set "PAGE_PORT=8097"
set "POOL=15360"
set "WIN=1480,980"
if defined NINFER_POOL set "POOL=%NINFER_POOL%"
if defined NINFER_WIN set "WIN=%NINFER_WIN%"

REM ---- locate python -----------------------------------------------------
set "PY="
if defined NINFER_PY set "PY=%NINFER_PY%"
if not defined PY if exist "%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe" set "PY=%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if not defined PY for %%P in (python.exe) do if not defined PY set "PY=%%~$PATH:P"
if not defined PY for %%P in (py.exe) do if not defined PY set "PY=%%~$PATH:P"
if not defined PY (
  echo [app] python interpreter not found.
  echo [app] set NINFER_PY=C:\path\to\python.exe and run this file again.
  pause
  exit /b 3
)
if not exist "%ROOT%panel.py" (
  echo [app] panel.py not found next to this file.
  pause
  exit /b 4
)

REM ---- 1) make sure the panel server is up -------------------------------
set "HAS="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr ":%PANEL_PORT% " ^| findstr "LISTENING"') do if not defined HAS set "HAS=%%P"
if defined HAS (
  echo [app] panel server already running on port %PANEL_PORT% ^(pid %HAS%^).
  echo [app] note: if that panel was started for you by a helper session,
  echo [app]       end its python.exe in Task Manager and run this file again
  echo [app]       to get your own instance.
) else (
  echo [app] starting the panel server on port %PANEL_PORT% ...
  start "NInfer panel server" /min "%PY%" "%ROOT%panel.py" --port %PANEL_PORT% --engine-port %ENGINE_PORT% --page-port %PAGE_PORT% --pool %POOL% --root "%ROOT%." --python "%PY%" --autostart-engine
  echo [app] waiting for it to answer ...
  timeout /t 3 /nobreak >nul
)

REM ---- 2) find a Chromium browser for app mode ---------------------------
set "PF86=%ProgramFiles(x86)%"
set "EDGE="
for %%P in ("%PF86%\Microsoft\Edge\Application\msedge.exe" "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" "%LOCALAPPDATA%\Microsoft\Edge\Application\msedge.exe") do if not defined EDGE if exist %%P set "EDGE=%%~P"
set "CHROME="
for %%P in ("%PF86%\Google\Chrome\Application\chrome.exe" "%ProgramFiles%\Google\Chrome\Application\chrome.exe" "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe") do if not defined CHROME if exist %%P set "CHROME=%%~P"

REM ---- 3) open the app window -------------------------------------------
if defined EDGE (
  echo [app] opening the app window with Edge.
  start "" "%EDGE%" --app="http://127.0.0.1:%PANEL_PORT%/" --window-size=%WIN%
  exit /b 0
)
if defined CHROME (
  echo [app] opening the app window with Chrome.
  start "" "%CHROME%" --app="http://127.0.0.1:%PANEL_PORT%/" --window-size=%WIN%
  exit /b 0
)
echo [app] Edge/Chrome not found - opening the default browser instead.
start "" "http://127.0.0.1:%PANEL_PORT%/"
exit /b 0
@echo off
REM ============================================================
REM  chat-web-ninfer.bat -- chat-web.bat, but the engine step is
REM  start-ninfer.bat (tries the validated 8 GB profile, falls back
REM  to the tight one if the desktop is holding VRAM).
REM
REM  [ADDED BY THE DEPLOYING AGENT 2026-10-04. Not part of the shipped
REM   pack. chat-web.bat and chat-web-tight.bat are untouched.]
REM
REM  WHEN TO USE: you want the browser chat page at
REM  http://127.0.0.1:8097/ as well as / instead of the DSH model.
REM  If you only use the local model inside DeepSeek Harness, use
REM  start-ninfer.bat alone -- the page is not needed for that.
REM
REM  Two windows, two meanings:
REM    this window (the engine)  closing it STOPS THE ENGINE
REM    "NInfer chat page 8097"   closing it only breaks the web page
REM
REM  ASCII-only on purpose: cmd parses a .bat in the OEM/ANSI codepage.
REM ============================================================
chcp 65001 >NUL
setlocal EnableExtensions
set "ROOT=%~dp0"

REM ---- python: NINFER_PY wins, then the runtime DSH ships, then PATH ----
set "PY=%NINFER_PY%"
if not defined PY set "PY=%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
set "HAVE_PY="
if exist "%PY%" set "HAVE_PY=1"
if not defined HAVE_PY (
  where python >NUL 2>NUL && set "HAVE_PY=1" && set "PY=python"
)
if not defined HAVE_PY (
  echo [ERROR] no python found. Set NINFER_PY to a python.exe and run this again.
  pause
  exit /b 3
)

REM ---- 1) chat page on 8097, in its own minimized window ----
set "ENG=%NINFER_ENGINE%"
if not defined ENG set "ENG=127.0.0.1:8095"
set "KEYARG="
if defined NINFER_API_KEY set "KEYARG=--api-key %NINFER_API_KEY%"
set "PAGE="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr ":8097 " ^| findstr "LISTENING"') do if not defined PAGE set "PAGE=%%P"
if defined PAGE (
  echo [1/3] chat page already running on 8097 ^(pid %PAGE%^).
) else (
  echo [1/3] starting the chat page on 8097, engine %ENG% ...
  start "NInfer chat page 8097 - closing this window only breaks the page" /min "%PY%" "%ROOT%ninfer-chat.py" --port 8097 --engine %ENG% %KEYARG% --model qwen3.8-27b
)

REM ---- 2) open the browser once the engine has had time to load ----
echo [2/3] the browser will open http://127.0.0.1:8097/ in about 18 s ...
start "" /min powershell -NoProfile -WindowStyle Hidden -Command "Start-Sleep -Seconds 18; Start-Process 'http://127.0.0.1:8097/'"

REM ---- 3) the engine, in THIS window (validated profile, tight fallback) ----
echo [3/3] starting the engine below. Leave this window open while you chat.
echo.
echo ============================================================
echo  chat page : http://127.0.0.1:8097/
echo  engine    : http://127.0.0.1:8095/v1   ^(API only, no page^)
echo ============================================================
echo.

call "%ROOT%start-ninfer.bat"

echo.
echo [chat-web-ninfer] the engine has exited - closing this window.
pause
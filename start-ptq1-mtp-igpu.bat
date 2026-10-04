@echo off
REM ============================================================
REM  start-ptq1-mtp-igpu.bat -- big-pool profile for the mode where the iGPU
REM  drives the panel (BIOS hybrid, or "discrete GPU direct" switched OFF),
REM  which frees the dGPU's desktop reservation.
REM
REM  [ADDED BY THE DEPLOYING AGENT 2026-10-04. Not part of the shipped pack.
REM   The shipped launchers are left byte-for-byte untouched.]
REM
REM  Same argv as start-ptq1-mtp-8gb.bat except the pool, and the pool is
REM  overridable from the environment:
REM      set POOL=16384 && start-ptq1-mtp-igpu.bat
REM  The default below is a value MEASURED to fit on 2026-10-04 in this mode.
REM  Change it only to a value you have measured.
REM
REM  THE MEASUREMENT (this machine, the engine's own reservation numbers):
REM    dGPU drove the panel : display_active=Enabled, ~580 MiB used ->
REM                           pool 8192 needed 744,513,280 B while only
REM                           739-740 MB were available: 4.1-4.6 MiB SHORT,
REM                           twice in a row, so 8192 could not start at all.
REM    iGPU drives the panel: display_active=Disabled, ~380 MiB used ->
REM                           available for runtime capacity = 1,003,487,232 B
REM                           (= 957.0 MiB, about 217 MB more than before).
REM
REM  THE FORMULA (CUDA Graph already excluded by --no-cuda-graph):
REM      reservation = 520,576,768 B + 27,336 B x POOL
REM      POOL  8192 ->   744,513,280 B =  710.0 MiB   fits only in iGPU mode
REM      POOL 15360 ->   940,457,728 B =  896.8 MiB   <- default, 60 MiB spare
REM      POOL 16384 ->   968,449,792 B =  923.6 MiB   fits, 35 MiB spare
REM      POOL 20480 -> 1,080,418,048 B = 1030.4 MiB   MEASURED NOT TO FIT
REM  So the ceiling in iGPU mode is about pool 17,600, and it moves with
REM  whatever else holds the dGPU.
REM
REM  WHY NOT KEEP THE SMALL POOL: DeepSeek Harness re-sends its whole system
REM  prompt + 31 tool schemas + the session history every turn (measured:
REM  2,163 tokens of fixed overhead, and one real session was 9,519 tokens).
REM  It computes the output budget as contextWindow - prompt, clamped at 1,
REM  so against a 7,168 pool that session got exactly ONE output token: the
REM  answer was cut to its first token and the UI showed the "output token
REM  limit reached" warning. Keep cordis.patch.yml's contextWindow equal to
REM  the pool this file launches, or you re-create that failure.
REM
REM  --device-state-slots is deliberately NOT set here: its default (1) is
REM  what lets the engine publish and materialize the MTP checkpoint. Setting
REM  it to 0 was measured to answer HTTP 500 "published MTP checkpoint is not
REM  materializable" on multi-turn chats.
REM
REM  Closing this console window stops the engine.
REM
REM  ASCII-ONLY ON PURPOSE: cmd parses a .bat in the OEM/ANSI codepage. An
REM  earlier version of this launcher carried a stray non-ASCII byte and cmd
REM  then executed NOTHING at all, silently, even with output redirected to a
REM  file. Check any edit with:
REM    powershell -c "$b=[IO.File]::ReadAllBytes('file.bat');($b|?{$_ -gt 127}).Count"
REM  It must print 0.
REM ============================================================
setlocal
if not defined POOL set "POOL=15360"
set "ROOT=%~dp0"
if not defined MODEL set "MODEL=%ROOT%models\bonsai2_27b_ternary_ptq1_native_mtp.ninfer"
if not exist "%MODEL%" (
  echo REFUSE: model not found: "%MODEL%"
  echo         Put it in %ROOT%models\ or run:  set MODEL=D:\path\to\bonsai2_27b_ternary_ptq1_native_mtp.ninfer  ^&^& start-ptq1-mtp-igpu.bat
  pause
  exit /b 3
)
set "CUDA_BIN=%ROOT%engine"
set "PATH=%CUDA_BIN%;%CUDA_BIN%\x64;%PATH%"
set "NINFER_KV_WINDOW=16384"
set "NINFER_KV_RETRIEVE=8192"
set "NINFER_KV_RING=1"
set "NINFER_HOST_PAGEABLE=1"
set "NINFER_KV_REUSE_HOSTBACKED=1"
set "NINFER_TERNARY_PTQ1_FAST=1"

REM one card runs exactly ONE instance (a second one "loads" through WDDM
REM over-commit and then dies in the D3D12 arena)
set "RUNNING="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr ":8095 " ^| findstr "LISTENING"') do if not defined RUNNING set "RUNNING=%%P"
if defined RUNNING (
  echo [ALREADY RUNNING] service already on port 8095 ^(pid %RUNNING%^).
  echo   ONE card runs one instance -- a second start would crash.
  echo   Stop that instance first - close its console window - then run this again.
  pause
  exit /b 4
)

if not exist "%ROOT%engine\ninfer-serve-120a.exe" (
  echo REFUSE: engine\ninfer-serve-120a.exe is missing from this pack
  pause
  exit /b 4
)
set "ENGINE=%ROOT%engine\ninfer-serve-120a.exe"

echo [engine] %ENGINE%
echo [model ] %MODEL%
echo [sized ] iGPU-desktop profile: --kv-capacity %POOL%, --no-cuda-graph
echo.

"%ENGINE%" "%MODEL%" ^
  --host 127.0.0.1 --port 8095 --model-id qwen3.8-27b ^
  --max-context 262144 --kv-capacity %POOL% --kv-dtype k8v4 --host-kv-mib 16384 ^
  --spec mtp --draft-tokens 4 --no-cuda-graph ^
  --default-max-tokens 4096 --default-reasoning-effort none ^
  --max-shared-prefixes 0 ^
  --presence-penalty 0 --temperature 0.7 --top-p 0.9 --top-k 20

echo.
echo [engine exited] errorlevel=%ERRORLEVEL%
pause
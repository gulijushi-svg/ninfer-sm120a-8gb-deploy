@echo off
REM ============================================================
REM  start-ptq1-mtp-8gb-tight.bat -- 8 GB profile for a desktop
REM  that is holding VRAM (the shipped 8 GB profile refuses).
REM
REM  [ADDED BY THE DEPLOYING AGENT 2026-10-04. NOT part of the
REM   shipped pack and NOT listed in SHA256SUMS.txt. Neither
REM   start-ptq1-mtp.bat nor start-ptq1-mtp-8gb.bat is modified.]
REM
REM  ONE DELTA vs start-ptq1-mtp-8gb.bat, everything else identical:
REM    + --device-state-slots 0
REM
REM  WHY. After loading the 5.94 GiB of weights the engine checks:
REM      reservation = 520,576,768 B + 27,336 B x --kv-capacity
REM  At --kv-capacity 8192 that is 744,513,280 B. On this RTX 5060
REM  (8151 MiB, driver 616.64) with the desktop compositor holding
REM  ~650 MB and the other usual apps ~270 MB, only 615,026,688 to
REM  689,889,280 B were available, so start-ptq1-mtp-8gb.bat ended in
REM      FATAL server failed during startup | requested Engine
REM      runtime reservation requires 744513280 bytes ...
REM  Freeing ZCode + Edge WebView2 (168 MB) was NOT enough, and both
REM  are restarted by their own watchdogs, so the win does not stick.
REM
REM  --device-state-slots 0 keeps the prefix-cache checkpoint states in
REM  the pinned 16 GiB host pool instead of one extra set on the device
REM  (the startup line then reads "1 active + 0 cached device states |
REM  host 8 states"). It is the engine-native knob that lowers this
REM  reservation without touching model precision or the KV pool.
REM
REM  MEASURED HERE 2026-10-04, this argv, counting corpus
REM  1,000 tokens in / 1,000 tokens out (temperature 0):
REM    engine ready | bonsai2-27b | total 4.2s | weights 5.94 GiB
REM    capacity | KV 8,192 tokens, k8v4, explicit | pages 128/4,096
REM             | runtime 563.2 MiB | free 253.8 MiB
REM    req#1 done | prompt 1,133 | output 1,000 | TTFT 2.0s
REM             | total 15.6s | prefill 584.1 tok/s | decode 73.5 tok/s
REM             | mtp accepted 780/875 (89.1%)
REM    answer = 301 302 303 ... (continues correctly)
REM  For comparison, the shipped 8 GB profile on the same card:
REM  runtime 710.0 MiB | free 218.5 MiB | decode 60.3 tok/s.
REM
REM  Everything else (pool 8192, --no-cuda-graph, max_tokens 4096, the
REM  port guard, KVMem env) is byte-for-byte the 8 GB profile.
REM
REM  HOW TO USE: double-click this, wait for "engine ready" and
REM  "capacity |", then open the chat page at http://127.0.0.1:8097/
REM  (chat-web-tight.bat serves that page and starts this engine).
REM  Closing this console window stops the engine.
REM  ONE instance per 8 GB card -- start this OR chat-web-tight.bat.
REM
REM  ASCII-only on purpose: cmd parses a .bat in the OEM/ANSI codepage.
REM ============================================================
setlocal
set "ROOT=%~dp0"
if not defined MODEL set "MODEL=%ROOT%models\bonsai2_27b_ternary_ptq1_native_mtp.ninfer"
if not exist "%MODEL%" (
  echo REFUSE: model not found: "%MODEL%"
  echo         Put it in %ROOT%models\ or run:  set MODEL=D:\path\to\bonsai2_27b_ternary_ptq1_native_mtp.ninfer  ^&^& start-ptq1-mtp-8gb-tight.bat
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

REM one 8 GB card runs exactly ONE instance (measured 2026-10-01: a second one
REM "loads" via WDDM over-commit and then dies in the D3D12 arena)
set "RUNNING="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr ":8095 " ^| findstr "LISTENING"') do if not defined RUNNING set "RUNNING=%%P"
if defined RUNNING (
  echo [ALREADY RUNNING] service already on port 8095 ^(pid %RUNNING%^).
  echo   One 8 GB card runs one instance -- a second start would crash.
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
echo [sized ] 8 GB tight profile: --kv-capacity 8192, --no-cuda-graph, --device-state-slots 0 (see the header for the numbers)
echo.

"%ENGINE%" "%MODEL%" ^
  --host 127.0.0.1 --port 8095 --model-id qwen3.8-27b ^
  --max-context 262144 --kv-capacity 8192 --kv-dtype k8v4 --host-kv-mib 16384 ^
  --spec mtp --draft-tokens 4 --no-cuda-graph --device-state-slots 0 ^
  --default-max-tokens 4096 --default-reasoning-effort none ^
  --max-shared-prefixes 0 ^
  --presence-penalty 0 --temperature 0.7 --top-p 0.9 --top-k 20

echo.
echo [engine exited] errorlevel=%ERRORLEVEL%
pause
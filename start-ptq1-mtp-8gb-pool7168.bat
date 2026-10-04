@echo off
REM ============================================================
REM  start-ptq1-mtp-8gb-pool7168.bat -- 8 GB profile, pool 7168.
REM
REM  [ADDED BY THE DEPLOYING AGENT 2026-10-04. Not part of the shipped
REM   pack. start-ptq1-mtp-8gb.bat is left byte-for-byte untouched.]
REM
REM  It is start-ptq1-mtp-8gb.bat with exactly ONE delta:
REM      --kv-capacity 8192  ->  7168        (112 pages instead of 128)
REM  Every other flag, the environment block, and the port guard are the
REM  same. --device-state-slots is NOT touched: it keeps its default (1),
REM  which is what lets the engine materialize the published MTP
REM  checkpoint. Do not "fix" a VRAM problem by setting that to 0: measured
REM  2026-10-04, a request against --device-state-slots 0 answers HTTP 500
REM  "published MTP checkpoint is not materializable" on multi-turn chats.
REM
REM  WHY (measured on THIS machine, 2026-10-04):
REM   09:19  requires 744,513,280  available 740,167,680   (4,345,600 B short)
REM   09:34  requires 744,513,280  available 739,663,872   (4,849,408 B short)
REM  Stable, not transient: the pool-8192 profile no longer fits this card
REM  once the desktop and DeepSeek Harness hold their own GPU memory
REM  (~580 MiB dedicated here, mostly the compositor at ~364 MiB).
REM
REM  THE ARITHMETIC, from the engine's own reported numbers:
REM    reservation = 520,576,768 B + 27,336 B x pool      (pool-independent
REM    part 520,576,768; the CUDA-Graph allowance is already excluded by
REM    --no-cuda-graph)
REM      pool 8192 -> 744,513,280 B = 710.0 MiB   does not fit
REM      pool 7168 -> 716,521,216 B = 683.3 MiB   fits with ~23 MiB spare
REM  So this file buys back the missing ~4.6 MiB by giving up 1,024 pool
REM  tokens (12.5% of the pool). That is the cheapest trade available:
REM    * --device-state-slots 0  would free ~147 MiB but breaks MTP (above);
REM    * a bigger pool cannot fit at all, and
REM    * --no-cuda-graph is already off, which is what removed the ~814 MiB
REM      CUDA-Graph term in the first place.
REM
REM  WHAT YOU LOSE, stated plainly: 1,024 tokens of DEVICE residency. A
REM  prompt at or above the pool is the condition the engine warns about
REM  ("the MIDDLE of such a prompt has been measured to go missing with no
REM   error line, HTTP 200 and a plausible wrong answer"), so keep the
REM  ceiling you configure in DeepSeek Harness in step with this number:
REM  cordis.patch.yml declares contextWindow 7168 for qwen3.8-27b, which
REM  puts dsh-compaction-basic's pressure threshold at
REM  floor(7168 x 0.8) = 5,734 tokens. If you raise the pool here, raise
REM  that line too.
REM
REM  Closing this console window stops the engine.
REM  ASCII-only on purpose: cmd parses a .bat in the OEM/ANSI codepage.
REM ============================================================
setlocal
set "ROOT=%~dp0"
if not defined MODEL set "MODEL=%ROOT%models\bonsai2_27b_ternary_ptq1_native_mtp.ninfer"
if not exist "%MODEL%" (
  echo REFUSE: model not found: "%MODEL%"
  echo         Put it in %ROOT%models\ or run:  set MODEL=D:\path\to\bonsai2_27b_ternary_ptq1_native_mtp.ninfer  ^&^& start-ptq1-mtp-8gb-pool7168.bat
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
echo [sized ] 8 GB profile, SHRUNK pool: --kv-capacity 7168, --no-cuda-graph (see the header)
echo.

"%ENGINE%" "%MODEL%" ^
  --host 127.0.0.1 --port 8095 --model-id qwen3.8-27b ^
  --max-context 262144 --kv-capacity 7168 --kv-dtype k8v4 --host-kv-mib 16384 ^
  --spec mtp --draft-tokens 4 --no-cuda-graph ^
  --default-max-tokens 4096 --default-reasoning-effort none ^
  --max-shared-prefixes 0 ^
  --presence-penalty 0 --temperature 0.7 --top-p 0.9 --top-k 20

echo.
echo [engine exited] errorlevel=%ERRORLEVEL%
pause
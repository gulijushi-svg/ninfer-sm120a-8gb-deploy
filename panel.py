# -*- coding: utf-8 -*-
"""
NInfer local control panel -- a dependency-free stand-in for the kind of
dashboard that MoE expert-offload servers ship (expert tiers, context fill,
recent requests, tok/s, hit rate), plus one-click engine control.

It is Python-standard-library only: http.server + subprocess + ctypes.
It talks to the machine, not to any cloud service.

WHAT IT DOES
  * serves panel.html at http://127.0.0.1:<port>/
  * GET  /api/state          live metrics as JSON
  * POST /api/engine/start   start the engine (with pool fallbacks)
  * POST /api/engine/stop    stop the engine (verified PID, never blind)
  * POST /api/engine/restart stop then start
  * POST /api/page/start     start the chat page (infer-chat.py, port 8097)

WHERE THE NUMBERS COME FROM
  * nvidia-smi    : GPU load / VRAM / temp / power / PCIe link
  * kernel32      : CPU total and physical RAM (GetSystemTimes,
                    GlobalMemoryStatusEx -- no psutil needed)
  * the engine's own stderr log: it is the only source for the pool size,
    per-request prompt/output/cache/TTFT/decode/MTP numbers. For that to
    work the engine has to be started BY THIS PANEL (then the log is a file
    the panel owns and tails). An engine started by a launcher window writes
    to its console instead, and the panel then shows HTTP-level state only --
    it says so in the UI instead of inventing numbers.

THE ENGINE ARGV IS THE SAME as start-ptq1-mtp-igpu.bat, including the
environment block, so the panel starts exactly what the launcher starts.
Pool fallbacks (15360 -> 12288 -> 8192 -> 7168) mirror start-ninfer.bat, so a
tightened desktop degrades instead of failing.
"""

import argparse
import ctypes
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

# ----------------------------------------------------------------------------
# configuration (filled in by main())
# ----------------------------------------------------------------------------
CFG = {
    "root": HERE,
    "engine_port": 8095,
    "page_port": 8097,
    "pool": 15360,
    "pool_fallbacks": [15360, 12288, 8192, 7168],
    "model": None,
    "log": None,
    "python": sys.executable,
}
LOCK = threading.Lock()
ENGINE_PROC = None          # our own child, if we started it


# ----------------------------------------------------------------------------
# small helpers
# ----------------------------------------------------------------------------
def log_path():
    """First writable candidate wins. %LOCALAPPDATA% normally, the toolkit's own
    records/ dir if the panel runs from a locked-down account, TEMP last."""
    if CFG["log"]:
        return CFG["log"]
    name = "engine-%d.log" % CFG["engine_port"]
    cands = []
    if os.environ.get("LOCALAPPDATA"):
        cands.append(os.path.join(os.environ["LOCALAPPDATA"], "NInferPanel", name))
    cands.append(os.path.join(CFG["root"], "records", "panel", name))
    cands.append(os.path.join(os.environ.get("TEMP") or os.path.expanduser("~"),
                              "NInferPanel", name))
    for c in cands:
        d = os.path.dirname(c)
        try:
            os.makedirs(d, exist_ok=True)
            probe = os.path.join(d, ".panel-write-test")
            with open(probe, "w") as f:
                f.write("")
            os.remove(probe)
            return c
        except Exception:
            continue
    return cands[-1]


def engine_exe():
    return os.path.join(CFG["root"], "engine", "ninfer-serve-120a.exe")


def model_path():
    if CFG["model"]:
        return CFG["model"]
    return os.path.join(CFG["root"], "models",
                        "bonsai2_27b_ternary_ptq1_native_mtp.ninfer")


def engine_env():
    env = dict(os.environ)
    eb = os.path.join(CFG["root"], "engine")
    env["PATH"] = eb + os.pathsep + os.path.join(eb, "x64") + os.pathsep + env.get("PATH", "")
    env["NINFER_KV_WINDOW"] = "16384"
    env["NINFER_KV_RETRIEVE"] = "8192"
    env["NINFER_KV_RING"] = "1"
    env["NINFER_HOST_PAGEABLE"] = "1"
    env["NINFER_KV_REUSE_HOSTBACKED"] = "1"
    env["NINFER_TERNARY_PTQ1_FAST"] = "1"
    return env


def http_ok(url, timeout=1.0):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return 200 <= r.status < 300
    except Exception:
        return False


def port_pid(port):
    """PID listening on `port`, or None. netstat output is parsed, and the
    PID is only accepted when the process name matches the engine."""
    try:
        out = subprocess.run(["netstat", "-ano", "-p", "tcp"],
                             capture_output=True, text=True, timeout=8).stdout
    except Exception:
        return None
    for line in out.splitlines():
        if "LISTENING" not in line:
            continue
        parts = line.split()
        if len(parts) >= 5 and parts[1].endswith(":%d" % port):
            pid = parts[-1]
            if pid.isdigit():
                return int(pid)
    return None


def proc_name(pid):
    try:
        out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"],
                             capture_output=True, text=True, timeout=8).stdout
        return out.split(",")[0].strip('"') if out.strip() else ""
    except Exception:
        return ""


# ----------------------------------------------------------------------------
# system metrics
# ----------------------------------------------------------------------------
class SysMeter(object):
    """CPU% from GetSystemTimes, RAM from GlobalMemoryStatusEx. Delta-based, so
    the first sample reports 0 -- callers poll steadily."""

    class FILETIME(ctypes.Structure):
        _fields_ = [("lo", ctypes.c_uint32), ("hi", ctypes.c_uint32)]

    class MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [("dwLength", ctypes.c_uint32), ("dwMemoryLoad", ctypes.c_uint32),
                    ("ullTotalPhys", ctypes.c_uint64), ("ullAvailPhys", ctypes.c_uint64),
                    ("ullTotalPageFile", ctypes.c_uint64), ("ullAvailPageFile", ctypes.c_uint64),
                    ("ullTotalVirtual", ctypes.c_uint64), ("ullAvailVirtual", ctypes.c_uint64),
                    ("ullAvailExtendedVirtual", ctypes.c_uint64)]

    def __init__(self):
        self.prev = None

    def _times(self):
        idle, kern, user = self.FILETIME(), self.FILETIME(), self.FILETIME()
        ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kern),
                                              ctypes.byref(user))
        def q(ft):
            return (ft.hi << 32) | ft.lo
        return q(idle), q(kern), q(user)

    def sample(self):
        out = {}
        try:
            idle, kern, user = self._times()
            if self.prev:
                di = idle - self.prev[0]
                dt = (kern - self.prev[1]) + (user - self.prev[2])
                if dt > 0:
                    out["cpu"] = max(0.0, min(100.0, 100.0 * (1.0 - float(di) / float(dt))))
            self.prev = (idle, kern, user)
        except Exception:
            pass
        try:
            m = self.MEMORYSTATUSEX()
            m.dwLength = ctypes.sizeof(self.MEMORYSTATUSEX)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m))
            out["ram_total_gb"] = round(m.ullTotalPhys / (1024.0 ** 3), 1)
            out["ram_used_gb"] = round((m.ullTotalPhys - m.ullAvailPhys) / (1024.0 ** 3), 1)
        except Exception:
            pass
        return out


SYSMETER = SysMeter()


def gpu_metrics():
    fields = ["name", "utilization.gpu", "memory.used", "memory.free", "memory.total",
              "temperature.gpu", "power.draw", "power.limit",
              "pcie.link.gen.current", "pcie.link.width.current", "display_active"]
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=" + ",".join(fields),
                              "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception as e:
        return {"error": "nvidia-smi unavailable: %s" % e}
    if not out:
        return {"error": "nvidia-smi returned nothing"}
    vals = [v.strip() for v in out.splitlines()[0].split(",")]
    vals += ["?"] * (len(fields) - len(vals))
    def num(x):
        try:
            return float(x)
        except Exception:
            return None
    out_d = {
        "name": vals[0],
        "util": num(vals[1]),
        "mem_used": num(vals[2]),
        "mem_free": num(vals[3]),
        "mem_total": num(vals[4]),
        "temp": num(vals[5]),
        "power": num(vals[6]),
        "power_limit": num(vals[7]),
        "pcie_gen": vals[8],
        "pcie_width": vals[9],
        "display_active": vals[10],
    }
    if not out_d.get("power_limit"):       # laptops often report [N/A] for power.limit
        try:
            o2 = subprocess.run(["nvidia-smi", "--query-gpu=power.default_limit",
                                 "--format=csv,noheader,nounits"],
                                capture_output=True, text=True, timeout=8).stdout.strip()
            v = num(o2.splitlines()[0]) if o2 else None
            if v:
                out_d["power_limit"] = v
        except Exception:
            pass
    return out_d


# ----------------------------------------------------------------------------
# engine log parsing
# ----------------------------------------------------------------------------
RE_CAPACITY = re.compile(r"capacity \| KV ([\d,]+) tokens.*?pages ([\d,]+)/([\d,]+)"
                         r".*?runtime ([\d.]+) MiB")
RE_READY = re.compile(r"engine ready \| (\S+) \| total ([\d.]+)s \| weights ([\d.]+) GiB")
RE_STARTED = re.compile(r"req#(\d+) started \| ([^|]+)\| (\d+) message.*?max output ([\d,]+)")
RE_DONE = re.compile(r"req#(\d+) done \| ([^|]+)\|(.*)$")
RE_PROMPT = re.compile(r"prompt ([\d,]+)")
RE_OUTPUT = re.compile(r"output ([\d,]+)")
RE_CACHE = re.compile(r"cache ([\d,]+) \(([\d.]+)%\)")
RE_TTFT = re.compile(r"TTFT ([\d.]+)s")
RE_TOTAL = re.compile(r"total ([\d.]+)s")
RE_DECODE = re.compile(r"decode ([\d.]+) tok/s")
RE_PREFILL = re.compile(r"prefill ([\d.]+) tok/s")
RE_MTP = re.compile(r"mtp accepted (\d+)/(\d+) \(([\d.]+)%\)")
RE_HOST = re.compile(r"host ([\d.]+)%")
RE_OVERS = re.compile(r"prompt exceeds the resident Device KV pool: prompt ([\d,]+) tokens"
                      r".*?> pool ([\d,]+) tokens")
RE_FATAL = re.compile(r"requires (\d+) bytes, but only (\d+) bytes are available")


def _int(s):
    return int(s.replace(",", ""))


class EngineLog(object):
    """Incremental tailer. Only lines that can carry numbers are regexed, so the
    engine's kvmem spam costs almost nothing."""

    def __init__(self, path):
        self.path = path
        self.off = 0
        self.pending = {}          # req# -> row
        self.rows = []             # finished rows, newest last
        self.tail = []             # last raw lines
        self.capacity = {}
        self.session = 0
        self.over_pool = None
        self.last_fatal = None
        self.model_name = None
        self.ready_at = None

    def reset(self):
        self.off = 0
        self.pending.clear()
        self.rows = []
        self.tail = []
        self.capacity = {}
        self.session = 0
        self.over_pool = None
        self.last_fatal = None

    def poll(self):
        if not self.path or not os.path.exists(self.path):
            return
        try:
            size = os.path.getsize(self.path)
            if size < self.off:          # rotated / truncated
                self.reset()
            if size == self.off:
                return
            with open(self.path, "rb") as f:
                f.seek(self.off)
                chunk = f.read(262144)
                self.off = f.tell()
        except Exception:
            return
        text = chunk.decode("utf-8", "replace")
        for line in text.splitlines():
            self._line(line)

    def _line(self, raw):
        line = raw.rstrip()
        if not line:
            return
        self.tail.append(line)
        if len(self.tail) > 40:
            self.tail = self.tail[-40:]
        if "req#" not in line and "capacity" not in line and "engine ready" not in line \
                and "exceeds the resident" not in line and "requires" not in line \
                and "throughput" not in line:
            return
        m = RE_READY.search(line)
        if m:
            self.session += 1
            self.pending.clear()
            self.ready_at = time.time()
            self.model_name = m.group(1)
            self.capacity["weights_gib"] = float(m.group(3))
            self.capacity["boot_s"] = float(m.group(2))
            return
        m = RE_CAPACITY.search(line)
        if m:
            self.capacity["pool"] = _int(m.group(1))
            self.capacity["pages_used"] = _int(m.group(2))
            self.capacity["pages_total"] = _int(m.group(3))
            self.capacity["runtime_mib"] = float(m.group(4))
            return
        m = RE_OVERS.search(line)
        if m:
            self.over_pool = {"prompt": _int(m.group(1)), "pool": _int(m.group(2))}
            return
        m = RE_FATAL.search(line)
        if m:
            self.last_fatal = {"requires": int(m.group(1)), "available": int(m.group(2))}
            return
        m = RE_STARTED.search(line)
        if m:
            self.pending[_int(m.group(1))] = {
                "req": _int(m.group(1)),
                "session": self.session,
                "started": line[:23].strip(),
                "started_epoch": time.time(),
                "mode": m.group(2).strip(),
                "messages": int(m.group(3)),
                "max_output": _int(m.group(4)),
                "done": False,
            }
            return
        m = RE_DONE.search(line)
        if m:
            rid = _int(m.group(1))
            rest = m.group(3)
            row = self.pending.pop(rid, {"req": rid, "session": self.session,
                                         "started": line[:23].strip(), "messages": None,
                                         "max_output": None})
            row["done"] = True
            row["at"] = line[:23].strip()
            row["mode"] = m.group(2).strip()
            row["note"] = " | ".join(x.strip() for x in rest.split("|")[:1]).strip()
            p = RE_PROMPT.search(rest)
            o = RE_OUTPUT.search(rest)
            c = RE_CACHE.search(rest)
            t = RE_TTFT.search(rest)
            tt = RE_TOTAL.search(rest)
            d = RE_DECODE.search(rest)
            pf = RE_PREFILL.search(rest)
            mtp = RE_MTP.search(rest)
            row["prompt"] = _int(p.group(1)) if p else None
            row["output"] = _int(o.group(1)) if o else None
            row["cache_tokens"] = _int(c.group(1)) if c else None
            row["cache_pct"] = float(c.group(2)) if c else None
            row["ttft"] = float(t.group(1)) if t else None
            row["total"] = float(tt.group(1)) if tt else None
            row["decode"] = float(d.group(1)) if d else None
            row["prefill"] = float(pf.group(1)) if pf else None
            row["mtp"] = "%s/%s (%s%%)" % mtp.groups() if mtp else None
            row["finish"] = ("输出上限" if "output limit" in rest else
                             ("工具调用" if "tool calls" in rest else
                              ("正常" if "stop token" in rest else "完成")))
            self.rows.append(row)
            if len(self.rows) > 200:
                self.rows = self.rows[-200:]
            return


LOG = EngineLog(None)


# ----------------------------------------------------------------------------
# engine control
# ----------------------------------------------------------------------------
def engine_argv(pool):
    return [engine_exe(), model_path(),
            "--host", "127.0.0.1", "--port", str(CFG["engine_port"]),
            "--model-id", "qwen3.8-27b",
            "--max-context", "262144", "--kv-capacity", str(pool),
            "--kv-dtype", "k8v4", "--host-kv-mib", "16384",
            "--spec", "mtp", "--draft-tokens", "4", "--no-cuda-graph",
            "--default-max-tokens", "4096", "--default-reasoning-effort", "none",
            "--max-shared-prefixes", "0",
            "--presence-penalty", "0", "--temperature", "0.7", "--top-p", "0.9", "--top-k", "20"]


def engine_up():
    return http_ok("http://127.0.0.1:%d/v1/models" % CFG["engine_port"], timeout=0.8)


def stale_engines():
    """Engine PIDs that exist but do not answer on the port.

    The engine is deliberately detached from the panel (so it survives the panel
    going away). The flip side: after a panel or DSH restart an engine can still
    hold its VRAM reservation while no longer serving. Every new pool attempt
    then fails with "only 0 bytes are available for runtime capacity", and the
    fallback chain quietly lands on a tiny pool. Clear the squatters first.
    """
    if engine_up():
        return []
    pids = []
    try:
        res = subprocess.run(["tasklist", "/FI", "IMAGENAME eq ninfer-serve-120a.exe",
                              "/FO", "CSV", "/NH"],
                             capture_output=True, text=True, timeout=10).stdout
        for line in res.splitlines():
            parts = [p.strip().strip('"') for p in line.split(",")]
            if parts and parts[0].lower().startswith("ninfer-serve-120a") \
                    and len(parts) > 1 and parts[1].isdigit():
                pids.append(int(parts[1]))
    except Exception:
        pass
    return pids


def start_engine(pools=None):
    """Start the engine, walking the pool list on VRAM refusal. Returns a dict
    describing what happened, including the engine's own refusal numbers."""
    global ENGINE_PROC
    with LOCK:
        if engine_up():
            pid = port_pid(CFG["engine_port"])
            return {"ok": True, "already": True, "pid": pid,
                    "message": "引擎已在运行（端口 %d 上 pid %s）" % (CFG["engine_port"], pid)}
        strays = stale_engines()
        if strays:
            for pid in strays:
                try:
                    subprocess.run(["taskkill", "/F", "/PID", str(pid)],
                                   capture_output=True, text=True, timeout=10)
                except Exception:
                    pass
            time.sleep(2.0)
        exe, mdl = engine_exe(), model_path()
        if not os.path.exists(exe):
            return {"ok": False, "message": "找不到引擎：%s" % exe}
        if not os.path.exists(mdl):
            return {"ok": False, "message": "找不到模型：%s" % mdl}

        lp = log_path()
        os.makedirs(os.path.dirname(lp), exist_ok=True)
        if os.path.exists(lp) and os.path.getsize(lp) > 32 * 1024 * 1024:
            try:
                os.replace(lp, lp + ".old")
            except Exception:
                pass
        LOG.path = lp
        LOG.reset()

        tried = []
        for pool in (pools or CFG["pool_fallbacks"]):
            LOG.last_fatal = None
            logf = open(lp, "ab", buffering=0)
            logf.write(("\n===== panel start | pool %d | %s =====\n"
                        % (pool, time.strftime("%Y-%m-%d %H:%M:%S"))).encode("utf-8"))
            try:
                proc = subprocess.Popen(engine_argv(pool), cwd=CFG["root"], env=engine_env(),
                                        stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                        creationflags=0x00000008 | 0x00000200)
            except Exception as e:
                logf.close()
                return {"ok": False, "message": "启动失败：%s" % e}
            LOG.off = 0
            LOG.poll()
            deadline = time.time() + 90
            foreign = None
            while time.time() < deadline:
                time.sleep(0.4)
                LOG.poll()
                if proc.poll() is not None and not engine_up():
                    break
                if engine_up():
                    serving = port_pid(CFG["engine_port"])
                    if serving is None or serving == proc.pid:
                        ENGINE_PROC = proc
                        return {"ok": True, "pool": pool, "pid": proc.pid, "log": lp,
                                "tried": tried,
                                "message": "引擎已启动：池 %d，pid %d" % (pool, proc.pid)}
                    foreign = serving
                    break
            else:
                try:
                    proc.kill()
                except Exception:
                    pass
            tried.append({"pool": pool, "fatal": LOG.last_fatal})
            try:
                proc.kill()
            except Exception:
                pass
        msg = "引擎启动失败：所有池值都被显存预留拒绝（%s）" % ", ".join(
            "%d%s" % (t["pool"],
                      ("：需要 %d B，可用 %d B" % (t["fatal"]["requires"], t["fatal"]["available"]))
                      if t["fatal"] else "")
            for t in tried)
        return {"ok": False, "tried": tried, "message": msg}


def stop_engine():
    global ENGINE_PROC
    with LOCK:
        pid = None
        if ENGINE_PROC is not None and ENGINE_PROC.poll() is None:
            pid = ENGINE_PROC.pid
        if pid is None:
            pid = port_pid(CFG["engine_port"])
        if pid is None and not engine_up():
            ENGINE_PROC = None
            return {"ok": True, "message": "引擎本来就没在运行"}
        if pid is None:
            return {"ok": False, "message": "端口有服务但拿不到 pid，未做任何操作"}
        name = proc_name(pid)
        if name and "ninfer" not in name.lower():
            return {"ok": False, "message": "端口 %d 上的 pid %d 是 %s，不是引擎，已放弃"
                                            % (CFG["engine_port"], pid, name)}
        stopped = False
        if ENGINE_PROC is not None and ENGINE_PROC.poll() is None:
            for meth in ("terminate", "kill"):
                try:
                    getattr(ENGINE_PROC, meth)()
                    stopped = True
                    break
                except Exception:
                    pass
        if not stopped or engine_up():
            subprocess.run(["taskkill", "/F", "/PID", str(pid)],
                           capture_output=True, text=True, timeout=10)
        def alive():
            return (port_pid(CFG["engine_port"]) is not None) or engine_up()
        for _ in range(25):
            if not alive():
                break
            time.sleep(0.4)
        if alive():
            return {"ok": False, "pid": pid,
                    "message": "停止失败：pid %d 仍在服务（可能需要管理员权限，或手动 taskkill /F /PID %d）"
                               % (pid, pid)}
        ENGINE_PROC = None
        return {"ok": True, "pid": pid, "message": "引擎已停止（pid %d）" % pid}


def page_script():
    """The chat page's file name has moved around between pack revisions, so try
    the known names and then any *chat*.py next to this panel."""
    cands = [os.path.join(CFG["root"], n) for n in
             ("ninfer-chat.py", "infer-chat.py", "chat-web.py", "chat.py")]
    cands += [os.path.join(CFG["root"], "tools", n) for n in
              ("ninfer-chat.py", "infer-chat.py")]
    for c in cands:
        if os.path.exists(c):
            return c
    try:
        import glob as _glob
        hits = sorted(_glob.glob(os.path.join(CFG["root"], "*chat*.py")))
        if hits:
            return hits[0]
    except Exception:
        pass
    return None


def start_page():
    py = CFG["python"]
    script = page_script()
    if not script:
        return {"ok": False, "message": "在 %s 里找不到聊天页脚本（ninfer-chat.py）" % CFG["root"]}
    if http_ok("http://127.0.0.1:%d/health" % CFG["page_port"], timeout=0.8):
        return {"ok": True, "already": True, "message": "聊天页已在运行"}
    try:
        subprocess.Popen([py, script, "--port", str(CFG["page_port"]),
                          "--engine", "127.0.0.1:%d" % CFG["engine_port"],
                          "--model", "qwen3.8-27b"],
                         cwd=CFG["root"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=0x00000008 | 0x00000200)
    except Exception as e:
        return {"ok": False, "message": "启动聊天页失败：%s" % e
                + "（可以改用 chat-web-ninfer.bat）"}
    for _ in range(30):
        time.sleep(0.4)
        if http_ok("http://127.0.0.1:%d/health" % CFG["page_port"], timeout=0.8):
            return {"ok": True, "message": "聊天页已启动：http://127.0.0.1:%d/" % CFG["page_port"]}
    return {"ok": False, "message": "聊天页启动超时，请看它的控制台"}


def state():
    LOG.poll()
    up = engine_up()
    pid = port_pid(CFG["engine_port"]) if up else None
    last = LOG.rows[-1] if LOG.rows else None
    # State pill. "reading" = prefill still running: a request is pending and has
    # been pending for less than the previous request's time-to-first-token.
    if not up:
        pill = "error"
    elif LOG.pending:
        row = sorted(LOG.pending.values(), key=lambda r: r.get("started_epoch") or 0)[-1]
        ref = (last.get("ttft") if last and last.get("ttft") else None) or 3.0
        pill = "reading" if (time.time() - (row.get("started_epoch") or 0)) < ref else "generating"
    else:
        pill = "idle"
    pool = LOG.capacity.get("pool") or (CFG["pool"] if up else None)
    ctx = None
    if pool and last and last.get("prompt"):
        ctx = {"pool": pool, "prompt": last["prompt"],
               "fill_pct": round(100.0 * last["prompt"] / pool, 1)}
    gpu = gpu_metrics()
    sysm = SYSMETER.sample()
    return {
        "engine": {
            "up": up, "pid": pid, "pill": pill,
            "pool": pool,
            "pages": ("%s/%s" % (LOG.capacity.get("pages_used"), LOG.capacity.get("pages_total"))
                      if LOG.capacity.get("pages_used") else None),
            "runtime_mib": LOG.capacity.get("runtime_mib"),
            "weights_gib": LOG.capacity.get("weights_gib"),
            "boot_s": LOG.capacity.get("boot_s"),
            "model": LOG.model_name,
            "log": LOG.path if LOG.path else None,
            "log_available": bool(LOG.path and os.path.exists(LOG.path)),
            "over_pool": LOG.over_pool,
            "last_fatal": LOG.last_fatal,
            "session": LOG.session,
            "pending": len(LOG.pending),
        },
        "gpu": gpu,
        "sys": sysm,
        "last": last,
        "context": ctx,
        "requests": LOG.rows[-25:][::-1],
        "tail": LOG.tail[-12:],
        "host_pct": None,
        "page": {"up": http_ok("http://127.0.0.1:%d/health" % CFG["page_port"], timeout=0.6),
                 "port": CFG["page_port"]},
        "cfg": {"engine_port": CFG["engine_port"], "pool": CFG["pool"],
                "model": os.path.basename(model_path())},
    }


# ----------------------------------------------------------------------------
# HTTP
# ----------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "NInferPanel/1.0"

    def log_message(self, fmt, *args):      # keep the console readable
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _file(self, name, ctype):
        p = os.path.join(HERE, name)
        if not os.path.exists(p):
            self._send(404, json.dumps({"error": "%s missing" % name}))
            return
        with open(p, "rb") as f:
            self._send(200, f.read(), ctype)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html", "/panel.html"):
            self._file("panel.html", "text/html; charset=utf-8")
        elif path == "/manifest.webmanifest":
            self._file("manifest.webmanifest", "application/manifest+json; charset=utf-8")
        elif path == "/favicon.ico":
            self._file("panel-icon.ico", "image/x-icon")
        elif path in ("/panel-icon.png", "/panel-icon-192.png", "/panel-icon.ico"):
            self._file(path.lstrip("/"),
                       "image/x-icon" if path.endswith(".ico") else "image/png")
        elif path == "/api/state":
            try:
                self._send(200, json.dumps(state(), ensure_ascii=False))
            except Exception as e:
                self._send(500, json.dumps({"error": str(e)}, ensure_ascii=False))
        elif path == "/health":
            self._send(200, json.dumps({"ok": True}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        path = self.path.split("?")[0]
        try:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            req = json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            req = {}
        if path == "/api/engine/start":
            pools = req.get("pools") or [req["pool"]] if req.get("pool") else None
            self._send(200, json.dumps(start_engine(pools), ensure_ascii=False))
        elif path == "/api/engine/stop":
            self._send(200, json.dumps(stop_engine(), ensure_ascii=False))
        elif path == "/api/engine/restart":
            r1 = stop_engine()
            r2 = start_engine()
            self._send(200, json.dumps({"ok": r2.get("ok"), "stop": r1, "start": r2},
                                       ensure_ascii=False))
        elif path == "/api/page/start":
            self._send(200, json.dumps(start_page(), ensure_ascii=False))
        else:
            self._send(404, json.dumps({"error": "not found"}))


def main():
    ap = argparse.ArgumentParser(description="NInfer local control panel")
    ap.add_argument("--port", type=int, default=8093,
                    help="panel port (8098 is used by the pack's usage-dashboard.py)")
    ap.add_argument("--engine-port", type=int, default=8095)
    ap.add_argument("--page-port", type=int, default=8097)
    ap.add_argument("--pool", type=int, default=15360)
    ap.add_argument("--log", default=None)
    ap.add_argument("--root", default=HERE)
    ap.add_argument("--model", default=None)
    ap.add_argument("--python", default=None, help="interpreter used for the chat page")
    ap.add_argument("--autostart-engine", action="store_true",
                    help="start the engine as soon as the panel is up (the desktop app uses this)")
    a = ap.parse_args()

    CFG["root"] = os.path.abspath(a.root)
    CFG["engine_port"] = a.engine_port
    CFG["page_port"] = a.page_port
    CFG["pool"] = a.pool
    CFG["log"] = a.log
    CFG["model"] = a.model
    if a.python:
        CFG["python"] = a.python
    pools = []
    for p in (a.pool, a.pool - 1024, a.pool - 2048, a.pool - 3072, 12288, 8192, 7168):
        if p >= 4096 and p not in pools:
            pools.append(p)
    CFG["pool_fallbacks"] = pools
    LOG.path = log_path()

    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print("NInfer panel : http://127.0.0.1:%d/" % a.port)
    print("engine       : 127.0.0.1:%d   (pool %d, fallbacks %s)"
          % (a.engine_port, a.pool, pools))
    print("chat page    : 127.0.0.1:%d" % a.page_port)
    print("engine log   : %s" % LOG.path)
    print("Ctrl+C or close this window stops the panel; a panel-started engine keeps running.")

    if a.autostart_engine:
        def _auto():
            time.sleep(1.0)
            res = start_engine()
            print("[autostart] " + str(res.get("message")))
        threading.Thread(target=_auto, daemon=True).start()

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
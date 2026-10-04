# NInfer sm_120a 引擎包 · 8 GB 显卡（RTX 5060）部署工具集

本仓库**只包含我们自己写的脚本、文档与实验记录**，用于把一台 8 GB 显存的机器
（NVIDIA GeForce RTX 5060，compute capability 12.0）跑通 **NInfer `sm_120a` 引擎包**（PTQ1_0 档）。

## 不包含什么（重要）

| 未包含 | 大小 | 原因 |
|---|---|---|
| `engine\ninfer-serve-120a.exe` 及 9 个运行时 DLL | 1,901 MiB | 是发布方的二进制制品；且单文件超过 GitHub 的 100 MiB 硬上限 |
| `models\bonsai2_27b_ternary_ptq1_native_mtp.ninfer` | 6,098 MiB | 是独立分发的模型包；6 GB 单文件无法上传（Release 单资产上限也只有 2 GB） |

⇒ 想跑起来需要**自备引擎包与模型包**：引擎解到本仓库同级目录，模型放进 `models\`，
文件名逐字保持 `bonsai2_27b_ternary_ptq1_native_mtp.ninfer`（6,394,697,216 B，
sha256 `5C4486C8A52687E3F62072C7DD2A320546D0E00D1C019BF137EB02CC944E21B8`）。
本仓库的 Release `engine-sm120a-20261002` 里另存了 `engine\` 目录的 11 个文件（1.86 GiB）作为备份。

## 快速开始

1. 引擎与模型放好后 → 双击 **`start-ptq1-mtp-lan.bat`**（局域网 + 鉴权 + 统计口 + 请求日志）
2. 聊天页：双击 **`chat-web.bat`** → <http://127.0.0.1:8097/>
3. 终端聊天 `chat-cli.bat` · AI agent `agent\agent.bat` · 用量看板 `usage.bat` → <http://127.0.0.1:8098/>
4. 单机自用：`start-ptq1-mtp-8gb.bat`（只绑 127.0.0.1，不起统计口与日志）
5. 面板 / 桌面应用：双击 **`panel-app.bat`**（可在桌面放一个指向它的快捷方式）
   → 自动起面板服务并用 Edge/Chrome 的**无地址栏窗口**打开 <http://127.0.0.1:8093/>
6. 集显分担显示的本机档：双击 **`start-ninfer.bat`**（链式尝试
   igpu 15360 → 12288 → 7168 → tight，成功即停）

## 六档启动器（每个只管一件事，方便一次只改一个变量）

| 启动器 | 主机池 | 逻辑上下文 | 解码 | 监听 | 统计口/请求日志 | 用途 |
|---|---|---|---|---|---|---|
| `start-ptq1-mtp-8gb.bat` | 16 GiB | 256K | draft 4 | 127.0.0.1 | 无 | 仅本机 |
| `start-ptq1-mtp-lan.bat` | 16 GiB | 256K | draft 4 | 0.0.0.0 + API key | 有 | 基线（对外服务） |
| `start-ptq1-mtp-fast.bat` | 16 GiB | 256K | **draft 12 + fast-prefill** | 同上 | 有 | 只要速度 |
| `start-ptq1-mtp-lan-bigctx.bat` | 24 GiB | 768K | draft 4 | 同上 | 有 | 只要容量 |
| `start-ptq1-mtp-lan-1m.bat` | 28 GiB | **1M** | **draft 12 + fast-prefill** | 同上 | 有 | 容量 + 速度（推荐日常） |
| `start-ptq1-mtp-diskkv.bat` | 28 GiB | 1M | draft 12 + fast-prefill | 同上 | 有 | 再加**磁盘 KV 层**（64 GiB，跨重启存活） |

**容量规则**（引擎启动时强制，教程 §2）：`主机池页数 + 设备池页数 ≥ 逻辑上下文页数`，页 = 64 token；
本 artifact 的主机开销实测 **25.12 KiB/token**（`host_kv_page_group_bytes = 1,646,592 B / 64 token`）：

```
max_context  262144 ->  6.28 GiB     524288 -> 12.56 GiB
             786432 -> 18.84 GiB    1048576 -> 25.12 GiB      2097152 -> 50.25 GiB（本机不可行）
```

## 参数审计（哪些必需、哪些只是噪音）

默认值全部取自引擎自己的 `--help`。**已从所有启动器删除两个与默认值逐字相同的纯冗余参数**：
`--prefill-chunk 1024`（default 1024）与 `--max-concurrency 1`（default 1）。

以下三条**不能删**，各有实测依据：

| 参数 | 引擎默认 | 为什么必须保留 |
|---|---|---|
| `--kv-capacity 8192` | 默认 = `--max-context`（1M！） | 删了池会变成 1M token，8 GB 显存装不下 |
| `--no-cuda-graph` | CUDA Graph **默认开** | 关掉它才把运行时预留从 `1,863,978,752` 降到 `1,010,437,888` 字节；否则启动即被拒 |
| `--default-max-tokens 4096` | 8192 | 池只有 8192；手册 §1-11 要求 `max_tokens ≤ 池`（客户端要 32,000 会触发 worker 崩溃） |

**环境变量**：`NINFER_KV_WINDOW=16384` 是**打开 KVMem（ring + 内容打分）的开关**，删了就退回词法排序；
`NINFER_HOST_PAGEABLE=1` 在 Windows 上必需（钉住的主机内存会映射进 GPU 地址空间、与显存抢地盘）。

## 关键实测读数（RTX 5060 8 GB / 驱动 591.86）

| 项 | 读数 |
|---|---|
| 引擎启动 | `engine ready | bonsai2-27b | total 3.7s`；`capacity | KV 8,192 tokens, k8v4, explicit | runtime 710.0 MiB` |
| 数数字语料 1,000 进 / 1,000 出 | prefill 482–670 tok/s · decode 54–99 tok/s · MTP 接受 780/875 = 89.1% |
| 与构建机（RTX 4080 SUPER，decode 196.8 tok/s）对比 | 慢约 3.3×（带宽 448 vs 736 GB/s；为装进 8 GB 关闭了 CUDA Graph） |
| 工具调用 | 支持；`finish_reason=tool_calls` + 规范 `tool_calls` 数组 |
| **同配置重复测量波动** | 同一档两次测出 **54.7** 与 **80.0 tok/s**（差 46%）⇒ 单次读数不可作准，须重复取中位数 |
| 排队 | `--max-concurrency 1`；日志实测一次 19.5k 题面 / 3.1k 输出的请求把后续请求堵了 **81 秒** |
| 共享显存 | **不可用**：`--wddm-evictable-budget` 需要 `NINFER_D3D12_RESIDENCY=ON` 的构建，本 exe 未编入 |

## 目录

| 路径 | 作用 |
|---|---|
| `start-ptq1-mtp-*.bat` | 上表六档启动器 |
| `allow-firewall-8095.bat` | 一键（自提权）放行入站 TCP 8095 |
| `ninfer-chat.py` / `chat-web.bat` | 聊天页 + 同源代理（引擎无内置网页、不发 CORS）+ 交付护栏 + `max_tokens` 钳制 |
| `panel.py` / `panel.html` / `panel.bat` | **本机控制面板**（一键启停引擎 + 指标 + 逐请求读数），默认 <http://127.0.0.1:8093/> |
| `panel-app.bat` + `manifest.webmanifest` + `panel-icon*` | **桌面应用入口**（Edge/Chrome `--app=` 无地址栏窗口）与 PWA 清单/图标 |
| `ninfer-cli.py` / `chat-cli.bat` | 终端聊天（不经浏览器） |
| `agent\agent-min.py` / `agent.bat` / `agent-lan.bat` | 最小 AI agent（工具循环 + 手册护栏 + 文件沙箱；`agent-lan` 用于连接远端引擎） |
| `usage-dashboard.py` / `usage.bat` | 用量看板（读引擎结构化请求日志 + 统计口） |
| `test-speed.bat` / `tools\speedtest.py` | 一键权威测速（打印引擎自报的 prefill / decode / 投机接受率） |
| `demos\` | 示例提示词与产出（单文件 HTML 蜻蜓闹钟） |
| `docs\` | 换设备部署指南、手册落地记录、局域网验证记录 |
| `records\` | 全部工程记录：逐轮读数、被拒原文、隔离实验、生成与验证脚本 |

## 本机 8 GB 档：关闭独显直连后的设备池

关闭"独显直连"（显示由核显驱动）后，显示占用不再计入独显，
本机实测可用的最高设备池档是 **15,360 token**：

| 档位 | 设备池 | 运行时预留（实测） | 备注 |
|---|---|---|---|
| `start-ptq1-mtp-igpu.bat` | **15,360** | 896.9 MiB（`capacity \| KV 15,360 tokens, k8v4, explicit \| pages 240/4,096`） | 本机推荐档 |
| `start-ptq1-mtp-8gb-tight.bat` | 12,288 | — | 第一降级 |
| `start-ptq1-mtp-8gb-pool7168.bat` | 7,168 | — | 老 8 GB 档 |
| `start-ninfer.bat` | 链式 | — | igpu15360 → 12288 → 7168 → tight，成功即停 |

设备池预留的实测公式：**`520,576,768 B + 27,336 B × 池`**。
实测天花板约 **17,600**；`20,480` 已确认装不下（启动被拒）。
两档都不需要 CUDA Graph（`--no-cuda-graph`，graph 会多要 814–850 MiB）。

## 控制面板 · 桌面应用

把启停、状态与逐请求读数收进一个纯标准库的本地服务，并给它套一个可双击的窗口。

| 文件 | 作用 |
|---|---|
| `panel.py` | 面板服务：`GET /`、`/panel.html`、`/manifest.webmanifest`、`/favicon.ico`、图标；`GET /api/state`；`POST /api/engine/start\|stop\|restart`、`/api/page/start` |
| `panel.html` | 仪表盘：状态灯（空闲/读取中/生成中/离线）、8 张指标卡（速度/GPU 负载/显存/温度/功耗/PCIe/CPU/内存）、上下文占用环、最近的请求表（时间/状态/题面/复用/输出/tok·s/命中率/首字/耗时）、引擎输出尾部 |
| `panel.bat` | 起面板并打开浏览器（默认 <http://127.0.0.1:8093/>） |
| `panel-app.bat` | **桌面应用入口**：先确保面板服务在跑，再用 Edge/Chrome 的 `--app=` 打开无地址栏窗口；支持 `NINFER_POOL` / `NINFER_WIN` / `NINFER_PY` 覆盖 |
| `manifest.webmanifest` + `panel-icon*.png|ico` | PWA 清单与图标：Edge 里「⋯ → 应用 → 安装此站点为应用」可得到开始菜单/任务栏条目 |

- 端口约定：面板 **8093**、引擎 8095、聊天页 8097、用量看板 8098 —— 各自独立，互不抢占。
- `--autostart-engine`（`panel-app.bat` 默认带上）：面板起来 1 秒后自动按
  15360 → 12288 → 8192 → 7168 的重试链拉起引擎。
- **引擎是独立进程**：关掉面板窗口 ≠ 停引擎；面板只接管"自己启动的"那个引擎的日志，
  别人的引擎只能看端口状态。
- 判据都是硬的：「启动」要求端口上的 PID 就是本次启动的进程；
  「停止」要求端口/进程真的消失，没停掉会如实报失败而不是假成功。
- 面板只监听 `127.0.0.1`，不需要联网，也不需要 `psutil`（ctypes 读系统计数）。

## 客户端预算与设备池对齐（踩过的坑）

引擎日志能唯一地证明这件事：`req#N started | ... max output M` 与
`req#N done | ... output limit | prompt P | output 1`。

- 客户端（DeepSeek Harness）的解码预算是 `max_tokens = contextWindow − 题面`，
  题面一超过声明值就被夹成 **1** —— 症状是"只回一个字"，工具调用还会变成
  `tool markup returned as text | malformed structure`。
- 客户端的 token 估算比引擎实际计数**高约 40%**（中文长会话更明显）：
  引擎实测 9,514 → 客户端按 ~13,315 扣预算；引擎实测 14,209 → 客户端已按 ≥15,360 扣。
  ⇒ 声明 15,360 时，客户端侧实际只喂到约 11k 真实 token。
- 对策：`contextWindow` 必须等于启动器的 `--kv-capacity`；
  压缩阈值（`thresholdRatio`）要留出足够生成摘要的余量；
  **一旦越线只能新开会话** —— 压缩本身也要生成 token，同样会被夹成 1。
- 引擎侧越池时会打印 `prompt exceeds the resident Device KV pool`，
  并实测"题面中段可能悄悄丢失、HTTP 200 但答案是错的"，所以宁可降档也不要越池。

## 许可与归属

- 引擎与模型归发布方（UP主 / Prism ML / 阿里云等）所有，**不在本仓库**；Release 中的镜像仅作备份，请勿再分发。
- 本仓库的脚本与文档：由部署 agent 编写，随你处置（若发布请自行附许可）。
- 发布方单独投递的内部手册**未收录**：公开再分发请先取得同意。

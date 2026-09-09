# CuberiteMCPServer

把 Cuberite Minecraft 服务器暴露为 MCP（Model Context Protocol）服务器（Streamable HTTP），让 LLM 主机可以调用服务器工具。
> 本文档为双语。所有文档保持中英双语。

## 配置

一切配置都在单个文件 config.ini（首次运行自动生成默认值；机器相关，gitignored——settings.ini 已并入）：

- [Network] Port / [Security] AllowedIPPrefixes — MCP HTTP 端点
- [Engine] Engine — mineflayer（默认）| mcc（已弃用回退）
- [Bot] — mineflayer bot。NodePath 可空（= PATH 上的 node）或绝对路径；BotDir 默认 bot（相对插件目录）。相对路径在加载时按插件目录解析（服务器从自身 CWD 用 os.execute 启动 bot，无法自己解析相对路径）。
- [MCC] — 已弃用回退引擎，Enabled 默认 false
- [VoidGuard] — 虚空坠落守卫，Enabled 默认 false（mineflayer 引擎能干净重生、不会落入虚空；仅遗留 MCC 引擎或异常地形才需要）。

## Bot 引擎

插件管理一个测试 bot，引擎可在 config.ini 切换：

- [Engine] Engine = mineflayer — **默认**。bot/ 里的 mineflayer bot（Node 22，无状态 MCP 端点 :33333；见 bot/README.md）。配置走 [Bot] NodePath / BotDir / Username / RandomUsername / MinecraftVersion（默认 1.12.2 —— Cuberite 的协议上限；需要 npm install 应用 prismarine-chunk 补丁；见 docs/version-compat-matrix.md）。
- [Engine] Engine = mcc — **已弃用** 遗留 Minecraft Console Client（85MB 二进制），仅作手动回退保留（mcc.lua）。

生命周期命令（控制台）：bot <start|stop|restart|status>，以及 mcc <start|stop|restart|status>（已弃用）；同样的动作也暴露为 MCP 工具 bot_* / mcc_*。

## 文档

每个文档的中文版见对应的 `*.zh.md` 文件（例如本 README → `README.zh.md`）。

- AGENTS.md — AI 代理开发指南（必读）
- bot/README.md — bot 架构与全部 mcc_* 工具索引
- docs/version-compat-matrix.md — 协议版本 vs Cuberite + prismarine-chunk 补丁
- docs/handoff-mineflayer-migration.md — 实现交接记录
- docs/feasibility-mineflayer.md — 可行性研究
- docs/baseline-mcc-tools.md — 采集的 MCC 工具基线
- docs/smoke-results.md — mineflayer × Cuberite phase-0 门禁结果

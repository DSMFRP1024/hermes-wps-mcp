# Hermes WPS MCP

上游 [`lc2panda/wps-skills`](https://github.com/lc2panda/wps-skills) 的**离线部署适配版**，
用于内网 aarch64 Linux（银河麒麟 V10 / 统信 UOS 20 / openEuler）上，
让 Hermes Agent 通过 MCP 直接操作正在运行的 WPS 文档。

- 上游 pin：`a82533662268b3245f93d8685bc45dffede048b6`
- 许可：MIT（与上游一致）
- **不是重写**，是 clone + 环境适配。业务逻辑（243 个工具的实现）一行没动。
- 上游原始说明保留在 [`README.upstream.md`](README.upstream.md)

关于「为什么不直接在 GitHub 上 fork」：本仓库是**独立仓库**，但保留了完整上游历史
（首个提交的父提交就是上游 pin），并且配了 `upstream` remote。这样上游后续修复仍能合并：

```bash
git remote add upstream https://github.com/lc2panda/wps-skills.git   # 已配置则跳过
git fetch upstream main
git merge upstream/main        # 或 git diff upstream/main 只看我们改了什么
```

GitHub 上的「Forked from」标识是没有的 —— 这是一个内网适配发布仓库，
需要打自己的 release 产物、写自己的 README，独立更清晰。

## 能力

243 个工具：231 个专业工具 + 12 个内置工具，覆盖 Excel 82 / Word 28 / PPT 112 / 通用 21。

能做到「实时」是因为加载项跑在 WPS 自己的 V8 引擎里，直接操作文档对象模型：
**改动立刻上屏、格式自动继承、不与用户的 Ctrl+S 冲突**。
MCP Server 不碰文件，只把命令排进队列，等加载项轮询取走。

```
Hermes Agent
   │  MCP (stdio)
   ▼
wps-office-mcp  (node dist/index.js)
   │  HTTP 轮询，仅 127.0.0.1:58891
   ▼
WPS 加载项「Claude助手」（WPS 内嵌 V8）
   │  WPS JS API
   ▼
你正在编辑的文档（内存对象）
```

## 三端

| 平台 | 通道 | 本仓库状态 |
|---|---|---|
| **Linux** | 反向轮询（与 macOS 共用一套） | **适配目标，CI 覆盖** |
| macOS | 反向轮询 | 上游支持，未验证 |
| Windows | PowerShell + COM | 上游支持，未验证 |

## 相对上游改了什么

只有下面这些，逐条列出便于对照回滚。

| # | 文件 | 改动 | 原因 |
|---|---|---|---|
| 1 | `wps-office-mcp/src/client/mac-poll-server.ts` | `switchApp()` 开头加 Linux 分支直接返回 | 原实现调 `wps-auto.sh`，其 `start_app()` 用 macOS 的 `open` 命令（Linux 没有），pptx 分支还依赖 `python-pptx`。内网场景 Hermes 常驻、WPS 用户自己开，无需拉起/杀进程 |
| 2 | `install.sh` | **新增** | 上游 `scripts/install.sh` 到处是 `claude mcp add`、`~/.claude/skills`、联网检查 |
| 3 | `build/test_poll_protocol.mjs` | **新增** | 上游**零测试**：`jest.config.js` 指向的 `src/tests/setup.ts` 根本不存在，`npm test` 必然失败 |
| 4 | `build/verify_dist.mjs` | **新增** | 拦「编译绿了但产物不可用」 |
| 5 | `build/package_offline.sh` | **新增** | 内网无 npm，必须自带 `node_modules` |
| 6 | `build/verify_package.py` | **新增** | CI 与本地同一份校验规则 |
| 7 | `.github/workflows/build.yml` | **新增** | 目标机是 aarch64，x86 上跑绿没意义 |
| 8 | `README.md` / `SKILL.md` | **替换** | 说明来源、改动、部署 |
| 9 | `build/test_install.py` | **新增** | `install.sh` 的语义测试：合并、幂等、卸载不误伤他人配置 |
| 10 | `build/test_verify_package.py` | **新增** | 校验器自身的回归测试（符号链接判定），不依赖宿主符号链接权限 |

**完全没动**：`tools/**`、`server/**`、`client/wps-client.ts`、
`wps-claude-assistant/**`（加载项本体）、`skills/**`。

## 产出离线包

联网机或 CI：

```bash
cd wps-office-mcp && npm ci && npx tsc -p tsconfig.json && cd ..
node build/verify_dist.mjs
node build/test_poll_protocol.mjs
bash build/package_offline.sh
# -> dist-pkg/wps-mcp-offline-aarch64.tar.gz + .sha256
```

或直接取 CI artifact（workflow `build-wps-mcp`，runner `ubuntu-24.04-arm`）。

## 内网安装

```bash
tar -xzf wps-mcp-offline-aarch64.tar.gz -C wps-mcp
cd wps-mcp
bash install.sh --dry-run     # 先看它要做什么
bash install.sh
```

`install.sh` 依次做：探测 node/WPS → 校验包完整性 → 部署服务与加载项 →
**合并**（非覆盖）`publish.xml`（改前备份）→ 重启 WPS → 打印 MCP 配置片段。

### 在 Hermes 注册 MCP

```json
{
  "wps-office": {
    "command": "/path/to/node",
    "args": ["/home/<user>/.local/share/hermes-wps-mcp/wps-office-mcp/dist/index.js"],
    "env": { "WPS_MCP_PORT": "58891" }
  }
}
```

## 启动顺序（重要）

**先起 Hermes（含 MCP），再开 WPS。**

反之在麒麟上有已知问题：WPS 已运行后再起 MCP Server，WPS 进程可能异常退出
（上游 Issue #17）。Hermes 常驻这一点天然满足正确顺序。

## 验证

```bash
# 加载项是否注册成功
cat ~/.local/share/Kingsoft/wps/jsaddons/publish.xml
ls  ~/.local/share/Kingsoft/wps/jsaddons/claude-assistant_/

# 服务是否在跑（需 Hermes 已拉起 MCP）
curl -s http://127.0.0.1:58891/status

# 端到端：重启 WPS，功能区应出现「Claude助手」
#         然后在 Hermes 里问「看看当前表格有哪些工作表」
```

日志：`~/.wps-office-mcp/logs/combined.log` / `error.log`。

## 已知限制

- **必须有图形会话**。加载项的宿主是运行中的 WPS 进程；无头服务器上整条链不成立。
- **只能操作活动文档**。WPS JS API 是 `ActiveWorkbook` / `ActiveDocument` 语义。
- **同机**。加载项与 MCP Server 必须同机，走 `127.0.0.1`。
- **加载项注册机制脆弱**。目录名尾部 `_`、`publish.xml` 的 `url` 前缀、
  `oem.ini` 的 `JsApiPlugin`，任一不符就**静默不加载**，零报错。
- **ARM64 的 WPS 无公开下载**。需从统信/麒麟 OEM 渠道或已预装整机获取，
  注意 OEM 授权与机器绑定。
- **测试覆盖有限**。补的协议测试只覆盖轮询链路，不覆盖 243 个工具的语义。

## 卸载

```bash
bash install.sh --uninstall
```

**什么都不删，全部改名留备份**：

- 安装目录 → `~/.local/share/hermes-wps-mcp.bak.<时间戳>`
- 加载项目录 → `jsaddons/claude-assistant_.bak.<时间戳>`
- `publish.xml` 改前先 `cp` 一份 `.bak.<时间戳>`

卸载只做两件事：从 `publish.xml` 摘掉 `name="claude-assistant"` 那一条（**别人的条目一条不碰**），
以及把上面三个位置改名。想回滚：把两个 `.bak` 改回原名即可。

> 不用 `rm -rf` 是有原因的：部分环境把 `rm` 劫持成回收站 shim，
> 会阻塞或直接失败；而且删了之后回滚只能重装。

## 本地快速跑测试

Windows / 无 `node_modules` 的环境也能跑安装语义测试：

```bash
WPS_TEST_STUB=1 python3 build/test_install.py     # 桩包，秒级
python3 build/test_verify_package.py              # 校验器回归测试
```

CI 不设 `WPS_TEST_STUB`，始终用真包 —— 防止「桩包绿了真包红」。

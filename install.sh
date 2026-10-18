#!/usr/bin/env bash
# WPS MCP 离线安装（内网 aarch64 / x86_64 Linux）
#
# 前置：本目录即离线包根目录，其中应包含
#   wps-office-mcp/dist/         编译产物（含 index.js）
#   wps-office-mcp/node_modules/ 生产依赖（已 prune，不含 jest/tsc）
#   wps-assistant/        WPS 加载项
#
# 用法：
#   bash install.sh --dry-run        # 只打印将要做什么
#   bash install.sh                  # 安装
#   bash install.sh --uninstall      # 卸载（保留备份）
#   bash install.sh --prefix DIR     # 自定义安装目录
#
# 设计约束（内网）：零外网、零 npm、零图形会话假设。
# 不修改任何已有配置：publish.xml 走合并而非覆盖，改前先备份。

set -euo pipefail

ADDON_NAME="wps-assistant"
ADDON_DIR_NAME="${ADDON_NAME}_"          # 尾部 _ 是 WPS jsaddons 规范
ADDON_TAB_LABEL="WPS助手"

PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${HOME}/.local/share/hermes-wps-mcp"
JSDADDONS="${HOME}/.local/share/Kingsoft/wps/jsaddons"

DRY_RUN=0
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --prefix)    shift; PREFIX="$1" ;;
    --jaddons)   shift; JSDADDONS="$1" ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

say()   { printf '  %s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }
warn()  { printf '  ! %s\n' "$*" >&2; }

run() {
  if [ "$DRY_RUN" = "1" ]; then printf '  [dry-run] %s\n' "$*"; else eval "$@"; fi
}

PUBLISH_XML="${JSDADDONS}/publish.xml"

# ---------------------------------------------------------------- 探测

head_ "1/5 环境探测"

NODE_BIN=""
for c in node; do
  if command -v "$c" >/dev/null 2>&1; then NODE_BIN="$(command -v "$c")"; break; fi
done
if [ -z "$NODE_BIN" ]; then
  warn "未找到 node。Hermes 主包自带 Node，请把它加入 PATH 后重试。"
  exit 1
fi
NODE_VER="$("$NODE_BIN" -v 2>/dev/null || echo unknown)"
say "node: $NODE_BIN ($NODE_VER)"
case "$NODE_VER" in
  v1[89].*|v2[0-9].*) : ;;
  *) warn "node 版本低于 18，MCP 服务可能无法启动（上游要求 >=18）" ;;
esac

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
say "python: ${PY:-未找到（publish.xml 合并将降级为纯文本追加）}"

QUICKSTART=""
for c in \
  /opt/apps/cn.wps.wps-office-pro/files/bin/quickstartoffice \
  /opt/kingsoft/wps-office/office6/quickstartoffice \
  /usr/bin/quickstartoffice
do
  if [ -x "$c" ]; then QUICKSTART="$c"; break; fi
done
say "quickstartoffice: ${QUICKSTART:-未找到（稍后手动重启 WPS）}"

say "安装目录: $PREFIX"
say "加载项目录: $JSDADDONS"

# 常见坑：用户习惯 `sudo bash install.sh`，于是 $HOME=/root，
# 加载项落到 /root/.local/share/Kingsoft/wps/jsaddons —— 日常用户开 WPS 时**完全不生效**，
# 而且没有任何报错。这里不阻止（确有人以 root 跑图形会话），但必须显式告警。
if [ "$(id -u)" = "0" ] || [ "$HOME" = "/root" ]; then
  warn "当前以 root 运行，加载项将注册到 $JSDADDONS"
  warn "若你平时用普通用户打开 WPS，请改用该用户执行；或用 --jaddons 显式指向"
  warn "该用户的 ~/.local/share/Kingsoft/wps/jsaddons"
fi

# ---------------------------------------------------------------- 卸载

if [ "$UNINSTALL" = "1" ]; then
  head_ "卸载"
  if [ -d "$PREFIX" ]; then
    BK="${PREFIX}.bak.$(date +%Y%m%d%H%M%S)"
    run "mv '$PREFIX' '$BK'"
    say "已移到备份: $BK（未删除）"
  else
    say "安装目录不存在，跳过"
  fi

  # 卸载也不直接删：移到备份目录，出问题能立刻搬回去。
  # （不用 rm -rf：某些环境把 rm 劫持成回收站 shim，会阻塞或直接失败）
  if [ -d "${JSDADDONS}/${ADDON_DIR_NAME}" ]; then
    ABK="${JSDADDONS}/${ADDON_DIR_NAME}.bak.$(date +%Y%m%d%H%M%S)"
    run "mv '${JSDADDONS}/${ADDON_DIR_NAME}' '$ABK'"
    say "加载项已移到备份: $ABK（未删除）"
  else
    say "加载项目录不存在，跳过"
  fi
  if [ -f "$PUBLISH_XML" ]; then
    run "cp -a '$PUBLISH_XML' '${PUBLISH_XML}.bak.$(date +%Y%m%d%H%M%S)'"
    if [ -n "$PY" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        printf '  [dry-run] 从 publish.xml 移除 %s\n' "$ADDON_NAME"
      else
        "$PY" - "$PUBLISH_XML" "$ADDON_NAME" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET
path, name = sys.argv[1], sys.argv[2]
root = ET.parse(path).getroot()
removed = 0
for n in list(root):
    if n.get("name") == name:
        root.remove(n); removed += 1
out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>', "<jsplugins>"]
for n in root:
    a = " ".join('%s="%s"' % (k, v) for k, v in n.attrib.items())
    out.append("  <%s %s/>" % (n.tag, a))
out.append("</jsplugins>")
open(path, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
print("  已移除 %d 条" % removed)
PYEOF
      fi
    else
      warn "无 python，请手工从 publish.xml 删掉 name=\"${ADDON_NAME}\" 那一行"
    fi
  fi
  if [ -n "$QUICKSTART" ]; then run "'$QUICKSTART' restart || true"; fi
  echo "卸载完成。请完全退出并重启 WPS。"
  exit 0
fi

# ---------------------------------------------------------------- 校验离线包

head_ "2/5 校验离线包完整性"

for f in \
  "wps-office-mcp/dist/index.js" \
  "wps-office-mcp/node_modules/@modelcontextprotocol/sdk/package.json" \
  "wps-assistant/manifest.xml" \
  "wps-assistant/ribbon.xml" \
  "wps-assistant/main.js"
do
  if [ -e "${PKG_ROOT}/${f}" ]; then
    say "ok  $f"
  else
    warn "缺失 ${f} —— 离线包不完整，请重新解压"
    exit 1
  fi
done

# ---------------------------------------------------------------- 部署服务

head_ "3/5 部署 MCP 服务 -> $PREFIX"

run "mkdir -p '$PREFIX'"
run "cp -a '${PKG_ROOT}/wps-office-mcp' '${PREFIX}/'"
run "cp -a '${PKG_ROOT}/wps-assistant' '${PREFIX}/'"
# 让 switchApp 里的相对路径（../../../wps-assistant）依然成立：
#   $PREFIX/wps-office-mcp/dist/client  -> 三次上跳 = $PREFIX
say "目录结构保持 wps-office-mcp 与 wps-assistant 同级（路径依赖）"

# ---------------------------------------------------------------- 注册加载项

head_ "4/5 注册 WPS 加载项 -> ${JSDADDONS}/${ADDON_DIR_NAME}"

run "mkdir -p '$JSDADDONS'"

# 旧品牌 ID 迁移。早期版本把加载项注册成 claude-assistant，改名后若不清理，
# publish.xml 里会留一条指向已失效目录的旧条目（功能区可能出现两个页签，
# 或页面加载报错）。这里把旧目录移到备份、旧条目从 publish.xml 摘掉。
# 这个字面量是**兼容常量**，仅用于识别并清理旧版残留，不是界面文案。
LEGACY_ADDON_ID="claude-assistant"
if [ -e "${JSDADDONS}/${LEGACY_ADDON_ID}_" ]; then
  BK="${JSDADDONS}/${LEGACY_ADDON_ID}_.bak.$(date +%Y%m%d%H%M%S)"
  run "mv '${JSDADDONS}/${LEGACY_ADDON_ID}_' '$BK'"
  say "清理旧版加载项目录，已移到: $BK"
fi

if [ -e "${JSDADDONS}/${ADDON_DIR_NAME}" ]; then
  BK="${JSDADDONS}/${ADDON_DIR_NAME}.bak.$(date +%Y%m%d%H%M%S)"
  run "mv '${JSDADDONS}/${ADDON_DIR_NAME}' '$BK'"
  say "已有同名加载项，已移到: $BK"
fi
run "cp -a '${PKG_ROOT}/wps-assistant' '${JSDADDONS}/${ADDON_DIR_NAME}'"

if [ -f "$PUBLISH_XML" ]; then
  run "cp -a '$PUBLISH_XML' '${PUBLISH_XML}.bak.$(date +%Y%m%d%H%M%S)'"
  say "已备份原有 publish.xml"
fi

if [ -n "$PY" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] 合并注册项到 %s\n' "$PUBLISH_XML"
  else
    "$PY" - "$PUBLISH_XML" "$ADDON_NAME" "$ADDON_DIR_NAME" <<'PYEOF'
import os, sys
import xml.etree.ElementTree as ET

path, name, dir_name = sys.argv[1], sys.argv[2], sys.argv[3]

if os.path.exists(path):
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        # 原文件不合法：整体备份后重建，绝不静默丢弃
        import shutil, time
        bk = path + ".corrupt." + time.strftime("%Y%m%d%H%M%S")
        shutil.copy2(path, bk)
        print("  原 publish.xml 解析失败，已备份到 %s 并重建" % bk)
        root = ET.Element("jsplugins")
else:
    root = ET.Element("jsplugins")

# 幂等 + 不覆盖他人条目：摘掉同名条目，以及旧品牌版本残留的那一条。
# （旧 ID 只在升级路径上出现；不清理会导致功能区出现重复页签）
LEGACY = "claude-assistant"
for n in list(root):
    if n.get("name") == name:
        root.remove(n)
    elif n.get("name") == LEGACY:
        root.remove(n)
        print("  已移除旧版注册项: %s（兼容清理）" % LEGACY)

el = ET.SubElement(root, "jsplugin")
el.set("name", name)
el.set("type", "wps,et,wpp")
el.set("url", dir_name + "/")        # 相对 jsaddons 目录，离线可用
el.set("enable", "enable_dev")

out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>', "<jsplugins>"]
for n in root:
    a = " ".join('%s="%s"' % (k, v) for k, v in n.attrib.items())
    out.append("  <%s %s/>" % (n.tag, a))
out.append("</jsplugins>")

with open(path, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(out) + "\n")
print("  已合并，当前共 %d 条加载项" % len(list(root)))
PYEOF
  fi
else
  warn "无 python，跳过自动合并。请手工确保 publish.xml 含："
  warn "  <jsplugin name=\"${ADDON_NAME}\" type=\"wps,et,wpp\" url=\"${ADDON_DIR_NAME}/\" enable=\"enable_dev\"/>"
fi

if [ -n "$QUICKSTART" ]; then
  run "'$QUICKSTART' restart || true"
  say "已重启 WPS 服务"
else
  say "请手动完全退出 WPS 后重新打开"
fi

# ---------------------------------------------------------------- 收尾

head_ "5/5 MCP 注册信息"

cat <<DONE

  启动命令：
    ${NODE_BIN} ${PREFIX}/wps-office-mcp/dist/index.js

  Hermes 的 MCP 配置（加到 mcpServers 里）：
    {
      "wps-office": {
        "command": "${NODE_BIN}",
        "args": ["${PREFIX}/wps-office-mcp/dist/index.js"],
        "env": { "WPS_MCP_PORT": "58891" }
      }
    }

  注意：
    · 必须用 stdio 方式启动（上游用 StdioServerTransport）。
    · 端口 58891 只监听 127.0.0.1，不对外暴露。
    · 启动顺序：先起 Hermes（含 MCP），再开 WPS。
      反之在麒麟上有已知问题（上游 Issue #17：WPS 可能异常退出）。
    · 日志在 ~/.wps-office-mcp/logs/（combined.log / error.log）。

  验证：
    1. 重启 WPS，功能区应出现「${ADDON_TAB_LABEL}」
    2. curl -s http://127.0.0.1:58891/status   # 需 MCP 已被 Hermes 拉起
    3. 在 Hermes 里问「看看当前表格有哪些工作表」
DONE

#!/usr/bin/env bash
# 组装离线包（在联网机/CI 上跑，产出可直接拷进内网的 tar.gz）
#
# 产物：dist-pkg/wps-mcp-offline-<arch>.tar.gz
# 内容：
#   wps-office-mcp/dist/          编译产物
#   wps-office-mcp/node_modules/  生产依赖（--omit=dev，不含 jest/tsc）
#   wps-claude-assistant/         WPS 加载项
#   install.sh / README.md / SKILL.md
#
# 目标机不需要 npm、不需要外网、不需要图形会话。

set -euo pipefail

PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${PKG_ROOT}/.stage"
OUT="${PKG_ROOT}/dist-pkg"
ARCH="$(uname -m)"

say()  { printf '  %s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }

head_ "清理"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT"

head_ "复制编译产物"
[ -d "${PKG_ROOT}/wps-office-mcp/dist" ] || { echo "错误：dist 不存在，先跑 tsc" >&2; exit 1; }
mkdir -p "${STAGE}/wps-office-mcp"
cp -a "${PKG_ROOT}/wps-office-mcp/dist" "${STAGE}/wps-office-mcp/"
cp -a "${PKG_ROOT}/wps-office-mcp/package.json" "${STAGE}/wps-office-mcp/"
cp -a "${PKG_ROOT}/wps-office-mcp/package-lock.json" "${STAGE}/wps-office-mcp/"
say "dist: $(find "${STAGE}/wps-office-mcp/dist" -name '*.js' | wc -l) 个 .js"

head_ "安装生产依赖（--omit=dev）"
# 用独立 prefix 装，避免污染工作区 node_modules
npm ci --omit=dev --no-audit --no-fund \
  --prefix "${STAGE}/wps-office-mcp" \
  --loglevel=error
say "node_modules: $(du -sh "${STAGE}/wps-office-mcp/node_modules" | cut -f1)"

head_ "清理悬空 bin 链接"
# npm 的 .bin/* 是指向包内可执行文件的符号链接。--omit=dev 之后，
# 有些包（如 jest 链上的 which）不在了，但 .bin 里的链接还留着 -> 悬空。
# 处理原则：只清「所属包整个不在了」的链接；若包还在而文件缺失，说明包坏了，直接失败。
python3 - "$STAGE" <<'PYEOF'
import os
import sys

root = sys.argv[1]
removed, broken = [], []

for dirpath, dirnames, filenames in os.walk(root):
    for name in list(dirnames) + filenames:
        p = os.path.join(dirpath, name)
        if not os.path.islink(p) or os.path.exists(p):
            continue
        target = os.path.normpath(os.path.join(dirpath, os.readlink(p)))
        rel = os.path.relpath(target, root).replace(os.sep, "/")
        parts = rel.split("/")
        pkg = None
        if "node_modules" in parts:
            i = len(parts) - 1 - parts[::-1].index("node_modules")
            seg = parts[i + 1]
            if seg.startswith("@"):
                pkg = os.path.join(root, *parts[: i + 1], seg, parts[i + 2])
            else:
                pkg = os.path.join(root, *parts[: i + 1], seg)
        if pkg and not os.path.exists(pkg):
            os.unlink(p)
            removed.append((os.path.relpath(p, root), rel))
        else:
            broken.append((os.path.relpath(p, root), rel))

for p, t in removed:
    print("  移除悬空链接（所属包不在生产依赖树中）: %s -> %s" % (p, t))
for p, t in broken:
    print("  悬空链接（所属包仍在，包内容不完整）: %s -> %s" % (p, t))
print("  小计: 移除 %d 个，异常 %d 个" % (len(removed), len(broken)))
sys.exit(1 if broken else 0)
PYEOF

head_ "复制加载项与文档"
cp -a "${PKG_ROOT}/wps-claude-assistant" "${STAGE}/"
cp -a "${PKG_ROOT}/install.sh" "${STAGE}/"
[ -f "${PKG_ROOT}/README.md" ] && cp -a "${PKG_ROOT}/README.md" "${STAGE}/"
[ -f "${PKG_ROOT}/SKILL.md" ] && cp -a "${PKG_ROOT}/SKILL.md" "${STAGE}/"
say "加载项: $(find "${STAGE}/wps-claude-assistant" -type f | wc -l) 个文件"

head_ "写版本信息"
GIT_SHA="$(git -C "$PKG_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
NODE_VER="$(node -v 2>/dev/null || echo unknown)"
cat > "${STAGE}/build-info.json" <<EOF
{
  "package": "hermes-wps-mcp",
  "arch": "${ARCH}",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "git_sha": "${GIT_SHA}",
  "node": "${NODE_VER}",
  "upstream": "lc2panda/wps-skills"
}
EOF
cat "${STAGE}/build-info.json"

head_ "生成 MANIFEST"
# 顺序很重要：链接清单必须先写在 MANIFEST.tsv 之前生成，
# 否则 MANIFEST.tsv 自己不会把 MANIFEST.links.tsv 登记进去（它还不存在），
# 校验侧就会报「清单漏登记」。
# MANIFEST.tsv 自身在生成中，用 -not -name 排除，校验侧对此有豁免。
(
  cd "$STAGE"
  find . -type l -printf 'LINK\t%p\t%l\n' | LC_ALL=C sort -k2 > "${STAGE}/MANIFEST.links.tsv"
  find . -type f -not -name 'MANIFEST.tsv' -printf '%s\t%p\n' | LC_ALL=C sort -k2 > "${STAGE}/MANIFEST.tsv"
)
say "普通文件: $(wc -l < "${STAGE}/MANIFEST.tsv")"
say "符号链接: $(wc -l < "${STAGE}/MANIFEST.links.tsv")"

TARBALL="${OUT}/wps-mcp-offline-${ARCH}.tar.gz"
head_ "打包"
# --sort=name + 固定 mtime，保证同样输入产出同样 sha256（便于校验）
tar --sort=name \
    --mtime='UTC 2026-01-01' \
    --owner=0 --group=0 --numeric-owner \
    -czf "$TARBALL" -C "$STAGE" .
say "产物: $TARBALL"
say "体积: $(du -h "$TARBALL" | cut -f1)"
sha256sum "$TARBALL" | tee "${TARBALL}.sha256"

rm -rf "$STAGE"

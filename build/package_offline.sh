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
# 只登记普通文件；符号链接另记（npm 的 .bin/* 是 symlink）
(
  cd "$STAGE"
  find . -type f -printf '%s\t%p\n' | LC_ALL=C sort -k2 > "${STAGE}/MANIFEST.tsv"
  find . -type l -printf 'LINK\t%p\t%l\n' | LC_ALL=C sort -k2 > "${STAGE}/MANIFEST.links.tsv"
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

#!/usr/bin/env bash
# 构建原生 QPKG 产物:双架构静态二进制 + 前端 dist,落入 qpkg/(打包目录)。
#
# 产物(均被 gitignore,scripts/build-qpkg.sh 前必须先跑本脚本):
#   qpkg/x86_64/bin/pigeonbox-linux-amd64
#   qpkg/arm_64/bin/pigeonbox-linux-arm64
#   qpkg/shared/www/            (前端构建产物,QDK shared 段→包根 www/)
#
# 前端来源(2026-10-09 前端拆仓:web 适配器+构建自包含在本仓 web/,与 fnos 同模式):
#   1. FRONTEND_DIST 环境变量指定的现成 dist 目录(直接拷贝,跳过构建)
#   2. 本仓 web/(QTS 宿主适配器+@pigeonbox/frontend-core tgz 钉版,见 web/package.json)
# 不再克隆 frontend 仓——QPKG web 内容随本仓提交可复现;类型检查由本仓 CI 把守。
#
# 版本注入:VERSION/COMMIT 环境变量优先,缺省取 git describe/rev-parse
# (kit/version 包变量,App Center「关于」与运行日志可见)。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QPKG_DIR="$ROOT/qpkg"

VERSION=${VERSION:-"$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo dev)"}
COMMIT=${COMMIT:-"$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"}
BUILD_TIME=${BUILD_TIME:-"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
LDFLAGS="-w -s -X 'github.com/pigeonbox/kit/version.Version=${VERSION}' -X 'github.com/pigeonbox/kit/version.BuildCommit=${COMMIT}' -X 'github.com/pigeonbox/kit/version.BuildTime=${BUILD_TIME}'"

echo "==> 构建原生二进制 (CGO_ENABLED=0 静态链接,纯 Go sqlite)"
for goarch in amd64 arm64; do
  case "${goarch}" in
    amd64) qarch=x86_64 ;;
    arm64) qarch=arm_64 ;;
  esac
  echo "    GOOS=linux GOARCH=${goarch} → qpkg/${qarch}/bin/"
  mkdir -p "$QPKG_DIR/${qarch}/bin"
  # GOWORK=off:保证构建严格按 go.mod 钉版(否则 hub go.work 联编本地 core main,
  # 产物含未发布代码且不可复现——真机修复到位性依赖钉版;fnos v1.14.3 首包踩坑)。
  CGO_ENABLED=0 GOWORK=off GOOS=linux GOARCH=${goarch} \
    go build -C "$ROOT" -ldflags="${LDFLAGS}" \
    -o "$QPKG_DIR/${qarch}/bin/pigeonbox-linux-${goarch}" ./cmd/pigeonbox
done

echo "==> 构建前端 dist → $QPKG_DIR/shared/www"
rm -rf "$QPKG_DIR/shared/www"
if [ -n "${FRONTEND_DIST:-}" ]; then
  cp -R "${FRONTEND_DIST}/." "$QPKG_DIR/shared/www"
  echo "    使用现成 dist: $FRONTEND_DIST"
else
  SRC="$ROOT/web"
  cd "$SRC"
  [ -d node_modules ] || npm ci --no-audit --no-fund
  # APP_VERSION=页脚「前端版本」(缺省=web/package.json version,与
  # frontend-core tgz 钉版同步;可由构建环境覆盖)
  APP_VERSION="${APP_VERSION:-$(node -p "require('./package.json').version")}" \
    npx vite build --outDir "$QPKG_DIR/shared/www" --emptyOutDir
fi

echo "==> 完成"
ls -lh "$QPKG_DIR"/*/bin/
du -sh "$QPKG_DIR/shared/www"

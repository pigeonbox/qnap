#!/usr/bin/env bash
# 构建原生 QPKG 产物:双架构静态二进制 + 前端 dist,落入 qpkg/(打包目录)。
#
# 产物(均被 gitignore,scripts/build-qpkg.sh 前必须先跑本脚本):
#   qpkg/x86_64/bin/pigeonbox-linux-amd64
#   qpkg/arm_64/bin/pigeonbox-linux-arm64
#   qpkg/shared/www/            (前端构建产物,QDK shared 段→包根 www/)
#
# 前端来源优先级(与 fnos/openwrt 同策略):
#   1. FRONTEND_DIST 环境变量指定的现成 dist 目录
#   2. 工作区已检出的 frontend 仓(../../frontend,hub make setup 布局)
#   3. 临时克隆 pigeonbox/frontend <FRONTEND_REF,默认 main>
# 只跑 vite build(类型检查由 frontend 仓 CI 独立把守);wire 类型依赖
# @pigeonbox/contracts 的 Release tgz 资产(匿名可下)。
#
# 版本注入:VERSION/COMMIT 环境变量优先,缺省取 git describe/rev-parse
# (kit/version 包变量,App Center「关于」与运行日志可见)。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QPKG_DIR="$ROOT/qpkg"
FRONTEND_REF=${FRONTEND_REF:-main}

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
SRC="${FRONTEND_DIST:-}"
CLEANUP_SRC=""
if [ -z "$SRC" ]; then
  # 工作区布局:hub(PigeonBox/)内 qnap/ 与 frontend/ 同级——探测 ../frontend。
  # (fnos build-native.sh 同款修复:此前多一级 ../../frontend 静默克隆远端,
  #  本地壳仓改动/fnos 融合前端不进包,qnap flavor 亦然)
  if [ -f "$ROOT/../frontend/package.json" ]; then
    SRC="$(cd "$ROOT/../frontend" && pwd)"
    echo "    使用工作区 frontend: $SRC"
  else
    SRC="$(mktemp -d)/frontend"
    CLEANUP_SRC="$SRC"
    echo "    克隆 frontend@$FRONTEND_REF"
    git clone -q --depth 1 -b "$FRONTEND_REF" \
      "https://github.com/pigeonbox/frontend.git" "$SRC"
  fi
fi
trap '[ -n "${CLEANUP_SRC:-}" ] && rm -rf "$(dirname "$CLEANUP_SRC")"' EXIT

cd "$SRC"
[ -d node_modules ] || npm ci --no-audit --no-fund
# 必须用 build:qnap flavor(注入 QNAP 宿主适配器:SSO 静默登录等);
# 默认 vite.config.ts 是 neutral flavor(零平台代码),QPKG 不用。
# (对齐 fnos 的 build-native.sh 用 vite.fnos.config.ts 的同款约束)
npx vite build --config vite.qnap.config.ts --outDir "$QPKG_DIR/shared/www" --emptyOutDir

echo "==> 完成"
ls -lh "$QPKG_DIR"/*/bin/
du -sh "$QPKG_DIR/shared/www"

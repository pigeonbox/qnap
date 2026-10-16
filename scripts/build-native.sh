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
LDFLAGS="-w -s -X 'github.com/oekit/core/version.Version=${VERSION}' -X 'github.com/oekit/core/version.BuildCommit=${COMMIT}' -X 'github.com/oekit/core/version.BuildTime=${BUILD_TIME}'"

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

# ── 随包 p2pc 设备直传(2026-10-14 对称节点 P2b) ──────────────────
# 版本=DEPS.env P2PC_REF(发布列车写 lib.p2p;缺省跳过=直传不可用优雅降级)。
# 下载顺序 curl → gh release download(本机 github 直连被断时兜底);
# checksums.txt 侧车强制校验。
fetch_p2pc() {
  local ref="$1" dest="$2" triple="$3"
  local asset="p2pc-${triple}" base="https://github.com/pigeonbox/p2p/releases/download/${ref}"
  local tmp; tmp="$(mktemp -d)"
  local ok=""
  if curl -fsSL -m 60 -o "$tmp/checksums.txt" "${base}/p2pc-checksums.txt" 2>/dev/null \
     && curl -fsSL -m 300 -o "$tmp/${asset}" "${base}/${asset}" 2>/dev/null; then
    ok=1
  elif command -v gh >/dev/null 2>&1; then
    gh release download "$ref" -R pigeonbox/p2p -p "${asset}" -O "$tmp/${asset}" --clobber \
      && gh release download "$ref" -R pigeonbox/p2p -p p2pc-checksums.txt -O "$tmp/checksums.txt" --clobber \
      && ok=1
  fi
  if [ -z "$ok" ]; then
    echo "✗ p2pc ${asset}@${ref} 下载失败(curl/gh 均不可用或失败)"; rm -rf "$tmp"; return 1
  fi
  if ! (cd "$tmp" && grep " ${asset}\$" checksums.txt | shasum -a 256 -c - >/dev/null); then
    echo "✗ p2pc ${asset}@${ref} sha256 校验失败"; rm -rf "$tmp"; return 1
  fi
  install -m 0755 "$tmp/${asset}" "$dest"
  rm -rf "$tmp"
  echo "    ✓ p2pc ${triple} @ ${ref}"
}

echo "==> 随包 p2pc(设备直传)"
P2PC_REF=$(sed -n 's/^P2PC_REF=//p' "$ROOT/DEPS.env" | tr -d ' \r')
if [ -n "$P2PC_REF" ]; then
  for goarch in amd64 arm64; do
    case "$goarch" in
      amd64) qarch=x86_64; triple=x86_64-unknown-linux-gnu ;;
      arm64) qarch=arm_64; triple=aarch64-unknown-linux-gnu ;;
    esac
    mkdir -p "$QPKG_DIR/${qarch}/bin"
    fetch_p2pc "$P2PC_REF" "$QPKG_DIR/${qarch}/bin/p2pc-linux-${goarch}" "$triple"
  done
else
  echo "    (DEPS.env 无 P2PC_REF,跳过——包内直传不可用,优雅降级)"
fi

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


# ── 版本戳自证(2026-10-12 版本幽灵根治) ──────────────────────────
# web 版本单一来源 = APP_VERSION 环境变量 / web/package.json;构建即写
# version.txt 并断言 dist 内戳一致,不一致=构建红。运维验收一条
# curl -s <host>/version.txt 即可验真,永别「页脚是几」猜谜与缓存伪影。
WEB_VERSION="${APP_VERSION:-$(node -p "require('$ROOT/web/package.json').version")}"
printf '%s\n' "$WEB_VERSION" > "$QPKG_DIR/shared/www/version.txt"
grep -rqF "$WEB_VERSION" "$QPKG_DIR/shared/www/assets" 2>/dev/null || { echo "✗ dist 未发现版本戳 $WEB_VERSION(__APP_VERSION__ 注入失效?)"; exit 1; }
echo "    版本自证 ✓ version.txt=$WEB_VERSION 与 dist 戳一致"
echo "==> 完成"
ls -lh "$QPKG_DIR"/*/bin/
du -sh "$QPKG_DIR/shared/www"

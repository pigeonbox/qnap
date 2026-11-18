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

# ── shellkit（编译侧统一管道；**设备侧脚本一律不引**，见 C1） ───────────────
# third_party/shellkit 是上游镜像（由 hub 侧 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**。
# ⚠️ 落点是 third_party/ 而不是 vendor/：Go ≥1.14 见到**模块根**下有 vendor/ 就默认切
#    vendor 模式 ⇒ 缺 vendor/modules.txt ⇒ go build 报 "inconsistent vendoring"（实测现红）。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090,SC1091  # 副本路径含变量 ⇒ shellcheck 静态跟不进去
. "$REPO_ROOT/third_party/shellkit/lib/bootstrap.sh"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}" # 库内消息走中文,与生态输出一致

QPKG_DIR="$REPO_ROOT/qpkg"

# ⚠️ 版本戳取自 git(describe/rev-parse)**保留手写**：shellkit 没有 git 抽象；
#   且「浅克隆无 tag ⇒ describe 退化成哈希」这类教训是本仓专属(E2)。
VERSION=${VERSION:-"$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || echo dev)"}
COMMIT=${COMMIT:-"$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"}
BUILD_TIME=${BUILD_TIME:-"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
LDFLAGS="-w -s -X 'github.com/oekit/core/version.Version=${VERSION}' -X 'github.com/oekit/core/version.BuildCommit=${COMMIT}' -X 'github.com/oekit/core/version.BuildTime=${BUILD_TIME}'"

log_section "构建原生二进制 (CGO_ENABLED=0 静态链接,纯 Go sqlite)"
for goarch in amd64 arm64; do
  case "${goarch}" in
    amd64) qarch=x86_64 ;;
    arm64) qarch=arm_64 ;;
  esac
  log_info "GOOS=linux GOARCH=${goarch} → qpkg/${qarch}/bin/"
  fs_ensure_dir "$QPKG_DIR/${qarch}/bin"
  # GOWORK=off:保证构建严格按 go.mod 钉版(否则 hub go.work 联编本地 core main,
  # 产物含未发布代码且不可复现——真机修复到位性依赖钉版;fnos v1.14.3 首包踩坑)。
  CGO_ENABLED=0 GOWORK=off GOOS=linux GOARCH=${goarch} \
    go build -C "$REPO_ROOT" -ldflags="${LDFLAGS}" \
    -o "$QPKG_DIR/${qarch}/bin/pigeonbox-linux-${goarch}" ./cmd/pigeonbox
done

# ── 随包 p2pc/p2pcweb 设备直传(P2b;A2 起含网页客户端) ──────────────────
# 版本=DEPS.env P2PC_REF(列车写 terminal.p2pc_ref;缺省跳过=直传不可用优雅降级)。
# 下载顺序 curl → gh release download(本机 github 直连被断时兜底);
# checksums.txt 侧车强制校验。
#
# ⚠️ DEPS.env 的 P2PC_REF 解析**保留手写** sed：shellkit 的 conf_get_any 取值序是
#   「环境变量 > 配置层 > 配置文件」⇒ 外部环境变量会悄悄改掉钉版 ⇒ 语义会变(C2)。
fetch_p2pc() {
  local ref="$1" dest="$2" triple="$3" prefix="$4"
  local asset="${prefix}-${triple}" base="https://github.com/pigeonbox/p2p/releases/download/${ref}"
  local tmp sha rc
  tmp="$(mktemp -d)"
  # ① checksums.txt 侧车(期望哈希的唯一来源):curl 优先,不通则 gh 兜底
  #    (原脚本是「curl 两个文件 → 失败再 gh 两个文件」的同一条兜底链)。
  if ! net_download "${base}/p2pc-checksums.txt" "${tmp}/checksums.txt"; then
    if ! command -v gh >/dev/null 2>&1 ||
      ! gh release download "$ref" -R pigeonbox/p2p -p p2pc-checksums.txt -O "${tmp}/checksums.txt" --clobber; then
      log_error "${asset}@${ref} 下载失败(curl/gh 均不可用或失败)"
      rm -rf "$tmp"
      return 1
    fi
  fi
  # ② 期望哈希:从侧车里取该资产的 sha256。
  #   口径与原脚本的 grep " ${asset}\$" checksums.txt | shasum -a 256 -c - 对齐:
  #   只认「**空格 + 资产名结尾**」的行(二进制模式的 *${asset} 不匹配,与原脚本同);
  #   这里用字面比较而不是正则 ⇒ 资产名里的正则元字符不会误伤。
  sha="$(_sha_of "${tmp}/checksums.txt" "$asset")"
  if [ -z "$sha" ]; then
    # ⚠️ 原脚本在资产**不在**侧车里时:grep 空输入 ⇒ shasum -a 256 -c - 报
    #   "no properly formatted SHA checksum lines found" ⇒ rc=1 ⇒ **判红**。
    #   ⇒ 这里保持 **fail-closed**(不静默放行无校验和的产物)。
    log_error "${asset}@${ref} 不在 p2pc-checksums.txt 里 ⇒ 拒绝安装(缺校验和)"
    rm -rf "$tmp"
    return 1
  fi
  # ③ 下载资产并校验(net_download 内建 sha256 比对,不匹配返回 SK_VERIFY=5)。
  #   ⚠️ **gh 兜底链保留**:shellkit 的 net_download 只认 curl/wget ⇒ gh 分支仍要手写。
  #   ⚠️ 校验不匹配时**不兜底**:原脚本「下载成功但校验失败 ⇒ 直接判红」,
  #   同一个 Release 换条路下到的还是同一个坏文件。
  rc=0
  if net_download "${base}/${asset}" "${tmp}/${asset}" "$sha"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -ne "$SK_VERIFY" ] && command -v gh >/dev/null 2>&1; then
      if gh release download "$ref" -R pigeonbox/p2p -p "${asset}" -O "${tmp}/${asset}" --clobber; then
        if net_verify "${tmp}/${asset}" "$sha"; then
          rc=0
        else
          rc=$SK_VERIFY
        fi
      else
        rc=1
      fi
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq "$SK_VERIFY" ]; then
      log_error "${asset}@${ref} sha256 校验失败"
    else
      log_error "${asset}@${ref} 下载失败(curl/gh 均不可用或失败)"
    fi
    rm -rf "$tmp"
    return 1
  fi
  install -m 0755 "${tmp}/${asset}" "$dest"
  rm -rf "$tmp"
  log_ok "${prefix} ${triple} @ ${ref}"
}

# 从 checksums 文件取某资产的 sha256(stdout;找不到 ⇒ 空串)。
_sha_of() { # <checksums 文件> <资产名>
  awk -v n=" $2" 'length($0) >= length(n) && substr($0, length($0) - length(n) + 1) == n { print $1; exit }' "$1"
}

log_section "随包 p2pc/p2pcweb(设备直传+网页客户端)"
P2PC_REF=$(sed -n 's/^P2PC_REF=//p' "$REPO_ROOT/DEPS.env" | tr -d ' \r')
if [ -n "$P2PC_REF" ]; then
  for goarch in amd64 arm64; do
    case "${goarch}" in
      amd64)
        qarch=x86_64
        triple=x86_64-unknown-linux-gnu
        ;;
      arm64)
        qarch=arm_64
        triple=aarch64-unknown-linux-gnu
        ;;
    esac
    fs_ensure_dir "$QPKG_DIR/${qarch}/bin"
    fetch_p2pc "$P2PC_REF" "$QPKG_DIR/${qarch}/bin/p2pc-linux-${goarch}" "$triple" p2pc
    fetch_p2pc "$P2PC_REF" "$QPKG_DIR/${qarch}/bin/p2pcweb-linux-${goarch}" "$triple" p2pc-web
  done
else
  log_info "(DEPS.env 无 P2PC_REF,跳过——包内直传不可用,优雅降级)"
fi

# ── 随包 pb CLI(官方命令行客户端:doctor 部署自检等)────────────────────
#
# # 为什么从**源码**编译而不是下载 server Release 的二进制资产
#
# qnap 与 server 的 Release 由**同号 tag 同时触发** ⇒ 若这里去下载 server
# Release 的 pb_linux_amd64 资产,就会与 server 的 Release 流水线**竞态**
# (资产还没构建完就下载 ⇒ 拿不到 ⇒ qpkg 构建失败)。
# ⇒ 改为**检出 server 同号 tag 的源码**本地编译 ⇒ **git tag 立即可见**
# (不需要等任何流水线)⇒ 零竞态。
#
# # 为什么 pb 适合这么干
#
# cmd/pb 是**纯 HTTP 客户端**:不链接 core(只用 oekit/pkg/cli)⇒
# 依赖极小(实测 199 个包 / 编译 3.5 秒 / 产物 6.5MB)⇒ 不拖慢 qpkg 构建。
#
# # 版本对齐
#
# server 的 tag 与 qnap 的 tag **同号**(列车的 terminal.qnap.tag = images.server
# 的号,如都是 v4.6.1)⇒ pb 的版本天然与包内服务端一致 ⇒ 不需要额外版本位。
#
# # 失败怎么办
#
# 编译失败 ⇒ **优雅降级**(包内无 pb,应用照常可用)⇒ 不阻断 qpkg 发布。
# (与 p2pc「包内无此文件时优雅跳过」同款纪律。)
#
# ⚠️ server ref 取自**仓内 VERSION 文件**(列车写的真相源),不用 git describe:
#   CI 是浅克隆且无 tag ⇒ describe 退化成 commit 哈希 ⇒ 拼出的 "v<hash>"
#   在 GitHub 上不存在 ⇒ 检出必然失败(fnos#145 已在 CI 上踩过这个坑)。
PB_SERVER_REF="${PB_SERVER_REF:-}"
if [ -z "$PB_SERVER_REF" ]; then
  _pb_ver="$(tr -d " \r\n" <"$REPO_ROOT/VERSION" 2>/dev/null || true)"
  if [ -n "$_pb_ver" ]; then
    PB_SERVER_REF="v${_pb_ver}"
  else
    PB_SERVER_REF="v${VERSION}"
  fi
fi
log_section "构建 pb CLI(官方命令行客户端) server ref=${PB_SERVER_REF}"
PB_SRC=""
_pb_ok=1
for goarch in amd64 arm64; do
  case "${goarch}" in
    amd64) qarch=x86_64 ;;
    arm64) qarch=arm_64 ;;
  esac
  if [ -z "$PB_SRC" ]; then
    PB_SRC="$(mktemp -d)/server"
    log_info "检出 server ${PB_SERVER_REF} 源码"
    # 检出 server 同号 tag 的源码；失败则**退避重试**——
    # server 的 tag 可能比本仓的 tag 晚几秒可见（两仓 tag 由列车分批推送：
    # frontend → server → 各终端）⇒ 重试即可覆盖这个窗口。
    #
    # 失败模式是**静默降级**（检出失败 ⇒ 不带 pb ⇒ 应用照常可用 ⇒ 只有门禁会发现）
    # ⇒ 没有重试就意味着「这一趟车的包没有 pb」。
    #
    # ⚠️ 手写重试循环 ⇒ shellkit retry;退避参数**钉死**
    #   (SHELLKIT_RETRY_DELAY=3 / BACKOFF=1 / MAX_DELAY=3)⇒ 与原
    #   「最多 10 次、间隔恒 3s」等价(不钉死则默认 1s、2 倍退避 ⇒ 不等价)。
    # ⚠️ clone 的 2>/dev/null 收进 _pb_clone 函数(原样保留)⇒
    #   免得把 shellkit 的重试告警一起吞掉。
    _pb_clone() {
      git clone -q --depth 1 --branch "$PB_SERVER_REF" \
        https://github.com/pigeonbox/server.git "$PB_SRC" 2>/dev/null
    }
    if ! SHELLKIT_RETRY_DELAY=3 SHELLKIT_RETRY_BACKOFF=1 SHELLKIT_RETRY_MAX_DELAY=3 \
      retry 10 _pb_clone; then
      log_error "server ${PB_SERVER_REF} 源码检出失败——pb 优雅降级(包内无 pb)"
      _pb_ok=0
      break
    fi
    if [ ! -d "$PB_SRC/.git" ]; then
      log_error "server ${PB_SERVER_REF} 源码检出失败——pb 优雅降级(包内无 pb)"
      _pb_ok=0
      break
    fi
  fi
  log_info "GOOS=linux GOARCH=${goarch}"
  if ! (cd "$PB_SRC" && CGO_ENABLED=0 GOWORK=off GOOS=linux GOARCH="${goarch}" \
    go build -trimpath -ldflags="-w -s" \
    -o "$QPKG_DIR/${qarch}/bin/pb-linux-${goarch}" ./cmd/pb) 2>/dev/null; then
    log_error "pb(${goarch}) 编译失败——该架构无 pb(其余架构照常)"
    rm -f "$QPKG_DIR/${qarch}/bin/pb-linux-${goarch}" 2>/dev/null || true
    continue
  fi
  log_ok "pb-linux-${goarch} ($(du -h "$QPKG_DIR/${qarch}/bin/pb-linux-${goarch}" | cut -f1))"
done
# ⚠️ 只有**两个架构都没成**时才判整体降级;单个架构失败不牵连另一个
#   (NAS 上 x86_64 与 arm64 各占一半,删掉能用的那个等于半数用户拿不到 pb)。
if [ "$_pb_ok" = "1" ] && ! ls "$QPKG_DIR"/*/bin/pb-linux-* >/dev/null 2>&1; then
  log_error "pb 两个架构均不可用——优雅降级(包内无 pb,应用照常)"
fi
if [ -n "$PB_SRC" ]; then
  rm -rf "$(dirname "$PB_SRC")" 2>/dev/null || true
fi

# ── 安装完整性自检清单(2026-10-22 真机事故固化) ──────────────────────
# QDK 的 dd|tar 解包在写**最后一个文件**时可能断流(安装包被截断/传输中断),
# 产出「看起来装上了、实则二进制被截断」的半拉子安装——本次事故:p2pcweb
# 截到 62%(9994402→6218752 字节),p2pc/pigeonbox 两个校验和完全正常,
# 症状却是 p2pcweb 段错误 + 看门狗每 30s 重拉的崩溃循环。
# 这里在打包期产出 bin/SHA256SUMS,安装后由 package_routines 的 pkg_post_install
# 逐个校验:不符即**中止安装**,让用户看到明确失败,而不是几天后的一段段错误。
log_section "生成 bin/SHA256SUMS(安装后完整性自检清单)"
for qarch in x86_64 arm_64; do
  _bindir="$QPKG_DIR/${qarch}/bin"
  [ -d "$_bindir" ] || continue
  (cd "$_bindir" && rm -f SHA256SUMS && sha256sum ./* >SHA256SUMS)
  log_ok "${qarch}/bin/SHA256SUMS"
done

log_section "构建前端 dist → $QPKG_DIR/shared/www"
rm -rf "$QPKG_DIR/shared/www"
if [ -n "${FRONTEND_DIST:-}" ]; then
  cp -R "${FRONTEND_DIST}/." "$QPKG_DIR/shared/www"
  log_info "使用现成 dist: $FRONTEND_DIST"
else
  SRC="$REPO_ROOT/web"
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
WEB_VERSION="${APP_VERSION:-$(node -p "require('$REPO_ROOT/web/package.json').version")}"
printf '%s\n' "$WEB_VERSION" >"$QPKG_DIR/shared/www/version.txt"
grep -rqF "$WEB_VERSION" "$QPKG_DIR/shared/www/assets" 2>/dev/null ||
  die 1 "dist 未发现版本戳 $WEB_VERSION(__APP_VERSION__ 注入失效?)"
log_ok "版本自证 ✓ version.txt=$WEB_VERSION 与 dist 戳一致"
log_section "完成"
ls -lh "$QPKG_DIR"/*/bin/
du -sh "$QPKG_DIR/shared/www"

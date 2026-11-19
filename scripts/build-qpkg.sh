#!/usr/bin/env bash
# 组装 PigeonBox 威联通 QPKG(依赖 QDK 官方打包器 qbuild)。
#
# .qpkg 不是普通 tar:它是"自解压 shell 脚本 + control.tar + data.tar.gz(+QDK 尾区)"
# 的自解压结构,必须用 qbuild 组包——纯 tar.gz 改名 .qpkg 不会被 App Center 安装。
# QDK 安装(Ubuntu): git clone https://github.com/qnap-dev/QDK && cd QDK && sudo ./InstallToUbuntu.sh install
#
# 前置:先跑 ./scripts/build-native.sh(双架构静态二进制 + 前端 www 落入 qpkg/)。
#
# 用法: ./scripts/build-qpkg.sh [arch] [版本]    arch ∈ x86_64 | arm_64
#   例: ./scripts/build-qpkg.sh x86_64 0.1.0     → dist/PigeonBox_0.1.0_x86_64.qpkg(.md5)
set -euo pipefail

# ── shellkit（编译侧统一管道；**设备侧脚本一律不引**，见 C1） ───────────────
# third_party/shellkit 是上游镜像（由 hub 侧 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**。
# ⚠️ 落点是 third_party/ 而不是 vendor/：Go ≥1.14 见到**模块根**下有 vendor/ 就默认切
#    vendor 模式 ⇒ 缺 vendor/modules.txt ⇒ go build 报 "inconsistent vendoring"（实测现红）。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090,SC1091  # 副本路径含变量 ⇒ shellcheck 静态跟不进去
. "$REPO_ROOT/third_party/shellkit/lib/bootstrap.sh"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}" # 库内消息走中文,与生态输出一致

cd "$REPO_ROOT"

# ⚠️ ${1:?...} 的用法校验**保留手写**：本脚本 set -euo pipefail ⇒ 缺参时 bash 以 **1** 退出；
#   若换成 shellkit 的 die 2(用法错)⇒ 退出码变成 2 ⇒ 违反 C3(退出码是对外契约)。
#   ⇒ 只把文案里的尖括号改成方括号：尖括号会被 bash 当**重定向**解析
#      (文案里带括号时会被吞成 "<构建号/dev/fd/63" 并多出 "例:: command not found" 噪音)。
ARCH="${1:?用法: build-qpkg.sh [x86_64|arm_64] [版本]}"
VERSION="${2:?缺少版本号}"
case "$ARCH" in
  x86_64) GOARCH=amd64 ;;
  arm_64) GOARCH=arm64 ;;
  *) die 1 "arch 须为 x86_64 或 arm_64" ;;
esac

# 原生产物前置检查(漏跑 build-native.sh 时给出明确指引,而非 qbuild 深处报错)
BIN="qpkg/${ARCH}/bin/pigeonbox-linux-${GOARCH}"
[ -f "$BIN" ] || die 1 "缺 ${BIN}:先跑 ./scripts/build-native.sh"
[ -d "qpkg/shared/www" ] || die 1 "缺 qpkg/shared/www(前端):先跑 ./scripts/build-native.sh"

QBUILD="${QBUILD:-/usr/share/QDK/bin/qbuild}"
if [ ! -x "$QBUILD" ]; then
  die 1 "未找到 qbuild:先安装 QDK(git clone https://github.com/qnap-dev/QDK && cd QDK && sudo ./InstallToUbuntu.sh install)"
fi
# ⚠️ 这里**不用** require_cmd dos2unix：它的退出码是 3(前置条件不满足),
#   与原脚本的 exit 1 不一致 ⇒ 会改退出码(C3)。
command -v dos2unix >/dev/null 2>&1 || die 1 "需要 dos2unix: sudo apt-get install dos2unix"

# 清构建区保留 dist(多架构串行构建产物互不覆盖;CI 为矩阵隔离亦无碍)
rm -rf build
STAGE="build/stage"
fs_ensure_dir "$STAGE"
fs_ensure_dir "dist"
cp -R qpkg/. "$STAGE/"

# 版本注入(qpkg.cfg 模板占位 __VERSION__)+ CRLF 压平:
# CRLF 是 QPKG 官方承认的最大坑(qinstall/服务脚本带 \r 直接执行失败)
sed -i.bak "s/^QPKG_VER=.*/QPKG_VER=\"${VERSION}\"/" "$STAGE/qpkg.cfg" && rm -f "$STAGE/qpkg.cfg.bak"
# ⚠️ prewire_beam_box **没有 .sh 后缀** ⇒ 上面的 '*.sh' 匹配不到它
#   ⇒ 它从没被 dos2unix ⇒ 一旦带上 CRLF，设备上 shebang 直接失效（QPKG 官方承认的
#   最大坑：带 \r 直接执行失败）⇒ 它是要在设备上**执行**的脚本 ⇒ 显式点名。
find "$STAGE" -type f \( -name '*.sh' -o -name 'qpkg.cfg' -o -name 'package_routines' \
  -o -name '*.example' -o -name 'prewire_beam_box' \) -exec dos2unix -q {} +
# 设备侧 shellkit POSIX 子集（上游镜像，**勿手改**）必须进包：shared/ 被 QDK 平铺到
#   包根 ⇒ 装机后落在 ${QPKG_ROOT}/shellkit-posix.sh ⇒ 服务脚本与预接线脚本同目录找它
#   （服务脚本缺它 ⇒ fail-closed 退 5 ⇒ 装机即挂）⇒ 打包期就拦住漏装。
[ -f "$STAGE/shared/shellkit-posix.sh" ] || die 1 "缺 qpkg/shared/shellkit-posix.sh（设备侧 POSIX 子集）"
# 权限：**只给要执行的脚本 0755**。POSIX 子集是被 `.`（source）进来的**库** ⇒ 0644 即可
#   （原写法 `*.sh` 会把它也 chmod 成 0755；能跑、无害，但纯 POSIX 源码给执行位
#   没有语义 ⇒ 这里显式收窄）。prewire_beam_box 无 .sh 后缀 ⇒ 必须显式点名，
#   否则打包后不可执行 ⇒ 服务脚本的 `nohup "$_prewire_script"` 会 Permission denied。
chmod 0755 "$STAGE/shared/"*.sh "$STAGE/shared/prewire_beam_box" "$STAGE/${ARCH}/bin/"
chmod 0644 "$STAGE/shared/shellkit-posix.sh"

# ⚠️ qbuild 组包命令行**一字未改**(E5:包格式命令行,改错一行 = 包装不上)。
QBUILD_DIR="$(dirname "$QBUILD")"
export PATH="${QBUILD_DIR}:$PATH"
(cd "$STAGE" && qbuild --build-arch "$ARCH")

PKG="$(find "$STAGE/build" -name '*.qpkg' | head -n 1)"
[ -n "$PKG" ] || die 1 "qbuild 未产出 .qpkg"
mv "$PKG" dist/
# md5 侧车按最终文件名重新生成(qbuild 生成时引用的是 build/ 旧路径);
# 内容用裸文件名,校验时在 dist/ 内执行 md5sum -c。
# 注意取本次产物名而非 find dist——串行双架构构建时 dist 已有上一架构的包。
BASE="$(basename "$PKG")"
(cd dist && md5sum "$BASE" >"$BASE.md5")
log_ok "dist/${BASE}"

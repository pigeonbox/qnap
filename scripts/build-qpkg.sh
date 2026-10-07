#!/usr/bin/env bash
# 组装 PigeonBox 威联通 QPKG(依赖 QDK 官方打包器 qbuild)。
#
# .qpkg 不是普通 tar:它是"自解压 shell 脚本 + control.tar + data.tar.gz(+QDK 尾区)"
# 的自解压结构,必须用 qbuild 组包——纯 tar.gz 改名 .qpkg 不会被 App Center 安装。
# QDK 安装(Ubuntu): git clone https://github.com/qnap-dev/QDK && cd QDK && sudo ./InstallToUbuntu.sh install
#
# 用法: ./scripts/build-qpkg.sh <arch> <版本>    arch ∈ x86_64 | arm_64
#   例: ./scripts/build-qpkg.sh x86_64 0.1.0     → dist/PigeonBox_0.1.0_x86_64.qpkg(.md5)
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${1:?用法: build-qpkg.sh <x86_64|arm_64> <版本>}"
VERSION="${2:?缺少版本号}"
case "$ARCH" in
    x86_64 | arm_64) ;;
    *) echo "arch 须为 x86_64 或 arm_64" >&2; exit 1 ;;
esac

QBUILD="${QBUILD:-/usr/share/QDK/bin/qbuild}"
if [ ! -x "$QBUILD" ]; then
    echo "未找到 qbuild:先安装 QDK(git clone https://github.com/qnap-dev/QDK && cd QDK && sudo ./InstallToUbuntu.sh install)" >&2
    exit 1
fi
command -v dos2unix >/dev/null 2>&1 || { echo "需要 dos2unix: sudo apt-get install dos2unix" >&2; exit 1; }

# 清构建区保留 dist(多架构串行构建产物互不覆盖;CI 为矩阵隔离亦无碍)
rm -rf build
STAGE="build/stage"
mkdir -p "$STAGE" dist
cp -R qpkg/. "$STAGE/"

# 版本注入(qpkg.cfg 模板占位 __VERSION__)+ CRLF 压平:
# CRLF 是 QPKG 官方承认的最大坑(qinstall/服务脚本带 \r 直接执行失败)
sed -i.bak "s/^QPKG_VER=.*/QPKG_VER=\"${VERSION}\"/" "$STAGE/qpkg.cfg" && rm -f "$STAGE/qpkg.cfg.bak"
find "$STAGE" -type f \( -name '*.sh' -o -name 'qpkg.cfg' -o -name 'package_routines' \
    -o -name '*.yml' -o -name '*.example' \) -exec dos2unix -q {} +
chmod 0755 "$STAGE/shared/"*.sh

export PATH="$(dirname "$QBUILD"):$PATH"
(cd "$STAGE" && qbuild --build-arch "$ARCH")

PKG="$(find "$STAGE/build" -name '*.qpkg' | head -n 1)"
[ -n "$PKG" ] || { echo "qbuild 未产出 .qpkg" >&2; exit 1; }
mv "$PKG" dist/
# md5 侧车按最终文件名重新生成(qbuild 生成时引用的是 build/ 旧路径);
# 内容用裸文件名,校验时在 dist/ 内执行 md5sum -c
BASE="$(basename "$(find dist -name '*.qpkg' | head -n 1)")"
(cd dist && md5sum "$BASE" > "$BASE.md5")
echo "✓ dist/${BASE}"

#!/bin/sh
# QPKG 服务脚本与安装钩子 mock 冒烟测试(本地与 CI 同一套,无外部依赖):
#   伪造 getcfg/setcfg/docker/compose-wrapper 与卷路径,验证 start(后台引导/
#   图标端口同步)/status/stop/remove/启用开关与 package_routines 的 .env
#   生成、升级镜像版本对齐、卸载钩子字符串展开。
# 用法: tests/run-tests.sh
set -u
cd "$(dirname "$0")/.." || exit 1

FAIL=0
ok() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (期望 [$3] 实际 [$2])"; fi
}
assert_contains() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *) fail "$1 ([$2] 不含 [$3])" ;;
    esac
}
assert_not_contains() {
    case "$2" in
        *"$3"*) fail "$1 ([$2] 不应含 [$3])" ;;
        *) ok "$1" ;;
    esac
}
assert_count() {
    n=$(printf '%s\n' "$2" | grep -c "$3" 2>/dev/null || true)
    if [ "${n:-0}" -eq 1 ]; then ok "$1"; else fail "$1 (期望恰好 1 行 [$3],实际 ${n:-0} 行)"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MOCK_LOG="$TMP/mock.log"      # docker/compose 调用记录
SETCFG_LOG="$TMP/setcfg.log"  # setcfg 调用记录

# ── mock getcfg:解析 ini(fake qpkg.conf / def_share.info) ──
cat > "$TMP/getcfg" <<'MOCK'
#!/bin/sh
sec=""; key=""; file=""; def=""
while [ $# -gt 0 ]; do
    case "$1" in
        -f) file="$2"; shift 2 ;;
        -d) def="$2"; shift 2 ;;
        -u) shift ;;
        *) if [ -z "$sec" ]; then sec="$1"; elif [ -z "$key" ]; then key="$1"; fi; shift ;;
    esac
done
[ -f "$file" ] || { [ -n "$def" ] && echo "$def"; exit 0; }
val=$(awk -F= -v s="$sec" -v k="$key" '
    $0 == "["s"]" { insec=1; next }
    /^\[/         { insec=0 }
    insec && $1 == k { for (i=2; i<NF; i++) printf "%s=", $i; print $NF; exit }
' "$file")
if [ -n "$val" ]; then echo "$val"; elif [ -n "$def" ]; then echo "$def"; fi
MOCK

cat > "$TMP/setcfg" <<'MOCK'
#!/bin/sh
echo "setcfg $*" >> "${SETCFG_LOG:?}"
MOCK

cat > "$TMP/docker" <<'MOCK'
#!/bin/sh
echo "docker $*" >> "${MOCK_LOG:?}"
case "$1" in
    info) [ "${MOCK_INFO_FAILS:-0}" = "1" ] && exit 1 ;;
    ps)   [ "${MOCK_PS_EMPTY:-0}" = "1" ] || echo "c0ffee" ;;
esac
exit 0
MOCK

cat > "$TMP/docker-compose" <<'MOCK'
#!/bin/sh
echo "compose-wrapper $*" >> "${MOCK_LOG:?}"
exit "${MOCK_COMPOSE_EXIT:-0}"
MOCK
chmod +x "$TMP/getcfg" "$TMP/setcfg" "$TMP/docker" "$TMP/docker-compose"

# ── 假 QTS 环境:qpkg.conf / def_share.info / CS 目录 / 包安装目录 ──
VOL="$TMP/vol"                # 默认存储卷(defVolMP)
CS="$TMP/cs"                  # Container Station 安装目录
PKGROOT="$TMP/qpkg-root"      # 本 QPKG 安装目录(SYS_QPKG_DIR / Install_Path)
mkdir -p "$CS/bin" "$PKGROOT/shared" "$VOL"
cp "$TMP/docker" "$TMP/docker-compose" "$CS/bin/"
cp qpkg/shared/compose.yml qpkg/shared/env.example "$PKGROOT/shared/"
cat > "$TMP/qpkg.conf" <<EOF
[PigeonBox]
Enable=TRUE
Install_Path=$PKGROOT
[container-station]
Install_Path=$CS
EOF
cat > "$TMP/def_share.info" <<EOF
[SHARE_DEF]
defVolMP=$VOL
EOF

# 服务脚本公共环境(被脚本顶层读取,直接 export);mock 日志须导出——start 走后台引导子进程
APP_DIR="$VOL/pigeonbox"
export MOCK_LOG SETCFG_LOG FCB_QPKG_CONF="$TMP/qpkg.conf" FCB_GETCFG="$TMP/getcfg" \
    FCB_SETCFG="$TMP/setcfg" FCB_DEF_SHARE_INFO="$TMP/def_share.info"
# 模拟 qinstall 安装序:pkg_post_install 先生成 .env,首次 start 在其之后
mkdir -p "$APP_DIR"
printf 'FCB_API_PORT=12345\nFCB_DATA_DIR=%s/data\n' "$APP_DIR" > "$APP_DIR/.env"

echo "── Q1 start:启用状态 → 后台引导 compose up + 图标端口同步"
: > "$MOCK_LOG"; : > "$SETCFG_LOG"
sh qpkg/shared/pigeonbox.sh start
assert_eq "start 立即返回(不阻塞 rcS)" "$?" "0"
i=0
while [ $i -lt 30 ] && ! grep -q "started" "$MOCK_LOG" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
assert_contains "compose wrapper up -d 已调用"  "$(cat "$MOCK_LOG")" "up -d"
assert_contains "项目名固定 pigeonbox"        "$(cat "$MOCK_LOG")" "-p pigeonbox"
assert_contains "env-file 指向卷根 .env"        "$(cat "$MOCK_LOG")" "--env-file $APP_DIR/.env"
assert_contains "-f 指向包内 compose.yml"       "$(cat "$MOCK_LOG")" "-f $PKGROOT/shared/compose.yml"
assert_contains "setcfg 同步 Web_Port"          "$(cat "$SETCFG_LOG")" "Web_Port 12345"
if [ -d "$APP_DIR" ]; then ok "应用目录已创建(data/ 由安装钩子建,Q5 验证)"; else fail "应用目录未创建"; fi

echo "── Q2 status:docker ps 按固定容器名判活"
sh qpkg/shared/pigeonbox.sh status
assert_eq "容器在跑 → 0" "$?" "0"
MOCK_PS_EMPTY=1 sh qpkg/shared/pigeonbox.sh status
assert_eq "容器不在 → 3" "$?" "3"

echo "── Q3 stop / remove:down 容忍失败"
: > "$MOCK_LOG"
sh qpkg/shared/pigeonbox.sh stop
assert_eq "stop 退出码" "$?" "0"
assert_contains "down --remove-orphans 已调用" "$(cat "$MOCK_LOG")" "down --remove-orphans"
MOCK_COMPOSE_EXIT=1 sh qpkg/shared/pigeonbox.sh stop
assert_eq "compose 失败时 stop 仍为 0" "$?" "0"
: > "$MOCK_LOG"
sh qpkg/shared/pigeonbox.sh remove
assert_eq "remove 退出码" "$?" "0"
assert_contains "remove 走 down 清理容器" "$(cat "$MOCK_LOG")" "down --remove-orphans"

echo "── Q4 start:停用状态不拉容器"
: > "$MOCK_LOG"
sed 's/^Enable=TRUE/Enable=FALSE/' "$TMP/qpkg.conf" > "$TMP/qpkg-disabled.conf"
FCB_QPKG_CONF="$TMP/qpkg-disabled.conf" sh qpkg/shared/pigeonbox.sh start
sleep 2
assert_not_contains "停用状态无 compose 调用" "$(cat "$MOCK_LOG")" "up -d"

echo "── Q5 pkg_post_install:首次安装生成 .env"
rm -rf "$VOL/pigeonbox"
export FCB_GETCFG="$TMP/getcfg" FCB_WRITE_LOG=true SYS_QPKG_DIR="$PKGROOT" QPKG_VER="0.1.0"
# shellcheck disable=SC1091
. qpkg/package_routines
pkg_post_install
assert_contains "env 注入默认端口"    "$(cat "$APP_DIR/.env")" "FCB_API_PORT=12345"
assert_contains "env 注入数据目录"    "$(cat "$APP_DIR/.env")" "FCB_DATA_DIR=$APP_DIR/data"
assert_contains "镜像 tag 对齐包版本"  "$(cat "$APP_DIR/.env")" "FCB_IMAGE_TAG=v0.1.0"
assert_count   "IMAGE_TAG 恰好一行"   "$(cat "$APP_DIR/.env")" "^FCB_IMAGE_TAG="
assert_count   "注册开关保留"         "$(cat "$APP_DIR/.env")" "^FCB_USER_ALLOW_REGISTRATION="
if [ -d "$APP_DIR/data" ]; then ok "data 目录已建"; else fail "data 目录未建"; fi

echo "── Q6 pkg_post_install:升级只刷镜像 tag,用户配置保留"
printf 'FCB_API_PORT=8080\nFCB_DATA_DIR=%s\nFCB_IMAGE_TAG=v0.1.0\n' "$APP_DIR/data" > "$APP_DIR/.env"
QPKG_VER="0.2.0" pkg_post_install
assert_contains "镜像 tag 刷新到 v0.2.0" "$(cat "$APP_DIR/.env")" "FCB_IMAGE_TAG=v0.2.0"
assert_contains "用户端口保留"           "$(cat "$APP_DIR/.env")" "FCB_API_PORT=8080"
assert_count   "IMAGE_TAG 恰好一行"      "$(cat "$APP_DIR/.env")" "^FCB_IMAGE_TAG="
if [ ! -f "$APP_DIR/.env.tmp" ]; then ok "无 .tmp 残留"; else fail ".env.tmp 残留"; fi

echo "── Q7 卸载钩子字符串按 source 时变量展开(具体路径)"
cp qpkg/shared/pigeonbox.sh "$PKGROOT/shared/pigeonbox.sh"
chmod +x "$PKGROOT/shared/pigeonbox.sh"
: > "$MOCK_LOG"
eval "$PKG_PRE_REMOVE"
assert_eq "PKG_PRE_REMOVE 执行退出码" "$?" "0"
i=0
while [ $i -lt 20 ] && ! grep -q "down --remove-orphans" "$MOCK_LOG" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
assert_contains "卸载钩子调用了服务脚本 remove" "$(cat "$MOCK_LOG")" "down --remove-orphans"
unset FCB_GETCFG FCB_WRITE_LOG SYS_QPKG_DIR QPKG_VER GETCFG WRITE_LOG
unset pkg_pre_install pkg_post_install PKG_PRE_REMOVE PKG_MAIN_REMOVE PKG_POST_REMOVE

echo
if [ "$FAIL" -eq 0 ]; then
    echo "✓ 全部通过"
    exit 0
fi
echo "✗ ${FAIL} 项失败"
exit 1

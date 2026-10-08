#!/bin/sh
# QPKG 服务脚本与安装钩子 mock 冒烟测试(本地与 CI 同一套,无外部依赖):
#   伪造 getcfg/setcfg 与假二进制,验证原生生命周期:start(后台引导/图标端口
#   同步/健康等待)/status/stop(幂等)/remove/启用开关/package_routines 的
#   .env 生成与 Docker 遗留清理/卸载钩子字符串展开/看门狗自愈(崩溃拉起+无响应重启)。
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
wait_for() { # <超时秒> <文件> <grep 模式>
    _i=0
    while [ "$_i" -lt "$1" ]; do
        grep -q "$3" "$2" 2>/dev/null && return 0
        sleep 0.5
        _i=$((_i + 1))
    done
    return 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SETCFG_LOG="$TMP/setcfg.log" # setcfg 调用记录

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
chmod +x "$TMP/getcfg" "$TMP/setcfg"

# ── 假 QTS 环境:qpkg.conf / def_share.info / 包安装目录 / 假二进制 ──
# 双架构假二进制都建:测试可能在 arm64 Mac(x86_64 交叉场景)或 CI x86_64 上跑,
# 服务脚本按 uname -m 选用。env.example 按安装布局放包根(QDK 把 shared/ 平铺到包根)。
VOL="$TMP/vol"           # 默认存储卷(defVolMP)
PKGROOT="$TMP/qpkg-root" # 本 QPKG 安装目录(SYS_QPKG_DIR / Install_Path)
mkdir -p "$PKGROOT/bin" "$VOL"
cat > "$PKGROOT/bin/pigeonbox-linux-amd64" <<'FAKE'
#!/bin/sh
# 假服务进程:常驻,TERM/KILL 即死(不服务 /ping,供看门狗无响应场景)
trap 'exit 0' TERM INT
while :; do sleep 1; done
FAKE
cp "$PKGROOT/bin/pigeonbox-linux-amd64" "$PKGROOT/bin/pigeonbox-linux-arm64"
chmod +x "$PKGROOT/bin/pigeonbox-linux-amd64" "$PKGROOT/bin/pigeonbox-linux-arm64"
cp qpkg/shared/env.example "$PKGROOT/env.example"
cat > "$TMP/qpkg.conf" <<EOF
[PigeonBox]
Enable=TRUE
Install_Path=$PKGROOT
EOF
cat > "$TMP/def_share.info" <<EOF
[SHARE_DEF]
defVolMP=$VOL
EOF

# 服务脚本公共环境(被脚本顶层读取,直接 export);mock 日志须导出——start 走后台引导子进程
APP_DIR="$VOL/pigeonbox"
export SETCFG_LOG FCB_QPKG_CONF="$TMP/qpkg.conf" FCB_GETCFG="$TMP/getcfg" \
    FCB_SETCFG="$TMP/setcfg" FCB_DEF_SHARE_INFO="$TMP/def_share.info" \
    HEALTH_WAIT_MAX=1

echo "── Q1 start:启用状态 → 后台引导拉起二进制 + 图标端口同步"
sh qpkg/shared/pigeonbox.sh start
assert_eq "start 立即返回(不阻塞 rcS)" "$?" "0"
if wait_for 15 "$APP_DIR/pigeonbox.pid" "[0-9]"; then
    ok "二进制已拉起(pid 文件就位)"
else
    fail "pid 文件未就位"
fi
SERVER_PID=$(head -n 1 "$APP_DIR/pigeonbox.pid" 2>/dev/null)
if kill -0 "$SERVER_PID" 2>/dev/null; then ok "服务进程存活"; else fail "服务进程未存活"; fi
if wait_for 15 "$SETCFG_LOG" "Web_Port 12345"; then
    ok "setcfg 同步 Web_Port(.env 端口)"
else
    fail "Web_Port 未同步"
fi
if [ -f "$APP_DIR/.watchdog_pid" ]; then ok "看门狗已启动"; else fail "看门狗未启动"; fi
if grep -q "health check\|not ready" "$APP_DIR/pigeonbox.log" 2>/dev/null; then
    ok "健康等待有记录"
else
    fail "健康等待无日志"
fi

echo "── Q2 status:PID 判活(LSF 语义)"
sh qpkg/shared/pigeonbox.sh status
assert_eq "进程在跑 → 0" "$?" "0"
echo 999999 > "$APP_DIR/pigeonbox.pid"
sh qpkg/shared/pigeonbox.sh status
assert_eq "pid 不存在 → 3" "$?" "3"
# 还原真实 pid:Q3 的 stop 依赖 pid 文件定位真进程(顺带验证陈旧 pid 场景下的行为差异)
printf '%s' "$SERVER_PID" > "$APP_DIR/pigeonbox.pid"

echo "── Q3 stop:先看门狗后服务,幂等"
sh qpkg/shared/pigeonbox.sh stop
assert_eq "stop 退出码" "$?" "0"
if kill -0 "$SERVER_PID" 2>/dev/null; then fail "服务进程未停"; else ok "服务进程已停"; fi
if [ -f "$APP_DIR/.watchdog_pid" ]; then fail "看门狗 pid 文件残留"; else ok "看门狗已清"; fi
if [ -f "$APP_DIR/pigeonbox.pid" ]; then fail "服务 pid 文件残留"; else ok "服务 pid 文件已清"; fi
sh qpkg/shared/pigeonbox.sh stop
assert_eq "重复 stop 仍为 0(幂等)" "$?" "0"

echo "── Q4 start:停用状态不拉进程"
sed 's/^Enable=TRUE/Enable=FALSE/' "$TMP/qpkg.conf" > "$TMP/qpkg-disabled.conf"
FCB_QPKG_CONF="$TMP/qpkg-disabled.conf" sh qpkg/shared/pigeonbox.sh start
sleep 2
if [ -f "$APP_DIR/pigeonbox.pid" ]; then fail "停用状态拉起了进程"; else ok "停用状态未拉起进程"; fi

echo "── Q5 pkg_post_install:首次安装生成 .env(PB_ 前缀,无镜像/遗留键)"
rm -rf "$APP_DIR"
export FCB_GETCFG="$TMP/getcfg" FCB_WRITE_LOG=true SYS_QPKG_DIR="$PKGROOT" QPKG_VER="1.14.4"
# shellcheck disable=SC1091
. qpkg/package_routines
pkg_post_install
assert_contains "env 注入默认端口"       "$(cat "$APP_DIR/.env")" "PB_SERVER_PORT=12345"
assert_count    "注册开关保留"           "$(cat "$APP_DIR/.env")" "^PB_USER_ALLOW_REGISTRATION="
assert_not_contains "无镜像钉版行"       "$(cat "$APP_DIR/.env")" "PB_IMAGE_TAG"
assert_not_contains "无 FCB_ 前缀行"     "$(cat "$APP_DIR/.env")" "^FCB_"
assert_count    "PORT 恰好一行"          "$(cat "$APP_DIR/.env")" "^PB_SERVER_PORT="
if find "$APP_DIR/data" -maxdepth 0 >/dev/null 2>&1; then ok "data 目录已建"; else fail "data 目录未建"; fi
if find "$APP_DIR/.env" -maxdepth 0 -perm 0600 >/dev/null 2>&1; then
    ok ".env 权限 600"
else
    fail ".env 权限非 600"
fi

echo "── Q6 pkg_post_install:Docker 旧版升级清理死配置,用户配置保留"
printf 'PB_SERVER_PORT=8080\nPB_ADMIN_PASSWORD="secret"\nFCB_API_PORT=12345\nFCB_IMAGE_TAG=v0.15.7\nPB_IMAGE_TAG=v0.15.7\nPB_API_BIND=0.0.0.0\nPB_MAX_BODY_SIZE=1024m\nTZ=Asia/Shanghai\n' > "$APP_DIR/.env"
pkg_post_install
ENV_NOW=$(cat "$APP_DIR/.env")
assert_contains "用户端口保留"     "$ENV_NOW" "PB_SERVER_PORT=8080"
assert_contains "管理员密码保留"   "$ENV_NOW" "PB_ADMIN_PASSWORD"
assert_not_contains "FCB_API_PORT 已清" "$ENV_NOW" "FCB_API_PORT"
assert_not_contains "FCB_IMAGE_TAG 已清" "$ENV_NOW" "FCB_IMAGE_TAG"
assert_not_contains "PB_IMAGE_TAG 已清" "$ENV_NOW" "PB_IMAGE_TAG"
assert_not_contains "PB_API_BIND 已清"  "$ENV_NOW" "PB_API_BIND"
assert_not_contains "PB_MAX_BODY_SIZE 已清" "$ENV_NOW" "PB_MAX_BODY_SIZE"
assert_not_contains "TZ 已清"           "$ENV_NOW" "^TZ="
if [ ! -f "$APP_DIR/.env.bak" ]; then ok "无 .bak 残留"; else fail ".env.bak 残留"; fi

echo "── Q7 看门狗:进程消失自动拉起"
WATCHDOG_INTERVAL=1 sh qpkg/shared/pigeonbox.sh start
wait_for 15 "$APP_DIR/pigeonbox.pid" "[0-9]" || fail "Q8 前置:进程未起"
OLD_PID=$(head -n 1 "$APP_DIR/pigeonbox.pid")
kill -9 "$OLD_PID" 2>/dev/null
NEW_PID=""
_i=0
while [ "$_i" -lt 20 ]; do
    sleep 1
    NEW_PID=$(head -n 1 "$APP_DIR/pigeonbox.pid" 2>/dev/null)
    [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && kill -0 "$NEW_PID" 2>/dev/null && break
    _i=$((_i + 1))
done
if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && kill -0 "$NEW_PID" 2>/dev/null; then
    ok "崩溃进程已被看门狗拉起($OLD_PID → $NEW_PID)"
else
    fail "看门狗未拉起崩溃进程"
fi
if grep -q "respawning" "$APP_DIR/pigeonbox.log" 2>/dev/null; then
    ok "拉起动作有日志"
else
    fail "拉起无日志"
fi

echo "── Q8 看门狗:进程活着但 /ping 无响应 → 重启"
STABLE_PID=$(head -n 1 "$APP_DIR/pigeonbox.pid")
_i=0
while [ "$_i" -lt 20 ]; do
    sleep 1
    CUR_PID=$(head -n 1 "$APP_DIR/pigeonbox.pid" 2>/dev/null)
    if [ -n "$CUR_PID" ] && [ "$CUR_PID" != "$STABLE_PID" ] && kill -0 "$CUR_PID" 2>/dev/null; then
        break
    fi
    _i=$((_i + 1))
done
if [ -n "$CUR_PID" ] && [ "$CUR_PID" != "$STABLE_PID" ]; then
    ok "无响应进程已被看门狗重启($STABLE_PID → $CUR_PID)"
else
    fail "看门狗未重启无响应进程"
fi
if grep -q "no response, restarting" "$APP_DIR/pigeonbox.log" 2>/dev/null; then
    ok "重启决策有日志"
else
    fail "重启决策无日志"
fi

echo "── Q9 看门狗停机竞态:stop 后不再拉起"
sh qpkg/shared/pigeonbox.sh stop
assert_eq "stop 退出码" "$?" "0"
sleep 3
FINAL_PID=$(head -n 1 "$APP_DIR/pigeonbox.pid" 2>/dev/null)
if [ -z "$FINAL_PID" ] || ! kill -0 "$FINAL_PID" 2>/dev/null; then
    ok "stop 后进程保持停止(无自愈拉起)"
else
    fail "stop 后进程被重新拉起"
fi

echo "── Q10 卸载钩子字符串按 source 时变量展开(具体路径;最后跑,钩内 unset 清场)"
cp qpkg/shared/pigeonbox.sh "$PKGROOT/pigeonbox.sh"
chmod +x "$PKGROOT/pigeonbox.sh"
# 先起一组进程供卸载停服
sh qpkg/shared/pigeonbox.sh start
wait_for 15 "$APP_DIR/pigeonbox.pid" "[0-9]" || fail "Q10 前置:进程未起"
UPID=$(head -n 1 "$APP_DIR/pigeonbox.pid")
eval "$PKG_PRE_REMOVE"
assert_eq "PKG_PRE_REMOVE 执行退出码" "$?" "0"
_i=0
while kill -0 "$UPID" 2>/dev/null && [ "$_i" -lt 20 ]; do sleep 0.5; _i=$((_i + 1)); done
if kill -0 "$UPID" 2>/dev/null; then fail "卸载钩子未停服"; else ok "卸载钩子调用了服务脚本 remove 并停服"; fi
unset FCB_GETCFG FCB_WRITE_LOG SYS_QPKG_DIR QPKG_VER GETCFG WRITE_LOG
unset pkg_pre_install pkg_post_install PKG_PRE_REMOVE PKG_MAIN_REMOVE PKG_POST_REMOVE

echo
if [ "$FAIL" -eq 0 ]; then
    echo "✓ 全部通过"
    exit 0
fi
echo "✗ ${FAIL} 项失败"
exit 1

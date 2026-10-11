#!/bin/sh
# PigeonBox QPKG 服务脚本(原生进程模式)—— qinstall.sh 安装时软链到 /etc/init.d/,
# 经 /etc/rcS.d/QS199PigeonBox(开机 start)/rcK.d(stop) 与 App Center 启停按钮调用。
# 另含内部参数 __boot_start(setsid 后台引导用,勿手工调用)。
#
# v1.14.4 起 QPKG 去 Docker 化(对齐 fnos v1.2.7+ 原生模式):包内自带静态二进制
# (bin/)与前端(www/),进程直接运行,免 Container Station/免 ghcr 拉镜像。
# 生命周期约定:start/stop exit 0=成功;status exit 0=运行中,3=未运行。
# QDK 打包布局:shared/ 内容平铺到包根(rsync shared/. → build 根),二进制来自
# 本架构目录 x86_64/ 或 arm_64/ 的 bin/,故运行时布局为 <QPKG_ROOT>/{pigeonbox.sh,bin/,www/}。
QPKG_NAME="PigeonBox"
# FCB_QPKG_CONF/FCB_GETCFG/FCB_SETCFG 仅供测试注入 mock(QTS 运行环境不会设置)
QPKG_CONF="${FCB_QPKG_CONF:-/etc/config/qpkg.conf}"
GETCFG="${FCB_GETCFG:-/sbin/getcfg}"
SETCFG="${FCB_SETCFG:-/sbin/setcfg}"
DEF_SHARE="${FCB_DEF_SHARE_INFO:-/etc/config/def_share.info}"

qpkg_root() {
    _r=$("$GETCFG" "$QPKG_NAME" Install_Path -f "$QPKG_CONF" 2>/dev/null)
    [ -n "$_r" ] || _r="/share/CACHEDEV1_DATA/.qpkg/${QPKG_NAME}"
    echo "$_r"
}

base_vol() {
    # 默认存储卷(数据放卷根而非 $QPKG_ROOT:卸载会整删安装目录,卷根数据保留)
    _v=$("$GETCFG" SHARE_DEF defVolMP -f "$DEF_SHARE" 2>/dev/null)
    [ -n "$_v" ] || _v="/share/CACHEDEV1_DATA"
    echo "$_v"
}

QPKG_ROOT="$(qpkg_root)"
APP_DIR="$(base_vol)/pigeonbox"
ENV_FILE="${APP_DIR}/.env"
LOG_FILE="${APP_DIR}/pigeonbox.log"
PID_FILE="${APP_DIR}/pigeonbox.pid"
WATCHDOG_PID_FILE="${APP_DIR}/.watchdog_pid"

# 按架构选二进制(build-native.sh 产出的静态链接文件)
case "$(uname -m)" in
    x86_64)          BIN="${QPKG_ROOT}/bin/pigeonbox-linux-amd64" ;;
    aarch64|arm64)   BIN="${QPKG_ROOT}/bin/pigeonbox-linux-arm64" ;;
    *)               BIN="" ;;
esac

# 可调参数(仅供测试注入加速;QTS 运行环境用默认值)
HEALTH_WAIT_MAX="${HEALTH_WAIT_MAX:-10}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}"
WATCHDOG_THRESHOLD=3

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >>"${LOG_FILE}" 2>/dev/null || true
}

# /ping 探活:curl 优先,QTS 老版本回退 busybox wget
probe() {
    if command -v curl >/dev/null 2>&1; then
        curl -s -m 3 "http://127.0.0.1:${PB_SERVER_PORT}/ping" 2>/dev/null | grep -q pong
    else
        wget -q -O- -T 3 "http://127.0.0.1:${PB_SERVER_PORT}/ping" 2>/dev/null | grep -q pong
    fi
}

# app.log 轮转:超 10MB 截尾保留最近 1MB(对齐 fnos cmd/main,防无限增长)
rotate_log() {
    [ -f "${LOG_FILE}" ] || return 0
    _size=$(wc -c <"${LOG_FILE}" 2>/dev/null | tr -d '[:space:]')
    [ -n "$_size" ] && [ "${_size}" -gt 10485760 ] || return 0
    tail -c 1048576 "${LOG_FILE}" >"${LOG_FILE}.tmp" 2>/dev/null \
        && mv "${LOG_FILE}.tmp" "${LOG_FILE}"
}

# 运行环境准备:在当前 shell 内导出(勿经命令替换子壳——export 传不出子壳)。
# 路径 env 全部落应用目录(卷根 pigeonbox/);.env 的 PB_SERVER_PORT 覆盖缺省。
prepare_env() {
    export PB_DATA_PATH="${APP_DIR}/data"
    export PB_DATABASE_DB_NAME="${APP_DIR}/data/fileCodeBox.db"
    export PB_STORAGE_PATH="${APP_DIR}/data/uploads"
    # 应用目录:二进制据此消费 .admin_reset 密码重置标记(internal/adminreset)
    export PB_APP_HOME="${APP_DIR}"
    export PB_SERVER_HOST=0.0.0.0
    # 端口:.env 显式配置优先,缺省回退 12345
    export PB_SERVER_PORT="${PB_SERVER_PORT:-12345}"
    if [ -r "${ENV_FILE}" ]; then
        set -a
        # shellcheck disable=SC1090
        . "${ENV_FILE}"
        set +a
    fi
    mkdir -p "${PB_DATA_PATH}"
}

launch() {
    # 打包链路不保证保留执行位,启动前兜底(文件属 root,可 chmod)
    chmod +x "${BIN}" 2>/dev/null || true
    # 高级逃生门:用户在应用目录自建 config.yaml 时才启用文件配置(env 优先级仍更高)
    if [ -r "${APP_DIR}/config.yaml" ]; then
        "${BIN}" --config "${APP_DIR}/config.yaml" --static "${QPKG_ROOT}/www" >>"${LOG_FILE}" 2>&1 &
    else
        "${BIN}" --static "${QPKG_ROOT}/www" >>"${LOG_FILE}" 2>&1 &
    fi
    printf "%s" "$!" >"${PID_FILE}"
}

# 看门狗自愈循环(由 start_process 后台拉起,继承环境;语义对齐 fnos cmd/main):
#   每个周期探活;进程消失(崩溃/被杀)直接重新拉起;/ping 连续 3 次失败重启进程。
# 终止条件:stop 先杀看门狗再杀 server,不会与正常停机竞态。
# ⚠ 双胞胎警示:本脚本与 fnos 仓 cmd/main 的看门狗/健康探测/日志截尾逻辑
# 同构(方言差异:本侧 POSIX sh、彼侧 bash)。单侧修改 watchdog 阈值/探活
# 方式/截尾上限时,请评估另一侧是否需要同步(共享库下沉已评估暂缓)。
watchdog_loop() {
    _fail=0
    while :; do
        sleep "${WATCHDOG_INTERVAL}"
        _pid=$(head -n 1 "${PID_FILE}" 2>/dev/null | tr -d '[:space:]')
        if ! kill -0 "${_pid}" 2>/dev/null; then
            log_msg "watchdog: server process gone, respawning"
            launch
            _fail=0
            continue
        fi
        if probe; then
            _fail=0
            continue
        fi
        _fail=$((_fail + 1))
        log_msg "watchdog: ping fail (${_fail}/${WATCHDOG_THRESHOLD})"
        if [ "${_fail}" -ge "${WATCHDOG_THRESHOLD}" ]; then
            log_msg "watchdog: no response, restarting server process"
            kill -TERM "${_pid}" 2>/dev/null || true
            sleep 3
            kill -KILL "${_pid}" 2>/dev/null || true
            launch
            _fail=0
        fi
    done
}

start_watchdog() {
    # 幂等:先清旧看门狗
    if [ -f "${WATCHDOG_PID_FILE}" ]; then
        kill "$(head -n 1 "${WATCHDOG_PID_FILE}" 2>/dev/null | tr -d '[:space:]')" 2>/dev/null || true
        rm -f "${WATCHDOG_PID_FILE}"
    fi
    watchdog_loop &
    echo $! >"${WATCHDOG_PID_FILE}"
    log_msg "watchdog started (pid $(cat "${WATCHDOG_PID_FILE}"))"
}

check_process() {
    kill -0 "$1" 2>/dev/null
}

status() {
    if [ -f "${PID_FILE}" ]; then
        _pid=$(head -n 1 "${PID_FILE}" | tr -d '[:space:]')
        if check_process "${_pid}"; then
            return 0
        fi
        rm -f "${PID_FILE}"
    fi
    return 1
}

start_process() {
    if status; then
        return 0
    fi
    if [ -z "${BIN}" ]; then
        log_msg "unsupported arch: $(uname -m)"
        return 1
    fi
    if [ ! -f "${BIN}" ]; then
        log_msg "binary not found: ${BIN}(打包漏跑 scripts/build-native.sh?)"
        return 1
    fi
    rotate_log
    prepare_env
    log_msg "Starting PigeonBox ($(uname -m)) on port ${PB_SERVER_PORT} ..."
    launch
    # 启动健康等待:未就绪只记日志(迁移/慢盘场景由看门狗兜底,App Center 以 status 复核)
    _waited=0
    while [ "${_waited}" -lt "${HEALTH_WAIT_MAX}" ]; do
        if probe; then
            log_msg "health check ok after ${_waited}s"
            break
        fi
        sleep 1
        _waited=$((_waited + 1))
    done
    [ "${_waited}" -ge "${HEALTH_WAIT_MAX}" ] && \
        log_msg "warn: /ping not ready after ${_waited}s (process may still be migrating)"
    start_watchdog
    return 0
}

stop_process() {
    log_msg "Stopping PigeonBox ..."
    # 先停看门狗,防止停机过程中被自愈逻辑重新拉起
    if [ -f "${WATCHDOG_PID_FILE}" ]; then
        _wdpid=$(head -n 1 "${WATCHDOG_PID_FILE}" 2>/dev/null | tr -d '[:space:]')
        kill "${_wdpid}" 2>/dev/null || true
        rm -f "${WATCHDOG_PID_FILE}"
        log_msg "watchdog stopped (${_wdpid})"
    fi
    if [ -r "${PID_FILE}" ]; then
        _pid=$(head -n 1 "${PID_FILE}" | tr -d '[:space:]')
        if ! check_process "${_pid}"; then
            rm -f "${PID_FILE}"
            log_msg "remove pid file (process gone)"
            return 0
        fi
        log_msg "send TERM signal to PID:${_pid}..."
        kill -TERM "${_pid}" >>"${LOG_FILE}" 2>&1 || true
        _count=0
        while check_process "${_pid}" && [ "${_count}" -lt 10 ]; do
            sleep 1
            _count=$((_count + 1))
        done
        if check_process "${_pid}"; then
            log_msg "send KILL signal to PID:${_pid}..."
            kill -KILL "${_pid}" >>"${LOG_FILE}" 2>&1 || true
            sleep 1
        fi
        rm -f "${PID_FILE}"
    fi
    return 0
}

case "$1" in
    start)
        # App Center 停用状态不启动
        if [ "$("$GETCFG" "$QPKG_NAME" Enable -u -d FALSE -f "$QPKG_CONF" 2>/dev/null)" != "TRUE" ]; then
            exit 0
        fi
        mkdir -p "$APP_DIR"
        # 开机时存储卷/网络晚于本脚本就绪的竞态:setsid 后台引导,不阻塞 rcS
        # (App Center 会杀阻塞在启动流程里的进程组)
        if command -v setsid >/dev/null 2>&1; then
            setsid "$0" __boot_start >/dev/null 2>&1 </dev/null &
        else
            "$0" __boot_start >/dev/null 2>&1 </dev/null &
        fi
        exit 0
        ;;
    __boot_start)
        prepare_env
        # App Center 图标端口跟随 .env(用户改端口后"打开"链接仍正确)
        if [ -n "${PB_SERVER_PORT:-}" ]; then
            "$SETCFG" "$QPKG_NAME" "Web_Port" "${PB_SERVER_PORT}" -f "$QPKG_CONF" 2>/dev/null
        fi
        start_process
        ;;
    stop)
        stop_process
        ;;
    restart)
        "$0" stop
        sleep 2
        exec "$0" start
        ;;
    status)
        # LSF 语义:0=运行中,3=未运行
        if status; then
            exit 0
        fi
        exit 3
        ;;
    remove)
        # 卸载:停进程(数据在卷根 pigeonbox/ 目录,卸载不动)
        stop_process
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|remove}" >&2
        exit 1
        ;;
esac

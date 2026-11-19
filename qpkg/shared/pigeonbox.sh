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

# ── shellkit POSIX 子集（设备侧唯一可用的 shellkit 形态）──────────────────
#   上游 shellkit 主库是 bash 3.2+ 基线（数组/mapfile/[[ ]]/printf -v）⇒
#   busybox ash **根本解析不了** ⇒ 上一轮改造里设备侧脚本一律零改动。
#   现在上游交付了纯 POSIX 的子集（lib/posix/shellkit-posix.sh）⇒ 这里只用
#   「建目录」这一小撮能力（fs_ensure_dir），其余手写全部保留（见下方注释）。
#   落点探测：① 环境变量 ② 脚本同目录 ③ 同目录 lib/ ④ 通用安装路径
#            ⑤ **QPKG 包根**
#   ⚠️ ⑤ 是 QTS 专属的、**不能省**：QTS 把服务脚本**软链**到 /etc/init.d/
#      ⇒ dirname "$0" 指向 /etc/init.d，不是包根 ⇒ 只探 ①②③④ 必然落空
#      ⇒ 装机即挂（fail-closed 退 5 ⇒ 服务永远起不来）。
#      包根能命中是因为 QDK 把 shared/ 平铺到包根（库与脚本同在包根）。
#   ⚠️ **fail-closed**：库在而脚本不在 ⇒ 装的是不完整的包 ⇒ 响亮失败退 5，
#      不静默半工作（设备侧改错 = 装机即挂 ⇒ 宁可直接失败，也不要带病运行）。
_sk_dir="$(dirname "$0")"
_sk_lib=""
for _sk_c in \
    "${PB_SHELLKIT_POSIX:-}" \
    "${_sk_dir}/shellkit-posix.sh" \
    "${_sk_dir}/lib/shellkit-posix.sh" \
    "/usr/lib/pigeonbox/shellkit-posix.sh" \
    "${QPKG_ROOT}/shellkit-posix.sh"
do
    if [ -n "$_sk_c" ] && [ -r "$_sk_c" ]; then _sk_lib="$_sk_c"; break; fi
done
if [ -z "$_sk_lib" ]; then
    echo "缺 shellkit POSIX 子集（装的是不完整的包）" >&2
    exit 5
fi
# 路径是运行时探测出来的 ⇒ shellcheck 静态追不动，显式声明不追
# shellcheck source=/dev/null
. "$_sk_lib"
# 归一成**绝对路径**再导出：子进程（预接线脚本）按各自 cwd 解析相对路径会找不到
_sk_lib="$(cd "$(dirname "$_sk_lib")" && pwd)/$(basename "$_sk_lib")"
export PB_SHELLKIT_POSIX="$_sk_lib"

# 按架构选二进制(build-native.sh 产出的静态链接文件)
case "$(uname -m)" in
    x86_64)          BIN="${QPKG_ROOT}/bin/pigeonbox-linux-amd64"
                     export PB_P2PC_PATH="${QPKG_ROOT}/bin/p2pc-linux-amd64" ;;
    aarch64|arm64)   BIN="${QPKG_ROOT}/bin/pigeonbox-linux-arm64"
                     export PB_P2PC_PATH="${QPKG_ROOT}/bin/p2pc-linux-arm64" ;;
    *)               BIN="" ;;
esac
# p2pc 设备直传随包(P2b):包内无此文件时 core 探测失败优雅降级(直传页引导态)。

# p2pcweb(PigeonBeam 信鸽直传网页客户端,2026-10-16 A2 内嵌,与 fnos 同构):
# LAN 暴露 + 持久令牌门禁(--token-file/--config-file 落数据卷,p2pcweb 自持读写);
# 端口 PB_P2PCWEB_PORT(.env 可覆盖,默认 12348);接收目录=数据卷(投递到柜同机路径最短)。
# 包内无此二进制时优雅跳过(老包升级首启兼容)。
P2PCWEB_BIN=""
case "$(uname -m)" in
    x86_64)          P2PCWEB_BIN="${QPKG_ROOT}/bin/p2pcweb-linux-amd64" ;;
    aarch64|arm64)   P2PCWEB_BIN="${QPKG_ROOT}/bin/p2pcweb-linux-arm64" ;;
esac
P2PCWEB_PID_FILE="${APP_DIR}/p2pcweb.pid"

# 可调参数(仅供测试注入加速;QTS 运行环境用默认值)
HEALTH_WAIT_MAX="${HEALTH_WAIT_MAX:-10}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}"
WATCHDOG_THRESHOLD=3

# ⚠️ **保留手写**（2026-11-19 设备侧 POSIX 化）：本函数写的是**日志文件**
#   （${LOG_FILE}），而 shellkit POSIX 子集的 log_* 一律写 **stderr**
#   ⇒ **不是等价替换**（换了会把服务日志的时间戳行变成 stderr 噪声，
#   且 QPKG 的日志采集看不到）⇒ 继续手写。
log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >>"${LOG_FILE}" 2>/dev/null || true
}

# ⚠️ **保留手写**（2026-11-19 设备侧 POSIX 化）：POSIX 子集**没有**探活能力
#   （net_wait_port / net_wait_http 都不在子集里；proc_* 明确不进子集，
#   见上游 issue #162）⇒ 探活逻辑保持原样。
# /ping 探活:curl 优先,QTS 老版本回退 busybox wget
probe() {
    if command -v curl >/dev/null 2>&1; then
        curl -s -m 3 "http://127.0.0.1:${PB_SERVER_PORT}/ping" 2>/dev/null | grep -q pong
    else
        wget -q -O- -T 3 "http://127.0.0.1:${PB_SERVER_PORT}/ping" 2>/dev/null | grep -q pong
    fi
}

# ⚠️ **保留手写**（2026-11-19 设备侧 POSIX 化）：POSIX 子集无日志轮转能力 ⇒ 保持原样。
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
    # .env 空串回退（2026-10-26 审计 P2，对齐 fnos 侧已实锤修过的同一处）：
    # 上面那行兜底发生在 source **之前** ⇒ .env 里若写了空的 PB_SERVER_PORT=
    # （用户可编辑；升级保留旧值），source 会把端口覆盖成空串 ⇒
    # 探活 URL 变成 "http://127.0.0.1:/ping" 恒失败 ⇒ 看门狗连续 3 次失败
    # 即 kill 重启 ⇒ **每 90s 强杀重启，永远起不来**。
    # 真机实录（fnos 侧 10-13）：探活恒失败 ⇒ 重启循环；本侧此前没有这个兜底。
    # ⇒ source 之后补一道：空串 ⇒ 回退 12345。
    if [ -z "${PB_SERVER_PORT:-}" ]; then
        export PB_SERVER_PORT=12345
    fi
    # 首启逃逸门(2026-10-22 全生态统一, 与 openwrt procd 段同款): 未设管理员
    # 密码时不播种弱口令 admin/admin123, 改走 /setup 首启向导(浏览器建号)。
    # 为什么这样更安全: 弱口令可被扫描器猜到; 未初始化实例要有人刻意访问
    # /setup 才能认领 —— 后者暴露面小得多。
    # 已有实例零副作用: core 的 CreateDefaultAdmin 见到已有管理员直接返回。
    [ -z "${PB_ADMIN_PASSWORD}" ] && export PB_DISABLE_DEFAULT_ADMIN=true
    # 建目录交给 shellkit POSIX 子集的 fs_ensure_dir（已存在即成功 ⇒ 与 mkdir -p
    # 等价；建父目录同款）。失败**不改退出码语义**：本脚本无 set -e，
    # 起不来由看门狗兜底 ⇒ 只记日志。
    fs_ensure_dir "${PB_DATA_PATH}" || log_msg "failed to create data dir: ${PB_DATA_PATH}"
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

# ⚠️ **保留手写**（2026-11-19 设备侧 POSIX 化）：POSIX 子集**没有**看门狗能力
#   （proc_* 明确不进子集，见上游 issue #162：进程存活判定/优雅停机都没有对应件）
#   ⇒ 整段保持原样（含与 fnos cmd/main 的同构关系，见下方「双胞胎警示」）。
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
        # p2pcweb 自愈:进程消失(崩溃/被杀)即重新拉起(环境沿用本循环继承的导出)
        if [ -n "$P2PCWEB_BIN" ] && [ -f "$P2PCWEB_BIN" ] && [ -f "${P2PCWEB_PID_FILE}" ]; then
            _bpid=$(head -n 1 "${P2PCWEB_PID_FILE}" 2>/dev/null | tr -d '[:space:]')
            if ! kill -0 "${_bpid}" 2>/dev/null; then
                log_msg "watchdog: p2pcweb process gone, respawning"
                start_p2pcweb
            fi
        fi
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

# p2pcweb 生命周期(A2):start 在 server 健康后拉起,stop 在 server 之前停。
start_p2pcweb() {
    # SC2015 纪律:不用 A && B || C 形态(与看门狗/探活同款显式 if 风格)
    if [ -z "$P2PCWEB_BIN" ] || [ ! -f "$P2PCWEB_BIN" ]; then
        log_msg "p2pcweb binary missing, skip"
        return 0
    fi
    if check_process "$(cat "${P2PCWEB_PID_FILE}" 2>/dev/null)"; then
        return 0
    fi
    chmod +x "$P2PCWEB_BIN" 2>/dev/null || true
    _beam_port="${PB_P2PCWEB_PORT:-12348}"
    log_msg "Starting p2pcweb on 0.0.0.0:${_beam_port} ..."
    "$P2PCWEB_BIN" --addr "0.0.0.0:${_beam_port}" \
        --token-file "${PB_DATA_PATH}/.p2pcweb_token" \
        --config-file "${PB_DATA_PATH}/p2pcweb.json" \
        --out "${PB_DATA_PATH}" \
        --no-open >>"${LOG_FILE}" 2>&1 &
    printf "%s" "$!" >"${P2PCWEB_PID_FILE}"
}

# PigeonBeam 出厂预接线(roadmap §3.1 的真实缺口):把 Box 地址 + 一把专用
# API Key 预置进 p2pcweb ⇒ 用户打开 Beam 的「文件柜」tab **不再需要手填**。
# 失败**不阻断**(优雅降级):Beam 退化为「手填」旧行为,Box 照常可用。
prewire_beam_box() {
    # ⚠️ 落点（2026-11-19，qnap#204 的另一半）：QTS 把服务脚本**软链**到
    #   /etc/init.d/ ⇒ dirname "$0" 指向 /etc/init.d，不是包根 ⇒ 同目录探测
    #   必然落空 ⇒ 预接线每次都被 skip（真机表现＝「装完仍得手填」）。
    #   ⇒ 主用包根（QDK 把 shared/ 平铺到包根），同目录仅作仓内/兜底。
    _prewire_script="${QPKG_ROOT}/prewire_beam_box"
    if [ ! -f "$_prewire_script" ]; then
        _prewire_script="$(cd "$(dirname "$0")" && pwd)/prewire_beam_box"
    fi
    if [ ! -f "$_prewire_script" ]; then
        log_msg "beam prewire: script missing, skip"
        return 0
    fi
    # 打包链路不保证保留执行位,启动前兜底(与 launch() 同款：文件属 root,可 chmod)
    chmod +x "$_prewire_script" 2>/dev/null || true
    # ⚠️ **后台执行**:脚本自己会等 Box / p2pcweb 就绪(最多 30s)
    #   ⇒ 前台调用会把包启动**阻塞** ⇒ 极端情况下触发 QPKG 启动超时。
    # ⚠️ qnap#204（2026-11-19 修）：原为 `nohup bash "$_prewire_script"`
    #   ⇒ **QTS 上没有 bash** ⇒ nohup 找不到解释器 ⇒ 子进程根本没起来
    #   ⇒ 预接线静默空跑（真机表现＝「装完仍得手填」）。
    #   ⇒ 预接线脚本本身已是 POSIX sh（busybox ash 可执行）⇒ 直接执行它。
    #   PB_SHELLKIT_POSIX 已在上方装载段导出 ⇒ 子进程能定位 POSIX 子集。
    nohup "$_prewire_script" >>"${LOG_FILE}" 2>&1 &
    log_msg "beam prewire: started (background; waits for Box + p2pcweb readiness)"
    return 0
}

stop_p2pcweb() {
    [ -f "${P2PCWEB_PID_FILE}" ] || return 0
    _bpid=$(head -n 1 "${P2PCWEB_PID_FILE}" 2>/dev/null | tr -d '[:space:]')
    if check_process "${_bpid}"; then
        kill -TERM "${_bpid}" 2>/dev/null || true
        _bc=0
        while check_process "${_bpid}" && [ "${_bc}" -lt 5 ]; do
            sleep 1
            _bc=$((_bc + 1))
        done
        if check_process "${_bpid}"; then
            kill -KILL "${_bpid}" 2>/dev/null || true
        fi
        log_msg "p2pcweb stopped (${_bpid})"
    fi
    rm -f "${P2PCWEB_PID_FILE}"
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
    # PigeonBeam 网页客户端随主服务拉起(A2;失败不阻断主服务)
    start_p2pcweb
    # 出厂预接线:Box 地址 + 专用 API Key 预置给 Beam（失败不阻断）
    prewire_beam_box
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
    # 再停 p2pcweb(避免看门狗复活它)
    stop_p2pcweb
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

# ⚠️ **退出码是对外契约**（2026-11-19 设备侧 POSIX 化）：status 退 0/3 是
#   QTS/LSF 语义（0=运行中,3=未运行），start/stop/restart 退 0=成功 ⇒ 一律不改。
#   （POSIX 子集的 die/fail 是「消息在前、退出码在后」、与 bash 版相反，
#     本脚本**不引**它们改退出码 ⇒ 只在上方装载段用到 fs_ensure_dir。）
case "$1" in
    start)
        # App Center 停用状态不启动
        if [ "$("$GETCFG" "$QPKG_NAME" Enable -u -d FALSE -f "$QPKG_CONF" 2>/dev/null)" != "TRUE" ]; then
            exit 0
        fi
        # 建目录交给 shellkit POSIX 子集的 fs_ensure_dir（已存在即成功 ⇒ 与 mkdir -p 等价）
        fs_ensure_dir "$APP_DIR" || log_msg "failed to create app dir: ${APP_DIR}"
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

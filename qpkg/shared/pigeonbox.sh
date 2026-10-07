#!/bin/sh
# PigeonBox QPKG 服务脚本 —— qinstall.sh 安装时软链到 /etc/init.d/,
# 经 /etc/rcS.d/QS199PigeonBox(开机 start)/rcK.d(stop) 与 App Center 启停按钮调用。
# 另含内部参数 __boot_start(setsid 后台引导用,勿手工调用)。
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
COMPOSE_FILE="${QPKG_ROOT}/shared/compose.yml"
APP_DIR="$(base_vol)/pigeonbox"
ENV_FILE="${APP_DIR}/.env"
LOG_FILE="${APP_DIR}/pigeonbox.log"

find_docker() {
    # 优先 Container Station 自带 CLI(容器在 CS 界面可见可管理),逐级回退
    _cs=$("$GETCFG" container-station Install_Path -f "$QPKG_CONF" 2>/dev/null)
    for c in "${_cs}/bin/docker" /usr/local/bin/docker /usr/local/bin/system-docker "${_cs}/bin/system-docker"; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    command -v docker 2>/dev/null
}

find_compose() {
    # Container Station 附带的 compose wrapper(CS2/CS3 均存在)优先,
    # 其次独立 docker-compose,最后 docker CLI v2 的 compose 子命令
    _cs=$("$GETCFG" container-station Install_Path -f "$QPKG_CONF" 2>/dev/null)
    for c in "${_cs}/bin/system-docker-compose" "${_cs}/bin/docker-compose" /usr/local/bin/docker-compose; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    _d="$(find_docker)"
    if [ -n "$_d" ] && "$_d" compose version >/dev/null 2>&1; then
        echo "$_d compose"
        return 0
    fi
    return 1
}

compose_run() {
    _c="$(find_compose)" || {
        echo "未找到 docker compose(请确认 Container Station 3 已安装并启动)" >>"$LOG_FILE" 2>&1
        return 1
    }
    case "$_c" in
        *" compose")
            _d="${_c% compose}"
            "$_d" compose -p pigeonbox --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
            ;;
        *)
            "$_c" -p pigeonbox --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
            ;;
    esac
}

wait_docker_ready() {
    # docker info 成功不代表 daemon 可服务:info+ps 须连续两次成功(开机竞态经验)
    _d="$(find_docker)" || return 1
    _n=0
    while [ "$_n" -lt 36 ]; do
        if "$_d" info >/dev/null 2>&1 && "$_d" ps >/dev/null 2>&1; then
            if "$_d" info >/dev/null 2>&1 && "$_d" ps >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 10
        _n=$((_n + 1))
    done
    return 1
}

do_boot_start() {
    wait_docker_ready || {
        echo "$(date '+%F %T') docker/Container Station 未就绪,放弃本次启动" >>"$LOG_FILE"
        exit 1
    }
    compose_run up -d >>"$LOG_FILE" 2>&1 || {
        echo "$(date '+%F %T') compose up 失败(镜像未拉全或端口占用?),详见上方输出" >>"$LOG_FILE"
        exit 1
    }
    echo "$(date '+%F %T') started ($(grep -E '^FCB_IMAGE_TAG=' "$ENV_FILE" 2>/dev/null | cut -d= -f2))" >>"$LOG_FILE"
}

case "$1" in
    start)
        # App Center 停用状态不启动
        if [ "$("$GETCFG" "$QPKG_NAME" Enable -u -d FALSE -f "$QPKG_CONF" 2>/dev/null)" != "TRUE" ]; then
            exit 0
        fi
        mkdir -p "$APP_DIR"
        # App Center 图标端口跟随 .env(用户改端口后"打开"链接仍正确)
        _port=$(grep -E '^FCB_API_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
        if [ -n "$_port" ]; then
            "$SETCFG" "$QPKG_NAME" "Web_Port" "$_port" -f "$QPKG_CONF" 2>/dev/null
        fi
        # 开机时 Container Station 常比本 QPKG 晚就绪:setsid 后台引导,不阻塞 rcS
        # (App Center 会杀阻塞在启动流程里的进程组)
        if command -v setsid >/dev/null 2>&1; then
            setsid "$0" __boot_start >/dev/null 2>&1 </dev/null &
        else
            "$0" __boot_start >/dev/null 2>&1 </dev/null &
        fi
        exit 0
        ;;
    __boot_start)
        do_boot_start
        ;;
    stop)
        compose_run down --remove-orphans >>"$LOG_FILE" 2>&1 || true
        exit 0
        ;;
    restart)
        "$0" stop
        sleep 2
        exec "$0" start
        ;;
    status)
        # 按固定容器名用 docker ps 判活,兼容 compose v1/v2 wrapper 差异
        # LSF 语义:0=运行中,3=未运行
        _d="$(find_docker)"
        if [ -n "$_d" ] && [ -n "$("$_d" ps --filter 'name=pigeonbox-server' --filter 'name=pigeonbox-frontend' --filter 'status=running' -q 2>/dev/null)" ]; then
            exit 0
        fi
        exit 3
        ;;
    remove)
        # 卸载:停并移除容器(不动镜像与数据;数据在卷根 pigeonbox/ 目录)
        compose_run down --remove-orphans >/dev/null 2>&1 || true
        exit 0
        ;;
esac
exit 1

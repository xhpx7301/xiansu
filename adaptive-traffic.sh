#!/usr/bin/env bash
# Adaptive traffic controller for Linux servers.
# It monitors /proc/net/dev, applies a staged egress rate with tc, and can
# optionally fill an hourly inbound target with downloads from a configured URL.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.1.0"
readonly CONFIG_DIR="/etc/adaptive-traffic"
readonly CONFIG_FILE="$CONFIG_DIR/config.env"
readonly STATE_FILE="$CONFIG_DIR/state.env"
readonly LOG_FILE="$CONFIG_DIR/adaptive-traffic.log"
readonly PID_FILE="$CONFIG_DIR/adaptive-traffic.pid"
readonly SERVICE_FILE="/etc/systemd/system/adaptive-traffic.service"
readonly INSTALL_PATH="/usr/local/bin/adaptive-traffic.sh"
readonly SHORTCUT_PATH="/usr/local/bin/xs"
readonly SCRIPT_URL="https://raw.githubusercontent.com/xhpx7301/xiansu/main/adaptive-traffic.sh"

log() {
    mkdir -p "$CONFIG_DIR"
    printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"
}

die() { log "ERROR: $*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "请以 root 运行"; }

have() { command -v "$1" >/dev/null 2>&1; }

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        mkdir -p "$CONFIG_DIR"
        cat > "$CONFIG_FILE" <<'EOF'
# 网卡留空时自动使用默认路由的网卡
IFACE=""
# 限速阶段：速率 Mbps，持续秒数；最后一个阶段 0 表示持续运行
RATE_STAGES="160:15,80:15,40:0"
# 只有达到该吞吐率才推进限速阶段；低于该值持续 RECOVERY_SECONDS 后恢复第一阶段
RECOVERY_RATE_MBPS=5
RECOVERY_SECONDS=30
# egress 只限制出站；both 同时把入站导入 IFB 后限速
DIRECTION="egress"
# 是否按小时补充入站流量。false 时只统计和限速
DOWNLOAD_ENABLED=false
# 目标为：每小时入站比出站多三分之一，即入站至少达到出站的 4/3
DOWNLOAD_RX_FRACTION=1.333333
# 每小时下载上限，0 表示不设上限；不设上限才能在高流量时完成 4/3 目标
MAX_DOWNLOAD_BYTES_PER_HOUR=0
# 腾讯镜像中的公开 npm 包；可替换为你有权访问的腾讯对象/软件包 URL
DOWNLOAD_URL="https://mirrors.tencent.com/npm/lodash/-/lodash-4.17.21.tgz"
# 下载请求的速率上限，curl 使用字节/秒；5000000 约等于 40 Mbps
DOWNLOAD_RATE_LIMIT="5000000"
# 每轮最多运行的下载秒数，防止异常 URL 长时间阻塞
DOWNLOAD_TIMEOUT_SECONDS=1800
EOF
        log "已创建默认配置：$CONFIG_FILE"
    fi
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    IFACE="${IFACE:-}"
    RATE_STAGES="${RATE_STAGES:-160:15,80:15,40:0}"
    RECOVERY_RATE_MBPS="${RECOVERY_RATE_MBPS:-5}"
    RECOVERY_SECONDS="${RECOVERY_SECONDS:-30}"
    DIRECTION="${DIRECTION:-egress}"
    DOWNLOAD_ENABLED="${DOWNLOAD_ENABLED:-false}"
    DOWNLOAD_RX_FRACTION="${DOWNLOAD_RX_FRACTION:-1.333333}"
    MAX_DOWNLOAD_BYTES_PER_HOUR="${MAX_DOWNLOAD_BYTES_PER_HOUR:-0}"
    DOWNLOAD_URL="${DOWNLOAD_URL:-}"
    DOWNLOAD_RATE_LIMIT="${DOWNLOAD_RATE_LIMIT:-5000000}"
    DOWNLOAD_TIMEOUT_SECONDS="${DOWNLOAD_TIMEOUT_SECONDS:-1800}"
}

validate_config() {
    [[ "$DIRECTION" == egress || "$DIRECTION" == both ]] || die "DIRECTION 必须是 egress 或 both"
    [[ "$RECOVERY_SECONDS" =~ ^[0-9]+$ ]] || die "RECOVERY_SECONDS 必须是整数"
    [ "$RECOVERY_SECONDS" -gt 0 ] || die "RECOVERY_SECONDS 必须大于 0"
    awk -v x="$RECOVERY_RATE_MBPS" 'BEGIN { exit !(x >= 0) }' || die "RECOVERY_RATE_MBPS 必须是非负数"
    [[ "$MAX_DOWNLOAD_BYTES_PER_HOUR" =~ ^[0-9]+$ ]] || die "MAX_DOWNLOAD_BYTES_PER_HOUR 必须是整数"
    [[ "$DOWNLOAD_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "DOWNLOAD_TIMEOUT_SECONDS 必须是整数"
    awk -v x="$DOWNLOAD_RX_FRACTION" 'BEGIN { exit !(x >= 0 && x <= 10) }' || die "DOWNLOAD_RX_FRACTION 必须在 0 到 10 之间"
    [ -n "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_ENABLED" != true ] || die "DOWNLOAD_URL 不能为空"
    local stage rate seconds
    IFS=',' read -ra stages <<< "$RATE_STAGES"
    [ "${#stages[@]}" -gt 0 ] || die "RATE_STAGES 不能为空"
    for stage in "${stages[@]}"; do
        rate="${stage%%:*}"; seconds="${stage#*:}"
        [[ "$rate" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "限速阶段格式错误：$stage"
        [[ "$seconds" =~ ^[0-9]+$ ]] || die "限速阶段持续时间错误：$stage"
        awk -v x="$rate" 'BEGIN { exit !(x > 0) }' || die "限速必须大于 0：$stage"
    done
}

detect_iface() {
    if [ -n "$IFACE" ]; then
        ip link show dev "$IFACE" >/dev/null 2>&1 || die "网卡不存在：$IFACE"
        printf '%s' "$IFACE"
        return
    fi
    ip route show default 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

read_counters() {
    local iface="$1"
    awk -v dev="$iface:" '$1 == dev {print $2, $10; found=1} END {if (!found) print "0 0"}' /proc/net/dev
}

rate_to_tc() {
    awk -v rate="$1" 'BEGIN { printf "%.3fmbit", rate }'
}

apply_rate() {
    local iface="$1" rate="$2"
    local tc_rate burst
    tc_rate="$(rate_to_tc "$rate")"
    burst="$(awk -v r="$rate" 'BEGIN {b=r*1000000/8/10; if (b<12000)b=12000; if (b>1048576)b=1048576; printf "%d", b}')"
    tc qdisc replace dev "$iface" root handle 1: tbf rate "$tc_rate" burst "${burst}b" latency 50ms

    if [ "$DIRECTION" = both ]; then
        if ! ip link show ifb-at >/dev/null 2>&1; then
            modprobe ifb numifbs=1 2>/dev/null || true
            ip link add ifb-at type ifb 2>/dev/null || true
        fi
        ip link set dev ifb-at up
        tc qdisc replace dev "$iface" handle ffff: ingress
        tc filter replace dev "$iface" parent ffff: protocol all flower action mirred egress redirect dev ifb-at
        tc qdisc replace dev ifb-at root handle 1: tbf rate "$tc_rate" burst "${burst}b" latency 50ms
    fi
}

cleanup_tc() {
    local iface="$1"
    tc qdisc del dev "$iface" root 2>/dev/null || true
    if [ "$DIRECTION" = both ]; then
        tc filter del dev "$iface" parent ffff: 2>/dev/null || true
        tc qdisc del dev "$iface" ingress 2>/dev/null || true
        tc qdisc del dev ifb-at root 2>/dev/null || true
        ip link del ifb-at 2>/dev/null || true
    fi
}

stage_rate() {
    local elapsed="$1" stage rate seconds total=0
    IFS=',' read -ra stages <<< "$RATE_STAGES"
    for stage in "${stages[@]}"; do
        rate="${stage%%:*}"; seconds="${stage#*:}"
        if [ "$seconds" -eq 0 ] || [ "$elapsed" -lt $((total + seconds)) ]; then
            printf '%s' "$rate"
            return
        fi
        total=$((total + seconds))
    done
    printf '%s' "${stages[-1]%%:*}"
}

state_get() {
    local key="$1" default="$2"
    [ -f "$STATE_FILE" ] || { printf '%s' "$default"; return; }
    awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; found=1; exit} END {if (!found) exit 1}' "$STATE_FILE" 2>/dev/null || printf '%s' "$default"
}

state_set() {
    local key="$1" value="$2" tmp
    mkdir -p "$CONFIG_DIR"
    tmp="$(mktemp "$CONFIG_DIR/state.XXXXXX")"
    if [ -f "$STATE_FILE" ]; then awk -F= -v k="$key" -v v="$value" '$1 != k {print} $1 == k {print k "=" v; found=1} END {if (!found) print k "=" v}' "$STATE_FILE" > "$tmp"; else printf '%s=%s\n' "$key" "$value" > "$tmp"; fi
    mv "$tmp" "$STATE_FILE"
}

download_deficit() {
    local rx="$2" tx="$3" baseline_rx baseline_tx hour_rx hour_tx target deficit
    baseline_rx="$(state_get HOUR_START_RX 0)"; baseline_tx="$(state_get HOUR_START_TX 0)"
    hour_rx=$((rx - baseline_rx)); hour_tx=$((tx - baseline_tx))
    [ "$hour_rx" -ge 0 ] || hour_rx=0; [ "$hour_tx" -ge 0 ] || hour_tx=0
    target="$(awk -v tx="$hour_tx" -v fraction="$DOWNLOAD_RX_FRACTION" 'BEGIN {printf "%.0f", tx*fraction}')"
    deficit=$((target - hour_rx)); [ "$deficit" -gt 0 ] || deficit=0
    if [ "$MAX_DOWNLOAD_BYTES_PER_HOUR" -gt 0 ] && [ "$deficit" -gt "$MAX_DOWNLOAD_BYTES_PER_HOUR" ]; then deficit="$MAX_DOWNLOAD_BYTES_PER_HOUR"; fi
    printf '%s' "$deficit"
}

download_until_target() {
    local iface="$1" hour="$2" rx="$3" tx="$4" deficit before after got remaining curl_args
    [ "$DOWNLOAD_ENABLED" = true ] || return 0
    deficit="$(download_deficit "$iface" "$rx" "$tx")"
    [ "$deficit" -gt 0 ] || return 0
    log "小时目标缺口：${deficit} bytes，开始下载：$DOWNLOAD_URL"
    before="$(read_counters "$iface" | awk '{print $1}')"
    curl_args=(-fL --retry 2 --connect-timeout 15 --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -sS)
    [ -n "$DOWNLOAD_RATE_LIMIT" ] && curl_args+=(--limit-rate "$DOWNLOAD_RATE_LIMIT")
    # 重复请求，直到网卡收到的字节数达到缺口或 curl 失败。
    while [ "$deficit" -gt 0 ]; do
        curl "${curl_args[@]}" "$DOWNLOAD_URL" -o /dev/null || { log "下载失败，下一小时重试"; break; }
        after="$(read_counters "$iface" | awk '{print $1}')"
        got=$((after - before)); [ "$got" -ge 0 ] || got=0
        [ "$got" -gt 0 ] || break
        remaining=$((deficit - got)); deficit="$remaining"
        before="$after"
        [ "$deficit" -gt 0 ] || break
    done
    log "本轮下载结束，剩余缺口：$((deficit > 0 ? deficit : 0)) bytes"
}

run() {
    have ip || die "缺少 iproute2（ip 命令）"
    have tc || die "缺少 iproute2（tc 命令）"
    have awk || die "缺少 awk"
    have curl || die "缺少 curl"
    load_config; validate_config
    local iface elapsed=0 low_rate_seconds=0 current_rate="" prev_rx prev_tx rx tx delta sample_mbps hour last_download_check=0
    iface="$(detect_iface)"; [ -n "$iface" ] || die "无法检测默认路由网卡"
    echo "$$" > "$PID_FILE"
    trap 'cleanup_tc "$iface"; rm -f "$PID_FILE"' EXIT INT TERM
    read -r prev_rx prev_tx <<< "$(read_counters "$iface")"
    log "启动 v$SCRIPT_VERSION，网卡=$iface，方向=$DIRECTION，阶段=$RATE_STAGES"
    while :; do
        read -r rx tx <<< "$(read_counters "$iface")"
        delta=$(( (rx - prev_rx) + (tx - prev_tx) )); [ "$delta" -ge 0 ] || delta=0
        sample_mbps="$(awk -v bytes="$delta" 'BEGIN {printf "%.6f", bytes*8/1000000}')"
        if awk -v sample="$sample_mbps" -v threshold="$RECOVERY_RATE_MBPS" 'BEGIN {exit !(sample < threshold)}'; then
            low_rate_seconds=$((low_rate_seconds + 1))
        else
            low_rate_seconds=0
            elapsed=$((elapsed + 1))
        fi
        if [ "$low_rate_seconds" -ge "$RECOVERY_SECONDS" ] && [ "$elapsed" -gt 0 ]; then
            elapsed=0
            low_rate_seconds=0
            log "流量恢复：连续 ${RECOVERY_SECONDS}s 低于 ${RECOVERY_RATE_MBPS} Mbps，重新应用第一阶段"
        fi
        current_rate="$(stage_rate "$elapsed")"
        if [ "$current_rate" != "${APPLIED_RATE:-}" ]; then
            apply_rate "$iface" "$current_rate"
            APPLIED_RATE="$current_rate"
            log "应用限速：${current_rate} Mbps（活跃 ${elapsed}s）"
        fi
        hour="$(date -u +%Y%m%d%H)"
        if [ "$(state_get HOUR 0)" != "$hour" ]; then
            state_set HOUR "$hour"; state_set HOUR_START_RX "$rx"; state_set HOUR_START_TX "$tx"
            last_download_check=0
            log "开始统计 UTC 小时 $hour，基线 rx=$rx tx=$tx"
        fi
        if [ "$DOWNLOAD_ENABLED" = true ] && [ $(( $(date +%s) - last_download_check )) -ge 60 ]; then
            download_until_target "$iface" "$hour" "$rx" "$tx"
            last_download_check="$(date +%s)"
        fi
        prev_rx="$rx"; prev_tx="$tx"
        sleep 1
    done
}

install_script_file() {
    local source_script="${BASH_SOURCE[0]:-}" temp_file
    mkdir -p "$(dirname "$INSTALL_PATH")"

    if [ -f "$source_script" ] && [[ "$source_script" != /dev/fd/* ]]; then
        source_script="$(readlink -f "$source_script" 2>/dev/null || printf '%s' "$source_script")"
        if [ "$source_script" != "$INSTALL_PATH" ]; then
            install -m 0755 "$source_script" "$INSTALL_PATH"
        else
            chmod 0755 "$INSTALL_PATH"
        fi
    else
        temp_file="$(mktemp)"
        if ! curl -fsSL --connect-timeout 15 --max-time 120 "$SCRIPT_URL" -o "$temp_file"; then
            rm -f "$temp_file"
            die "无法从 GitHub 下载最新脚本：$SCRIPT_URL"
        fi
        if ! bash -n "$temp_file"; then
            rm -f "$temp_file"
            die "GitHub 返回的脚本语法检查失败"
        fi
        install -m 0755 "$temp_file" "$INSTALL_PATH"
        rm -f "$temp_file"
    fi
    ln -sfn "$INSTALL_PATH" "$SHORTCUT_PATH"
}

write_service_file() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Adaptive staged traffic controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH run
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

install_service() {
    need_root
    have curl || die "安装和更新需要 curl"
    install_script_file
    load_config
    mkdir -p "$CONFIG_DIR"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    write_service_file
    systemctl daemon-reload
    systemctl enable --now adaptive-traffic.service
    log "服务已安装并启动：adaptive-traffic.service"
    log "快捷命令：xs；脚本路径：$INSTALL_PATH"
}

update_script() {
    need_root
    have curl || die "更新需要 curl"
    local temp_file remote_version current_version
    temp_file="$(mktemp)"
    echo "正在从 GitHub 获取最新脚本..."
    if ! curl -fsSL --connect-timeout 15 --max-time 120 "$SCRIPT_URL" -o "$temp_file"; then
        rm -f "$temp_file"
        die "下载失败：$SCRIPT_URL"
    fi
    if ! bash -n "$temp_file"; then
        rm -f "$temp_file"
        die "远程脚本语法检查失败，已取消更新"
    fi
    current_version="$(grep -E '^readonly SCRIPT_VERSION=' "$INSTALL_PATH" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
    remote_version="$(grep -E '^readonly SCRIPT_VERSION=' "$temp_file" | head -1 | cut -d'"' -f2 || true)"
    install -m 0755 "$temp_file" "$INSTALL_PATH"
    rm -f "$temp_file"
    ln -sfn "$INSTALL_PATH" "$SHORTCUT_PATH"
    if systemctl is-enabled adaptive-traffic.service >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl restart adaptive-traffic.service
    fi
    echo "更新完成：${current_version:-未知} -> ${remote_version:-未知}"
    log "脚本已从 GitHub 更新：${current_version:-未知} -> ${remote_version:-未知}"
}

uninstall_service() {
    need_root
    systemctl disable --now adaptive-traffic.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -f "$SHORTCUT_PATH" "$INSTALL_PATH"
    systemctl daemon-reload
    log "服务、快捷命令和安装脚本已移除；配置和日志保留在 $CONFIG_DIR"
}

status() {
    load_config
    printf '配置：%s\n' "$CONFIG_FILE"
    local service_state iface
    service_state="$(systemctl is-active adaptive-traffic.service 2>/dev/null || true)"
    printf '服务：%s\n' "${service_state:-未安装或未运行}"
    printf '快捷命令：%s\n' "$(if [ -L "$SHORTCUT_PATH" ]; then echo "已安装 ($SHORTCUT_PATH)"; else echo '未安装'; fi)"
    printf '限速方向：%s\n' "$DIRECTION"
    printf '限速阶段：%s\n' "$RATE_STAGES"
    printf '恢复条件：低于 %s Mbps 持续 %ss\n' "$RECOVERY_RATE_MBPS" "$RECOVERY_SECONDS"
    printf '不对等补充：%s，目标入站/出站=%s，下载限速=%s bytes/s\n' "$DOWNLOAD_ENABLED" "$DOWNLOAD_RX_FRACTION" "${DOWNLOAD_RATE_LIMIT:-不限速}"
    if have ip && iface="$(detect_iface 2>/dev/null)" && [ -n "$iface" ]; then
        printf '网卡：%s\n' "$iface"
    fi
    printf '状态文件：%s\n' "$STATE_FILE"
    [ -f "$STATE_FILE" ] && cat "$STATE_FILE"
    printf '最近日志：\n'; tail -n 20 "$LOG_FILE" 2>/dev/null || true
}

pause_menu() {
    read -r -p "按回车返回菜单..." _ || true
}

show_tc_status() {
    need_root
    load_config
    local iface
    iface="$(detect_iface)" || return 1
    [ -n "$iface" ] || die "无法检测默认路由网卡"
    echo "网卡：$iface"
    tc -s qdisc show dev "$iface"
    if [ "$DIRECTION" = both ] && ip link show ifb-at >/dev/null 2>&1; then
        echo
        echo "IFB 入站整形：ifb-at"
        tc -s qdisc show dev ifb-at
    fi
}

edit_config() {
    need_root
    load_config
    local editor="${EDITOR:-}"
    if [ -z "$editor" ]; then
        if have nano; then editor=nano; elif have vi; then editor=vi; else die "未找到 nano 或 vi"; fi
    fi
    "$editor" "$CONFIG_FILE"
}

service_action() {
    need_root
    local action="$1"
    systemctl "$action" adaptive-traffic.service
    echo "服务操作完成：$action"
}

show_menu() {
    need_root
    load_config
    while true; do
        clear 2>/dev/null || true
        echo "=============================================="
        echo "        自适应限速与流量管理菜单"
        echo "=============================================="
        echo "  1. 查看服务状态、配置和最近日志"
        echo "  2. 启动服务"
        echo "  3. 停止服务并清理限速"
        echo "  4. 重启服务并应用配置"
        echo "  5. 查看实时服务日志"
        echo "  6. 查看 tc 限速统计"
        echo "  7. 编辑配置文件"
        echo "  8. 从 GitHub 获取最新脚本"
        echo "  9. 卸载服务和 xs 快捷命令"
        echo "  0. 退出"
        echo
        read -r -p "请选择 [0-9]: " choice
        case "$choice" in
            1) status; pause_menu ;;
            2) service_action start || true; pause_menu ;;
            3) service_action stop || true; pause_menu ;;
            4) service_action restart || true; pause_menu ;;
            5) journalctl -u adaptive-traffic.service -f || true ;;
            6) show_tc_status || true; pause_menu ;;
            7) edit_config; echo "配置已编辑，选择 4 重启服务后生效。"; pause_menu ;;
            8) update_script; exec "$INSTALL_PATH" menu ;;
            9) uninstall_service; echo "卸载完成。"; return 0 ;;
            0) return 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

usage() {
    cat <<EOF
用法：sudo $0 <命令>

命令：
  install      创建默认配置并安装 systemd 服务
  menu         打开交互式管理菜单
  run          前台运行控制器（服务会调用此命令）
  status       查看服务、小时计数和最近日志
  update       从 GitHub 获取最新脚本
  uninstall    停止并移除服务，保留配置和日志

安装后编辑：$CONFIG_FILE
EOF
}

case "${1:-}" in
    install) install_service ;;
    ''|menu|xs) show_menu ;;
    run) need_root; run ;;
    status) status ;;
    update) update_script ;;
    uninstall) uninstall_service ;;
    *) usage; exit 2 ;;
esac

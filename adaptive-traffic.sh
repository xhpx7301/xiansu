#!/usr/bin/env bash
# Adaptive traffic controller for Linux servers.
# It monitors /proc/net/dev, applies a staged egress rate with tc, and can
# optionally fill an hourly inbound target with downloads from a configured URL.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.2.7"
readonly CONFIG_DIR="/etc/adaptive-traffic"
readonly CONFIG_FILE="$CONFIG_DIR/config.env"
readonly STATE_FILE="$CONFIG_DIR/state.env"
readonly LOG_FILE="$CONFIG_DIR/adaptive-traffic.log"
readonly PID_FILE="$CONFIG_DIR/adaptive-traffic.pid"
readonly SERVICE_FILE="/etc/systemd/system/adaptive-traffic.service"
readonly INSTALL_PATH="/usr/local/bin/adaptive-traffic.sh"
readonly SHORTCUT_PATH="/usr/local/bin/xs"
readonly SCRIPT_URL="https://raw.githubusercontent.com/xhpx7301/xiansu/main/adaptive-traffic.sh"
COLOR_OUTPUT=0
RUN_IFACE=''

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
# 是否按小时补充入站流量。默认开启；false 时只统计和限速
DOWNLOAD_ENABLED=true
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
    DOWNLOAD_ENABLED="${DOWNLOAD_ENABLED:-true}"
    DOWNLOAD_RX_FRACTION="${DOWNLOAD_RX_FRACTION:-1.333333}"
    MAX_DOWNLOAD_BYTES_PER_HOUR="${MAX_DOWNLOAD_BYTES_PER_HOUR:-0}"
    DOWNLOAD_URL="${DOWNLOAD_URL:-}"
    DOWNLOAD_RATE_LIMIT="${DOWNLOAD_RATE_LIMIT-5000000}"
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

cleanup_run() {
    if [ -n "${RUN_IFACE:-}" ]; then
        cleanup_tc "$RUN_IFACE"
    fi
    state_set CURRENT_RATE none
    state_set ACTIVE_SECONDS 0
    rm -f "$PID_FILE"
    RUN_IFACE=''
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

format_bytes() {
    awk -v bytes="${1:-0}" 'BEGIN {
        if (bytes < 0) bytes = 0
        if (bytes >= 1099511627776) printf "%.2f TiB", bytes / 1099511627776
        else if (bytes >= 1073741824) printf "%.2f GiB", bytes / 1073741824
        else if (bytes >= 1048576) printf "%.2f MiB", bytes / 1048576
        else if (bytes >= 1024) printf "%.2f KiB", bytes / 1024
        else printf "%.0f B", bytes
    }'
}

show_dashboard() {
    load_config
    local iface service_state hour state_hour rx_base tx_base rx tx hour_rx hour_tx target gap ratio rate rate_label active_seconds download_state direction_text service_color download_color gap_color
    local blue='' green='' yellow='' cyan='' dim='' reset=''
    if [ "$COLOR_OUTPUT" -eq 1 ] || [ -t 1 ]; then
        blue=$'\033[94m'; green=$'\033[92m'; yellow=$'\033[93m'; cyan=$'\033[96m'
        dim=$'\033[92m'; reset=$'\033[0m'
    fi

    iface="$(detect_iface 2>/dev/null || true)"
    [ -n "$iface" ] || iface="unknown"
    service_state="$(systemctl is-active adaptive-traffic.service 2>/dev/null || true)"
    [ -n "$service_state" ] || service_state="inactive"
    hour="$(date -u +%Y%m%d%H)"
    state_hour="$(state_get HOUR 0)"
    IFS=' ' read -r rx tx <<< "$(read_counters "$iface" 2>/dev/null || printf '0 0')"
    rx="${rx:-0}"; tx="${tx:-0}"
    rx_base="$(state_get HOUR_START_RX 0)"
    tx_base="$(state_get HOUR_START_TX 0)"
    if [ "$state_hour" = "$hour" ]; then
        hour_rx=$((rx - rx_base)); hour_tx=$((tx - tx_base))
        [ "$hour_rx" -ge 0 ] || hour_rx=0
        [ "$hour_tx" -ge 0 ] || hour_tx=0
    else
        hour_rx=0; hour_tx=0
    fi
    target="$(awk -v tx="$hour_tx" -v fraction="$DOWNLOAD_RX_FRACTION" 'BEGIN {printf "%.0f", tx*fraction}')"
    gap=$((target - hour_rx)); [ "$gap" -gt 0 ] || gap=0
    if [ "$hour_tx" -gt 0 ]; then
        ratio="$(awk -v rx="$hour_rx" -v tx="$hour_tx" 'BEGIN {printf "%.1f%%", rx/tx*100}')"
    else
        ratio="--"
    fi
    rate="$(state_get CURRENT_RATE none)"
    active_seconds="$(state_get ACTIVE_SECONDS 0)"
    if [ "$rate" = "none" ]; then
        if [ "$service_state" = activating ]; then rate_label="启动中"; else rate_label="未运行"; fi
    else
        rate_label="${rate} Mbps"
    fi
    [ "$DIRECTION" = both ] && direction_text="双向" || direction_text="出站"
    if [ "$service_state" = active ]; then service_color="$green"; else service_color="$yellow"; fi
    if [ "$DOWNLOAD_ENABLED" = true ]; then download_state="已开启"; download_color="$green"; else download_state="已关闭"; download_color="$dim"; fi
    if [ "$gap" -eq 0 ]; then gap_color="$green"; else gap_color="$yellow"; fi

    printf '%s=== 自适应限速与流量管理 v%s ===%s\n' "$blue" "$SCRIPT_VERSION" "$reset"
    printf '%s服务：%s%-10s%s | 网卡：%s%-12s%s | 限速方向：%s%s%s\n' \
        "$dim" "$service_color" "$service_state" "$reset" "$cyan" "$iface" "$reset" "$yellow" "$direction_text" "$reset"
    printf '当前限速：%s%s%s | 活跃计时：%s%ss%s | 阶段：%s%s%s\n' \
        "$yellow" "$rate_label" "$reset" "$yellow" "$active_seconds" "$reset" "$cyan" "$RATE_STAGES" "$reset"
    printf '恢复条件：低于 %s%s Mbps%s 持续 %s%s 秒%s | 当前小时 (UTC)：%s%s%s\n' \
        "$yellow" "$RECOVERY_RATE_MBPS" "$reset" "$yellow" "$RECOVERY_SECONDS" "$reset" "$cyan" "$hour" "$reset"
    printf '%s整机流量：%s%s%s | 入站(RX)：%s%s%s | 出站(TX)：%s%s%s | 入/出：%s%s%s\n' \
        "$dim" "$cyan" "$iface" "$reset" "$cyan" "$(format_bytes "$hour_rx")" "$reset" "$yellow" "$(format_bytes "$hour_tx")" "$reset" "$green" "$ratio" "$reset"
    printf '目标入站：出站 × %s%s%s = %s%s%s | 待补缺口：%s%s%s\n' \
        "$yellow" "$DOWNLOAD_RX_FRACTION" "$reset" "$green" "$(format_bytes "$target")" "$reset" "$gap_color" "$(format_bytes "$gap")" "$reset"
    printf '补充下载：%s%s%s | 速率上限：%s%s Mbps%s | 来源：%s腾讯镜像%s\n' \
        "$download_color" "$download_state" "$reset" "$yellow" "$(awk -v bytes="${DOWNLOAD_RATE_LIMIT:-0}" 'BEGIN {if (bytes > 0) printf "%.1f", bytes*8/1000000; else printf "不限速"}')" "$reset" "$blue" "$reset"
    printf '%s------------------------------------------------------------%s\n' "$dim" "$reset"
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
    local iface elapsed=0 low_rate_seconds=0 current_rate="" prev_rx prev_tx rx tx delta sample_mbps hour last_download_check=0 last_state_seconds=-1
    iface="$(detect_iface)"; [ -n "$iface" ] || die "无法检测默认路由网卡"
    RUN_IFACE="$iface"
    echo "$$" > "$PID_FILE"
    trap cleanup_run EXIT
    trap 'exit 0' INT TERM
    IFS=' ' read -r prev_rx prev_tx <<< "$(read_counters "$iface")"
    prev_rx="${prev_rx:-0}"; prev_tx="${prev_tx:-0}"
    log "启动 v$SCRIPT_VERSION，网卡=$iface，方向=$DIRECTION，阶段=$RATE_STAGES"
    while :; do
        IFS=' ' read -r rx tx <<< "$(read_counters "$iface")"
        rx="${rx:-0}"; tx="${tx:-0}"
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
            state_set CURRENT_RATE "$current_rate"
            log "应用限速：${current_rate} Mbps（活跃 ${elapsed}s）"
        fi
        if [ "$elapsed" -ne "$last_state_seconds" ] && { [ $((elapsed % 5)) -eq 0 ] || [ "$current_rate" != "${APPLIED_RATE_BEFORE:-}" ]; }; then
            state_set CURRENT_RATE "$current_rate"
            state_set ACTIVE_SECONDS "$elapsed"
            last_state_seconds="$elapsed"
        fi
        APPLIED_RATE_BEFORE="$current_rate"
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
    local source_script="${BASH_SOURCE[0]:-}" temp_file fetch_url
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
        fetch_url="${SCRIPT_URL}?_=$(date +%s)"
        if ! curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' --connect-timeout 15 --max-time 120 "$fetch_url" -o "$temp_file"; then
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
    local temp_file remote_version current_version fetch_url
    temp_file="$(mktemp)"
    echo "正在从 GitHub 获取最新脚本..."
    fetch_url="${SCRIPT_URL}?_=$(date +%s)"
    if ! curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' --connect-timeout 15 --max-time 120 "$fetch_url" -o "$temp_file"; then
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
    echo "当前安装路径：$INSTALL_PATH；快捷命令：$SHORTCUT_PATH"
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
    show_dashboard
    printf '配置文件：%s\n' "$CONFIG_FILE"
    printf '快捷命令：%s\n' "$(if [ -L "$SHORTCUT_PATH" ]; then echo "已安装 ($SHORTCUT_PATH)"; else echo '未安装'; fi)"
    printf '最近日志：\n'; tail -n 20 "$LOG_FILE" 2>/dev/null || true
}

pause_menu() {
    read -r -p "按回车返回菜单..." _ || true
}

menu_option() {
    local number="$1" label="$2" blue='' green='' reset=''
    if [ "$COLOR_OUTPUT" -eq 1 ] || [ -t 1 ]; then
        blue=$'\033[94m'; green=$'\033[92m'; reset=$'\033[0m'
    fi
    printf '  %s%s%s. %s%s%s\n' "$blue" "$number" "$reset" "$green" "$label" "$reset"
}

show_tc_status() {
    need_root
    load_config
    local iface
    iface="$(detect_iface)" || return 1
    [ -n "$iface" ] || die "无法检测默认路由网卡"
    show_one_tc_stats "$iface" "出站网卡"
    if [ "$DIRECTION" = both ] && ip link show ifb-at >/dev/null 2>&1; then
        echo
        show_one_tc_stats ifb-at "入站整形 IFB"
    fi
}

show_one_tc_stats() {
    local iface="$1" label="$2" raw kind handle rate burst latency bytes packets drops overlimits backlog
    echo "[$label：$iface]"
    raw="$(tc -s qdisc show dev "$iface" 2>/dev/null || true)"
    if [ -z "$raw" ]; then
        echo "  未发现流量队列规则。"
        return 0
    fi
    while IFS=$'\t' read -r kind handle rate burst latency bytes packets drops overlimits backlog; do
        [ -n "$kind" ] || continue
        case "$kind" in
            tbf) kind="TBF 令牌桶" ;;
            fq_codel) kind="FQ-CoDel 公平队列" ;;
            fq) kind="FQ 公平队列" ;;
            pfifo_fast) kind="PFIFO_FAST 先进先出" ;;
            noqueue) kind="无队列" ;;
            *) kind="$kind 队列" ;;
        esac
        printf '  队列类型：%s（句柄 %s）\n' "$kind" "$handle"
        if [ -n "$rate" ]; then printf '  限速速率：%s\n' "$rate"; else echo '  限速速率：队列未声明固定速率'; fi
        [ -n "$burst" ] && printf '  突发额度：%s\n' "$burst"
        [ -n "$latency" ] && printf '  队列延迟：%s\n' "$latency"
        printf '  累计发送：%s | 数据包：%s\n' "$(format_bytes "${bytes:-0}")" "${packets:-0}"
        printf '  丢包：%s | 超限次数：%s | 当前积压：%s\n' "${drops:-0}" "${overlimits:-0}" "${backlog:-0}"
    done < <(printf '%s\n' "$raw" | awk '
        function emit() { if (kind != "") print kind "\t" handle "\t" rate "\t" burst "\t" latency "\t" bytes "\t" packets "\t" drops "\t" overlimits "\t" backlog }
        /^qdisc / { kind=$2; handle=$3; rate=""; burst=""; latency=""; bytes=0; packets=0; drops=0; overlimits=0; backlog="0b"; for (i=1;i<=NF;i++) {if ($i=="rate") rate=$(i+1); if ($i=="burst") burst=$(i+1); if ($i=="lat") latency=$(i+1)} }
        /^ Sent / { for (i=1;i<=NF;i++) {if ($i=="Sent") bytes=$(i+1); if ($i=="pkt") packets=$(i-1); if ($i ~ /dropped/) {v=$(i+1); gsub(/[(),]/,"",v); drops=v} if ($i=="overlimits") {v=$(i+1); gsub(/[(),]/,"",v); overlimits=v}} }
        /^ backlog / {backlog=$2; emit(); kind=""}
        END {emit()}
    ')
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

set_config_value() {
    local key="$1" rhs="$2" temp_file
    temp_file="$(mktemp "$CONFIG_DIR/config.XXXXXX")"
    awk -F= -v key="$key" -v rhs="$rhs" '$1 == key {print key "=" rhs; found=1; next} {print} END {if (!found) print key "=" rhs}' "$CONFIG_FILE" > "$temp_file"
    if ! bash -n "$temp_file" 2>/dev/null; then
        rm -f "$temp_file"
        echo "配置文件语法校验失败，未保存。" >&2
        return 1
    fi
    if ! (set -a; . "$temp_file"; set +a; [[ "${DIRECTION:-egress}" == egress || "${DIRECTION:-egress}" == both ]]; [[ "${RECOVERY_SECONDS:-30}" =~ ^[0-9]+$ ]] && [ "${RECOVERY_SECONDS:-30}" -gt 0 ]; [[ "${MAX_DOWNLOAD_BYTES_PER_HOUR:-0}" =~ ^[0-9]+$ ]]; [[ "${DOWNLOAD_ENABLED:-true}" == true || "${DOWNLOAD_ENABLED:-true}" == false ]]; awk -v x="${RECOVERY_RATE_MBPS:-5}" 'BEGIN {exit !(x >= 0)}'; awk -v x="${DOWNLOAD_RX_FRACTION:-1.333333}" 'BEGIN {exit !(x >= 0 && x <= 10)}'; [ -n "${DOWNLOAD_URL:-}" ] || [ "${DOWNLOAD_ENABLED:-true}" != true ]); then
        rm -f "$temp_file"
        echo "配置值校验失败，未保存。" >&2
        return 1
    fi
    chmod 600 "$temp_file"
    mv "$temp_file" "$CONFIG_FILE"
    load_config
    validate_config
    if systemctl is-active --quiet adaptive-traffic.service 2>/dev/null; then
        systemctl restart adaptive-traffic.service
        echo "配置已保存，服务已重启应用。"
    else
        echo "配置已保存；服务当前未运行，启动或重启服务后生效。"
    fi
}

configure_one() {
    local key="$1" title="$2" current value rhs
    current="${!key:-}"
    read -r -p "$title [$current]: " value
    [ -n "$value" ] || { echo "未修改。"; return 0; }
    rhs="$value"
    case "$key" in
        IFACE)
            if [ "$value" = auto ]; then
                rhs='""'
            else
                [[ "$value" =~ ^[A-Za-z0-9_.:-]+$ ]] || { echo "网卡名称格式无效。"; return 1; }
                ip link show dev "$value" >/dev/null 2>&1 || { echo "网卡不存在：$value"; return 1; }
                rhs="\"$value\""
            fi
            ;;
        RATE_STAGES)
            [[ "$value" =~ ^[0-9]+([.][0-9]+)?:[0-9]+(,[0-9]+([.][0-9]+)?:[0-9]+)*$ ]] || { echo '格式示例：160:15,80:15,40:0'; return 1; }
            RATE_STAGES="$value"
            validate_config || return 1
            rhs="\"$value\""
            ;;
        RECOVERY_RATE_MBPS|DOWNLOAD_RX_FRACTION)
            [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "请输入非负数字。"; return 1; }
            if [ "$key" = DOWNLOAD_RX_FRACTION ]; then
                awk -v x="$value" 'BEGIN {exit !(x <= 10)}' || { echo "比例最大为 10。"; return 1; }
            fi
            ;;
        RECOVERY_SECONDS|MAX_DOWNLOAD_BYTES_PER_HOUR)
            [[ "$value" =~ ^[0-9]+$ ]] || { echo "请输入非负整数。"; return 1; }
            [ "$key" != RECOVERY_SECONDS ] || [ "$value" -gt 0 ] || { echo "恢复秒数必须大于 0。"; return 1; }
            ;;
        DIRECTION)
            [[ "$value" == egress || "$value" == both ]] || { echo "请输入 egress 或 both。"; return 1; }
            rhs="\"$value\""
            ;;
        DOWNLOAD_ENABLED)
            [[ "$value" == true || "$value" == false ]] || { echo "请输入 true 或 false。"; return 1; }
            ;;
        DOWNLOAD_RATE_LIMIT)
            [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "请输入 Mbps 数字；输入 0 表示不限速。"; return 1; }
            if awk -v x="$value" 'BEGIN {exit !(x == 0)}'; then rhs='""'; else rhs="\"$(awk -v mbps="$value" 'BEGIN {printf "%.0f", mbps*1000000/8}')\""; fi
            ;;
        DOWNLOAD_URL)
            [[ "$value" == https://* ]] || { echo "请输入 https:// 开头的 URL。"; return 1; }
            rhs="\"$value\""
            ;;
        *) echo "不支持修改此配置项。"; return 1 ;;
    esac
    set_config_value "$key" "$rhs"
}

config_submenu() {
    local category choice
    while true; do
        clear 2>/dev/null || true
        load_config
        echo "========== 配置管理 =========="
        menu_option 1 "限速策略与网卡"
        menu_option 2 "不对等流量补充"
        menu_option 3 "编辑完整原始配置"
        menu_option 0 "返回主菜单"
        echo
        read -r -p "请选择 [0-3]: " category
        case "$category" in
            1)
                while true; do
                    clear 2>/dev/null || true
                    load_config
                    echo "====== 限速策略与网卡 ======"
                    menu_option 1 "网卡（当前：${IFACE:-自动检测}）"
                    menu_option 2 "分阶段速率（当前：$RATE_STAGES）"
                    menu_option 3 "恢复阈值（当前：$RECOVERY_RATE_MBPS Mbps）"
                    menu_option 4 "恢复等待（当前：$RECOVERY_SECONDS 秒）"
                    menu_option 5 "限速方向（当前：$DIRECTION）"
                    menu_option 0 "返回配置菜单"
                    read -r -p "请选择 [0-5]: " choice
                    case "$choice" in
                        1) configure_one IFACE "网卡名（输入 auto 自动检测）"; pause_menu ;;
                        2) configure_one RATE_STAGES "分阶段速率 Mbps:秒数"; pause_menu ;;
                        3) configure_one RECOVERY_RATE_MBPS "低于该吞吐率时开始恢复计时 (Mbps)"; pause_menu ;;
                        4) configure_one RECOVERY_SECONDS "低速持续多少秒后恢复"; pause_menu ;;
                        5) configure_one DIRECTION "输入 egress 或 both"; pause_menu ;;
                        0) break ;;
                        *) echo "无效选项"; sleep 1 ;;
                    esac
                done
                ;;
            2)
                while true; do
                    clear 2>/dev/null || true
                    load_config
                    local rate_mbps
                    rate_mbps="$(awk -v bytes="${DOWNLOAD_RATE_LIMIT:-0}" 'BEGIN {if (bytes > 0) printf "%.2f", bytes*8/1000000; else printf "0 (不限速)"}')"
                    echo "====== 不对等流量补充 ======"
                    menu_option 1 "自动补充开关（当前：$DOWNLOAD_ENABLED）"
                    menu_option 2 "入站/出站目标比例（当前：$DOWNLOAD_RX_FRACTION）"
                    menu_option 3 "每小时最大补充量（当前：$MAX_DOWNLOAD_BYTES_PER_HOUR bytes；0 为不限）"
                    menu_option 4 "下载速度上限（当前：$rate_mbps Mbps；0 为不限）"
                    menu_option 5 "腾讯镜像下载 URL"
                    menu_option 0 "返回配置菜单"
                    read -r -p "请选择 [0-5]: " choice
                    case "$choice" in
                        1) configure_one DOWNLOAD_ENABLED "启用自动下载补足？输入 true 或 false"; pause_menu ;;
                        2) configure_one DOWNLOAD_RX_FRACTION "目标入站/出站比例（1.333333 表示多三分之一）"; pause_menu ;;
                        3) configure_one MAX_DOWNLOAD_BYTES_PER_HOUR "每小时最大下载字节数（0 为不限）"; pause_menu ;;
                        4) configure_one DOWNLOAD_RATE_LIMIT "下载限速 Mbps（40 表示 40 Mbps，0 为不限）"; pause_menu ;;
                        5) configure_one DOWNLOAD_URL "下载 URL"; pause_menu ;;
                        0) break ;;
                        *) echo "无效选项"; sleep 1 ;;
                    esac
                done
                ;;
            3)
                edit_config
                load_config
                if validate_config; then
                    echo "配置校验通过。"
                else
                    echo "配置校验失败：服务不会应用当前无效配置，请修正后再重启。"
                fi
                pause_menu
                ;;
            0) return 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

service_action() {
    need_root
    local action="$1"
    if ! systemctl "$action" adaptive-traffic.service; then
        echo "服务操作失败：$action"
        journalctl -u adaptive-traffic.service -n 12 --no-pager 2>/dev/null || true
        return 1
    fi
    if [ "$action" = start ] || [ "$action" = restart ]; then
        local state i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            state="$(systemctl is-active adaptive-traffic.service 2>/dev/null || true)"
            [ "$state" = active ] && { echo "服务已启动：$action"; return 0; }
            [[ "$state" == failed || "$state" == inactive || "$state" == deactivating ]] && break
            sleep 1
        done
        echo "服务未进入运行状态，当前状态：${state:-未知}"
        journalctl -u adaptive-traffic.service -n 12 --no-pager 2>/dev/null || true
        return 1
    fi
    echo "服务操作完成：$action"
}

show_menu() {
    need_root
    COLOR_OUTPUT=1
    load_config
    while true; do
        clear 2>/dev/null || true
        show_dashboard
        menu_option 1 "查看服务状态、配置和最近日志"
        menu_option 2 "启动服务"
        menu_option 3 "停止服务并清理限速"
        menu_option 4 "重启服务并应用配置"
        menu_option 5 "查看实时服务日志"
        menu_option 6 "查看 tc 限速统计"
        menu_option 7 "配置管理（二级菜单）"
        menu_option 8 "从 GitHub 获取最新脚本"
        menu_option 9 "卸载服务和 xs 快捷命令"
        menu_option 0 "退出"
        echo
        read -r -p "请选择 [0-9]: " choice
        case "$choice" in
            1) status; pause_menu ;;
            2) service_action start || true; pause_menu ;;
            3) service_action stop || true; pause_menu ;;
            4) service_action restart || true; pause_menu ;;
            5) journalctl -u adaptive-traffic.service -f || true ;;
            6) show_tc_status || true; pause_menu ;;
            7) config_submenu ;;
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

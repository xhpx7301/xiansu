# 自适应限速与不对等流量工具

这是一个面向 Linux 代理服务器的 Bash 脚本。它参考 `realm-xwPF` 的整机流量统计方式，读取 `/proc/net/dev` 的网卡计数器，并使用 `tc` 对网卡流量进行分阶段限速。

## 功能

- 默认限速阶段：`160 Mbps` 持续 15 秒，随后 `80 Mbps` 持续 15 秒，最后保持 `40 Mbps`。
- 默认限速方向为出站，限制整张网卡上的出站流量。
- 当采样吞吐率低于 `5 Mbps` 并持续 `30 秒` 时，恢复到 `160 Mbps` 第一阶段。
- 按北京时间（UTC+8）小时统计整机入站和出站字节数。
- 支持整卡统计和多个代理端口统计；端口模式可统计 TCP/UDP 49912 等固定监听端口。
- 状态面板分别显示网卡总入站和脚本补充下载量，便于判断实际补充情况。
- 按北京时间每月 1 日 00:00 重置月度统计，显示本月累计入站、出站、当前缺口和实际补充流量；服务重启不会清零。
- 默认目标为：入站流量达到出站流量的 `1.4` 倍，即入站比出站多 40%。
- 发现入站缺口后，从配置的腾讯 npm 镜像重复下载文件补足。
- 补充下载默认限制为 `5000000` 字节/秒，约等于 `40 Mbps`。
- 下载内容写入 `/dev/null`，不会在硬盘上累积下载文件。
- 支持通过 IFB 对入站和出站同时限速。
- `xs` 首页提供终端状态面板，集中显示服务、网卡、小时流量、当前限速阶段和入站补充缺口。

## 环境要求

- Linux、root 权限和 Bash
- `iproute2`，提供 `ip` 和 `tc`
- `awk`、`curl`、`systemd`
- 使用端口统计模式时还需要 `nftables`，提供 `nft`

脚本不会在 Windows 上直接运行，应该上传到 Linux 服务器执行。

## 安装

### 一键安装

在 Linux 服务器上执行以下命令，会安装服务并创建 `xs` 管理快捷命令：

```bash
curl -fsSL https://raw.githubusercontent.com/xhpx7301/xiansu/main/adaptive-traffic.sh | sudo bash -s install
```

安装完成后直接运行管理菜单：

```bash
sudo xs
```

也可以使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/xhpx7301/xiansu/main/adaptive-traffic.sh | sudo bash -s install
```

### 本地脚本安装

```bash
chmod +x adaptive-traffic.sh
sudo ./adaptive-traffic.sh install
```

安装命令会创建并启动 `adaptive-traffic.service`，默认配置位于：

```text
/etc/adaptive-traffic/config.env
```

修改配置后重启服务：

```bash
sudo systemctl restart adaptive-traffic.service
```

## `xs` 管理菜单

执行 `sudo xs` 后可以管理：

首页状态面板显示当前服务运行状态、网卡、限速方向和已应用速率，也会显示“本小时累计（北京时间）”所选统计模式的入站/出站流量、实际入出比例、目标入站量和待补缺口。小时和月度统计会分别列出脚本补充下载量；整卡模式将总入站减去已记录补充量，展示其他入站估算值，端口模式则展示代理端口入站。月度统计同时显示统计起始时间、累计缺口和检查次数。同一个北京时间小时内重启服务会沿用已有小时基线，避免把重启后的流量误标成完整一小时。

“当前小时缺口”只计算当前北京时间小时；“本月累计缺口”从本月统计基线开始，包含本月此前所有小时的累计差额，因此可能大于当前小时缺口。首次升级到支持统计模式的版本时会重新建立月度和小时基线，之后服务重启会沿用同一统计模式的基线。若希望手动重新开始统计，可在“配置管理 → 重置小时、本月和补充统计”中操作。该选项会要求输入 `yes` 确认；服务运行时会先停止再恢复，并重置小时、本月和补充下载统计，不修改限速或下载配置。

1. 查看服务状态、当前配置、小时统计和最近日志
2. 启动服务
3. 停止服务并清理 `tc` 限速
4. 重启服务并应用配置
5. 查看实时 systemd 日志
6. 查看网卡和 `tc` 限速统计
7. 配置管理二级菜单：限速策略、恢复条件、整卡/端口统计模式、代理端口管理、流量补充、下载限速，以及重置小时、本月和补充统计
8. 从 GitHub 获取最新脚本并自动重启服务
9. 卸载服务、脚本和 `xs` 快捷命令

配置管理中的“编辑完整原始配置”仍可打开 `/etc/adaptive-traffic/config.env`，适合修改高级参数；常用配置建议通过二级菜单修改，保存后会自动校验并在服务运行时重启应用。

“查看 `tc` 限速统计”会将内核队列输出整理为中文，显示网卡、队列类型、当前限速、突发额度、队列延迟、累计发送量、数据包、丢包、超限次数和队列积压。

启动或重启服务后，菜单会等待服务进入 `active`；如果仍显示 `activating` 或启动失败，会自动输出最近 12 条 systemd 日志，便于定位 `tc`、网卡或权限问题。

更新功能只替换脚本，不会覆盖 `/etc/adaptive-traffic/config.env`、统计状态或日志。也可以直接执行：

```bash
sudo /usr/local/bin/adaptive-traffic.sh update
```

## 默认配置

```bash
IFACE=""
RATE_STAGES="160:15,80:15,40:0"
RECOVERY_RATE_MBPS=5
RECOVERY_SECONDS=30
DIRECTION="egress"

DOWNLOAD_ENABLED=true
TRAFFIC_STATS_MODE="interface"
PROXY_PORTS="49912"
DOWNLOAD_RX_FRACTION=1.4
MAX_DOWNLOAD_BYTES_PER_HOUR=0
DOWNLOAD_URL="https://mirrors.tencent.com/npm/lodash/-/lodash-4.17.21.tgz"
DOWNLOAD_RATE_LIMIT="5000000"
DOWNLOAD_TIMEOUT_SECONDS=1800
```

开启补充流量并应用目标比例：

```bash
sudo nano /etc/adaptive-traffic/config.env
```

确认至少包含：

```bash
DOWNLOAD_ENABLED=true
TRAFFIC_STATS_MODE="interface"
PROXY_PORTS="49912"
DOWNLOAD_RX_FRACTION=1.4
MAX_DOWNLOAD_BYTES_PER_HOUR=0
DOWNLOAD_URL="https://mirrors.tencent.com/npm/lodash/-/lodash-4.17.21.tgz"
DOWNLOAD_RATE_LIMIT="5000000"
```

`DOWNLOAD_RX_FRACTION=1.4` 的含义是：

```text
目标入站 = 出站 × 1.4
需要补充的入站 = 目标入站 - 已有入站
```

统计模式：

- `TRAFFIC_STATS_MODE="interface"`：统计整张网卡。补充下载仍会计入总 RX，但面板会单独显示脚本实际下载量和扣除补充后的其他入站估算值。
- `TRAFFIC_STATS_MODE="port"`：通过 nftables 统计指定代理监听端口的 TCP/UDP 客户端双向流量。代理到目标网站的连接不使用监听端口，所以脚本用客户端入站加出站，分别估算代理完整链路的入站和出站。端口列表使用 `PROXY_PORTS="49912,443"` 这样的逗号分隔格式。端口模式需要服务器安装 `nft`，并只适合代理确实固定使用这些端口的情况；它是估算值，不等于服务商账单统计。

在 `xs → 配置管理 → 不对等流量补充 → 代理端口管理` 可以添加、按序号修改、按序号删除或直接设置整个列表。至少保留一个端口，不允许重复端口；每个端口同时统计 TCP 和 UDP。保存后若服务正在运行，会自动重启应用。旧配置中的单端口 `PROXY_PORT` 会继续读取；首次通过菜单保存端口列表后，以新字段 `PROXY_PORTS` 为准。

端口模式下，腾讯镜像下载不会命中代理监听端口，因此不会被计入代理业务估算值；下载补充量仍会单独计入目标计算。代理程序如果使用透明代理、NAT、额外监听端口或本机回环连接，估算可能偏离实际值，应使用整卡模式核对服务商流量。

补充下载使用 HTTPS，默认镜像的远端端口是 443，本机源端口由系统临时分配。端口统计规则同时校验连接方向：只计入客户端发往代理端口的请求及代理返回给客户端的响应，避免下载连接的临时端口恰好与代理端口相同而被误计入。

例如某小时出站 30 GB、自然入站 30 GB，目标入站为 42 GB，脚本会额外下载约 12 GB。

补充下载的检查周期是每 60 分钟一次。每个北京时间小时切换时，服务会先检查上一小时的缺口，再记录当前统计源作为新小时基线；只有目标入站量高于当前统计入站量时才下载，下载内容直接写入 `/dev/null`，达到缺口后停止。默认目标是入站达到出站的 1.4 倍，即多 40%。补充下载本身会增加整卡 RX，因此整卡模式下它会减少下一次缺口；端口模式下它不计入代理端口入站，但会作为已完成的补充量计入目标。

状态面板会显示北京时间当前时间和补充记录，包括上次检查时间、检查结果、本次实际下载量、下次检查时间和累计下载量。也可以直接查看：

```bash
sudo grep -E '^(MONTH|DOWNLOAD_)' /etc/adaptive-traffic/state.env
sudo journalctl -u adaptive-traffic.service --since '2 hours ago' --no-pager | grep -E '小时目标缺口|下载失败|本轮下载结束'
```

其中 `已完成` 表示本轮达到缺口，`无缺口` 表示检查时无需下载，`部分完成` 表示下载受到文件大小、超时或其他条件限制，`失败` 表示请求失败。补充量按 curl 实际收到的文件字节数记录，避免将同时发生的代理 RX 算作补充；整卡模式的“其他入站”是估算值，端口模式的代理端口流量由 nftables 计数器提供。

## 限速和恢复逻辑

脚本每秒读取一次网卡收发计数器。只有当采样吞吐率达到 `RECOVERY_RATE_MBPS` 时，才会推进限速阶段：

```text
高流量活跃 0-15 秒       160 Mbps
高流量活跃 15-30 秒       80 Mbps
高流量活跃超过 30 秒      40 Mbps
```

当采样吞吐率低于 `RECOVERY_RATE_MBPS` 并连续达到 `RECOVERY_SECONDS`，阶段计时清零并恢复到 160 Mbps。低流量保活数据不会不断推动脚本降到更低阶段。

`DIRECTION="egress"` 使用 `tc tbf` 限制出站。设置为 `DIRECTION="both"` 时，脚本会创建 `ifb-at`，把入站流量导入后再使用 `tc tbf` 限制。`tc` 是网卡级规则，服务器已有其他 qdisc 或流量整形配置时应先检查，避免规则互相覆盖。

## 补充下载说明

腾讯镜像地址已经写入默认配置。脚本使用 `curl -o /dev/null`，下载数据不会保存到磁盘，只会产生网络流量。

`curl --limit-rate` 使用字节/秒，不是 bit/s：

```text
5000000 bytes/s × 8 ≈ 40 Mbps
```

如果将 `MAX_DOWNLOAD_BYTES_PER_HOUR` 设置为具体数值，达到上限后可能无法完成入站为出站 `1.4` 倍的目标；设置为 `0` 表示不设置每小时补充上限。

## 查看和卸载

```bash
sudo ./adaptive-traffic.sh status
sudo systemctl status adaptive-traffic.service
sudo journalctl -u adaptive-traffic.service -f
sudo ./adaptive-traffic.sh uninstall
```

状态、日志和配置目录：

```text
/etc/adaptive-traffic/
```

小时和月度统计使用北京时间（UTC+8）边界。整卡模式统计整张网卡；端口模式统计代理端口。实际吞吐会受到线路容量、协议开销、TCP 重传和服务商计费规则影响。

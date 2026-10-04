# 自适应限速与不对等流量工具

这是一个面向 Linux 代理服务器的 Bash 脚本。它参考 `realm-xwPF` 的整机流量统计方式，读取 `/proc/net/dev` 的网卡计数器，并使用 `tc` 对网卡流量进行分阶段限速。

## 功能

- 默认限速阶段：`160 Mbps` 持续 15 秒，随后 `80 Mbps` 持续 15 秒，最后保持 `40 Mbps`。
- 默认限速方向为出站，限制整张网卡上的出站流量。
- 当采样吞吐率低于 `5 Mbps` 并持续 `30 秒` 时，恢复到 `160 Mbps` 第一阶段。
- 按 UTC 小时统计整机入站和出站字节数。
- 默认目标为：入站流量达到出站流量的 `4/3`，即入站比出站多三分之一。
- 发现入站缺口后，从配置的腾讯 npm 镜像重复下载文件补足。
- 补充下载默认限制为 `5000000` 字节/秒，约等于 `40 Mbps`。
- 下载内容写入 `/dev/null`，不会在硬盘上累积下载文件。
- 支持通过 IFB 对入站和出站同时限速。
- `xs` 首页提供终端状态面板，集中显示服务、网卡、小时流量、当前限速阶段和入站补充缺口。

## 环境要求

- Linux、root 权限和 Bash
- `iproute2`，提供 `ip` 和 `tc`
- `awk`、`curl`、`systemd`

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

首页状态面板显示当前服务运行状态、网卡、限速方向和已应用速率，也会显示本 UTC 小时入站/出站流量、实际入出比例、目标入站量和待补缺口。小时流量以脚本记录的小时起始网卡计数器为基准。

1. 查看服务状态、当前配置、小时统计和最近日志
2. 启动服务
3. 停止服务并清理 `tc` 限速
4. 重启服务并应用配置
5. 查看实时 systemd 日志
6. 查看网卡和 `tc` 限速统计
7. 编辑 `/etc/adaptive-traffic/config.env`
8. 从 GitHub 获取最新脚本并自动重启服务
9. 卸载服务、脚本和 `xs` 快捷命令

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

DOWNLOAD_ENABLED=false
DOWNLOAD_RX_FRACTION=1.333333
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
DOWNLOAD_RX_FRACTION=1.333333
MAX_DOWNLOAD_BYTES_PER_HOUR=0
DOWNLOAD_URL="https://mirrors.tencent.com/npm/lodash/-/lodash-4.17.21.tgz"
DOWNLOAD_RATE_LIMIT="5000000"
```

`DOWNLOAD_RX_FRACTION=1.333333` 的含义是：

```text
目标入站 = 出站 × 4/3
需要补充的入站 = 目标入站 - 已有入站
```

例如某小时出站 30 GB、自然入站 30 GB，目标入站为 40 GB，脚本会额外下载约 10 GB。

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

如果将 `MAX_DOWNLOAD_BYTES_PER_HOUR` 设置为具体数值，达到上限后可能无法完成入站为出站 `4/3` 的目标；设置为 `0` 表示不设置每小时补充上限。

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

小时统计使用 UTC 小时边界，统计的是整张网卡上的所有流量。实际吞吐会受到线路容量、协议开销、TCP 重传和服务商计费规则影响。

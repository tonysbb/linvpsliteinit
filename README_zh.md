# linvpsliteinit（中文说明）

[English](./README.md) | [日本語](./README_ja.md)

**linvpsliteinit** 是面向 **Debian / Ubuntu / Alpine Linux** 的 **轻量级、可交互** VPS 初始化与组件安装工具集。

---

## ✨ 功能亮点
- **一次初始化，可自由跳过**：主机名、时区、防火墙、Fail2Ban、SWAP、BBR
- **后续可多次执行组件安装**：按需添加模块
- **智能 SWAP**：推荐容量；Debian 11 避免重复挂载，Debian 12 保持默认策略
- **安全基线**：默认拒绝入站、允许出站；仅开放 SSH；Debian/Ubuntu 可启用 Fail2Ban
- **Alpine 支持**：iptables 防火墙、OpenRC 服务管理、POSIX sh 编写，无需 bash
- **全球友好**：英文注释，兼容 Debian 11/12、Ubuntu LTS、Alpine 3.22+

---

## 🚀 快速开始

> **需 root 权限。** 执行前请先阅读脚本内容。

```bash
git clone https://github.com/tonysbb/linvpsliteinit.git
cd linvpsliteinit
chmod +x vps_init.sh add_components.sh
sudo ./vps_init.sh
sudo ./add_components.sh
```

### ☝️ 一键安装（请谨慎使用）

```bash
curl -fsSL https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/vps_init.sh | sudo sh
curl -fsSL https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/add_components.sh | sudo sh
```

---

## 🧩 模块说明

### 1) 初始化脚本 `vps_init.sh`
- 主机名、时区设置（符合 RFC 1123）
- SWAP：动态推荐容量，Debian 11 避免重复挂载
- 防火墙：Debian/Ubuntu 使用 UFW + Fail2Ban；Alpine 使用 iptables
- BBR：内核支持时自动启用

初始化过程中，主机名和时区会分别单独询问。
在 Debian/Ubuntu 上，确认进入防火墙步骤后会直接配置 UFW，再单独询问是否启用 Fail2Ban。

### 2) 组件脚本 `add_components.sh`
可重复执行的菜单式安装器，支持：
- SWAP 配置
- 防火墙（UFW + Fail2Ban / iptables）
- BBR
- 高级网络调优（适用于代理 / FRP / 高并发场景）
- 主机名与时区
- Docker（Debian/Ubuntu 使用官方源；Alpine 使用系统包）
- tmux
- mosh（可选放行默认 UDP 端口范围 `60000-61000`）
- FRPS（Alpine 使用 OpenRC；Debian/Ubuntu 使用 systemd）

Guided Install 模式下会直接进入“主机名与时区”子步骤，主机名和时区都可以分别跳过。
`高级网络调优` 为可选项，会应用较保守的 `somaxconn`、`tcp_max_syn_backlog`、
`rmem/wmem`、`nofile` 以及可选的 `TCP Fast Open` 设置。

---

## 🛠️ 兼容性

| 系统 | 版本 | 防火墙 | 服务管理 |
|------|------|--------|---------|
| Debian | 11 / 12 | UFW + Fail2Ban | systemd |
| Ubuntu | 20.04 / 22.04 / 24.04 LTS | UFW + Fail2Ban | systemd |
| Alpine | 3.22+ | iptables | OpenRC |

> **cloud-init**：部分 VPS 镜像会在启动时覆盖主机名/网络配置。  
> Debian/Ubuntu 请检查 `/etc/cloud/cloud.cfg` 中的 `preserve_hostname`。  
> Alpine NAT VPS 上，宿主机可能在启动时注入主机名，脚本已通过 `/etc/local.d/hostname.start` 自动处理。

> **NAT VPS**：若使用 10000 以上端口，请确认服务商的端口映射与脚本配置一致。

---

## 🔒 安全说明
- 必须以 root 身份运行
- 主机名需符合 RFC 1123 格式
- **Debian/Ubuntu**：UFW 默认拒绝入站/允许出站；Fail2Ban 防止 SSH 暴力破解
- **Alpine**：iptables 默认 DROP 入站；`vps_init.sh` 配置仅密钥登录
- 私钥在服务器端生成后一次性展示，确认保存后立即删除，请务必及时备份

---

## 📜 许可证
MIT（见 [LICENSE](./LICENSE)）

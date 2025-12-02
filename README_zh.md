# linvpsliteinit（中文说明）

[English](./README.md) | [日本語](./README_ja.md)

**linvpsliteinit** 是面向 **Debian / Ubuntu** 的 **轻量级、可交互** VPS 初始化与组件安装工具集。

---

## ✨ 功能亮点
- **一次初始化，可自由跳过**：主机名、时区、UFW、Fail2Ban、SWAP、BBR  
- **后续可多次执行组件安装**：按需添加模块  
- **智能 SWAP**：推荐容量；Debian 11 避免重复挂载，Debian 12 保持默认策略  
- **安全基线**：默认拒绝入站、允许出站；仅开放 SSH；可启用 Fail2Ban  
- **全球友好**：英文注释，兼容 Debian 11/12 与 Ubuntu LTS  

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
curl -fsSL https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/vps_init.sh | sudo bash
curl -fsSL https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/add_components.sh | sudo bash
```

---

## 🧩 模块说明
- **初始化脚本**：主机名、时区、SWAP、UFW、Fail2Ban、BBR  
- **组件脚本**：可重复执行，支持 SWAP、Fail2Ban、Docker 等  

---

## 🛠️ 兼容性
- Debian **11 / 12**
- Ubuntu **20.04 / 22.04 / 24.04**

---

## 🔒 安全说明
- 必须以 root 身份运行  
- 防火墙默认拒绝入站、允许出站  
- 主机名需符合 RFC1123 格式  

---

## 📜 许可证
MIT（见 [LICENSE](./LICENSE)）

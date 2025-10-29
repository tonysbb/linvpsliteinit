<div align="center">

![linvpsliteinit banner](./assets/banner.svg)

# linvpsliteinit — Lightweight VPS Initialization Toolkit

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-green.svg)
![Shell](https://img.shields.io/badge/Shell-bash-lightgrey.svg)
![PRs](https://img.shields.io/badge/PRs-welcome-orange.svg)

**English** · [🇨🇳 中文](./README_zh.md) · [🇯🇵 日本語](./README_ja.md)

</div>

`linvpsliteinit` is a **lightweight, interactive VPS setup toolkit** for **Debian & Ubuntu**.  
It ships a one-pass initialization script and a re-runnable components installer.

---

## ✨ Features at a Glance
- **Init once, skip freely**: hostname, timezone, UFW, Fail2Ban, SWAP, BBR  
- **Add later, safely**: re-run the components installer any time  
- **Smart SWAP**: sensible defaults; Debian 11 de-dup; Debian 12 untouched  
- **Secure baseline**: deny inbound by default, allow chosen SSH; Fail2Ban enabled  
- **Global-ready**: clear English comments; tested on Debian 11/12 & Ubuntu LTS  

---

## 🚀 Quick Start

> **Root is required.** Review the scripts before executing in production.

```bash
# Clone
git clone https://github.com/tonysbb/linvpsliteinit.git
cd linvpsliteinit

# Make executable
chmod +x vps_init_final_ChatGPT.sh add_components_ChatGPT.sh

# Initialize (recommended on a fresh VPS)
sudo ./vps_init_final_ChatGPT.sh

# Add components later as needed
sudo ./add_components_ChatGPT.sh
```

### ☝️ One-liner (use with caution)
> Read the script first if possible. One-liners are convenient but risky if you don’t audit code.

```bash
# Initialization script
curl -fsSL https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/vps_init_final_ChatGPT.sh | sudo bash

# Components script
curl -fsSL https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/add_components_ChatGPT.sh | sudo bash
```

Alternatively (download then run):

```bash
curl -fsSLO https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/vps_init_final_ChatGPT.sh
curl -fsSLO https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/add_components_ChatGPT.sh
chmod +x *.sh
sudo ./vps_init_final_ChatGPT.sh
sudo ./add_components_ChatGPT.sh
```

---

## 🧩 Modules
### 1) Initialization — `vps_init_final_ChatGPT.sh`
- Hostname & Timezone (RFC 1123 compliant)
- SWAP: dynamic sizing, deduplication for Debian 11
- UFW: deny inbound, allow outbound
- Fail2Ban: optional security layer
- BBR: enabled if supported

### 2) Components — `add_components_ChatGPT.sh`
- Re-runnable menu installer:
  - SWAP reconfiguration
  - Fail2Ban
  - Docker (official repo)
  - Extend as needed

---

## 🛠️ Compatibility
- Debian **11** (Bullseye), **12** (Bookworm)
- Ubuntu **20.04 / 22.04 / 24.04** LTS

> Some VPS images ship with **cloud-init** which can override hostname/network configs.  
> Check `/etc/cloud/cloud.cfg` (`preserve_hostname`) if changes don’t persist.

---

## 🔒 Security Notes
- Run as **root**
- Hostname must comply with RFC 1123
- UFW defaults: deny inbound, allow outbound
- Fail2Ban defends against SSH brute-force

---

## 📜 License
MIT — see [LICENSE](./LICENSE)
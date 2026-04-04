<div align="center">

# linvpsliteinit — Lightweight VPS Initialization Toolkit

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu%20%7C%20Alpine-green.svg)
![Shell](https://img.shields.io/badge/Shell-POSIX%20sh-lightgrey.svg)
![PRs](https://img.shields.io/badge/PRs-welcome-orange.svg)

**English** · [🇨🇳 中文](./README_zh.md) · [🇯🇵 日本語](./README_ja.md)

</div>

`linvpsliteinit` is a **lightweight, interactive VPS setup toolkit** for **Debian, Ubuntu, and Alpine Linux**.  
It ships a one-pass initialization script and a re-runnable components installer.

---

## ✨ Features at a Glance
- **Init once, skip freely**: hostname, timezone, firewall, Fail2Ban, SWAP, BBR
- **Add later, safely**: re-run the components installer any time
- **Smart SWAP**: sensible defaults; Debian 11 de-dup; Debian 12 untouched
- **Secure baseline**: deny inbound by default, allow chosen SSH port; Fail2Ban on Debian/Ubuntu
- **Alpine support**: iptables firewall, OpenRC services, POSIX sh — no bash required
- **Global-ready**: clear English comments; tested on Debian 11/12, Ubuntu LTS, Alpine 3.22+

---

## 🚀 Quick Start

> **Root is required.** Review the scripts before executing in production.

```bash
# Clone
git clone https://github.com/tonysbb/linvpsliteinit.git
cd linvpsliteinit

# Make executable
chmod +x vps_init.sh add_components.sh

# Initialize (recommended on a fresh VPS)
sudo ./vps_init.sh

# Add components later as needed
sudo ./add_components.sh
```

### ☝️ One-liner (use with caution)
> Read the script first if possible. One-liners are convenient but risky if you don't audit code.

```bash
# Initialization script
curl -fsSL https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/vps_init.sh | sudo sh

# Components script
curl -fsSL https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/add_components.sh | sudo sh
```

Alternatively (download then run):

```bash
curl -fsSLO https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/vps_init.sh
curl -fsSLO https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/add_components.sh
chmod +x *.sh
sudo ./vps_init.sh
sudo ./add_components.sh
```

---

## 🧩 Modules

### 1) Initialization — `vps_init.sh`
- Hostname & Timezone (RFC 1123 compliant)
- SWAP: dynamic sizing, deduplication for Debian 11
- Firewall: UFW + Fail2Ban on Debian/Ubuntu; iptables on Alpine
- BBR: enabled if supported by kernel

During initialization, hostname and timezone are prompted separately.
On Debian/Ubuntu, choosing the firewall step configures UFW directly, then asks whether to enable Fail2Ban.

### 2) Components — `add_components.sh`
- Re-runnable menu installer:
  - SWAP reconfiguration
  - Firewall (UFW + Fail2Ban / iptables)
  - BBR
  - Hostname & Timezone
  - Docker (official repo on Debian/Ubuntu; Alpine package on Alpine)
  - tmux
  - mosh (with optional default UDP range `60000-61000`)
  - FRPS (OpenRC service on Alpine; systemd on Debian/Ubuntu)

In Guided Install, the Hostname/Timezone step opens directly and each field can be skipped independently.

---

## 🛠️ Compatibility

| OS | Version | Firewall | Service Manager |
|----|---------|----------|----------------|
| Debian | 11 (Bullseye), 12 (Bookworm) | UFW + Fail2Ban | systemd |
| Ubuntu | 20.04 / 22.04 / 24.04 LTS | UFW + Fail2Ban | systemd |
| Alpine | 3.22+ | iptables | OpenRC |

> **cloud-init**: Some VPS images override hostname/network on boot.  
> Check `/etc/cloud/cloud.cfg` (`preserve_hostname`) on Debian/Ubuntu if changes don't persist.  
> On Alpine NAT VPS, hostname may be injected by the host — the script handles this automatically via `/etc/local.d/hostname.start`.

> **NAT VPS**: If ports above 10000 are used, ensure your provider's port mapping matches the ports configured in the script.

---

## 🔒 Security Notes
- Run as **root**
- Hostname must comply with RFC 1123
- **Debian/Ubuntu**: UFW defaults to deny inbound / allow outbound; Fail2Ban defends against SSH brute-force
- **Alpine**: iptables defaults to DROP inbound; key-only SSH configured by `vps_init.sh`
- Private key is generated server-side and displayed once — save it immediately, it is deleted after confirmation

---

## 📜 License
MIT — see [LICENSE](./LICENSE)

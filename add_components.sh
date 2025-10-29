#!/bin/bash

#================================================================================
# VPS Add-on Component Manager - Production Ready
#
# @author: Tony
# @contributors: Gemini, ChatGPT, Claude AI
# @description: A robust, idempotent script to manage VPS components including
#               SWAP, security tools, Docker, FRPS, and system optimizations.
# @os: Debian/Ubuntu
# @license: MIT
#================================================================================

# --- Color Definitions & Setup ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
set -e
LOG_FILE="/root/components_manager_$(date +%Y%m%d_%H%M%S).log"
exec &> >(tee -a "$LOG_FILE")
echo -e "${GREEN}Component Manager started. Log: ${YELLOW}$LOG_FILE${NC}"

check_root() { if [ "$(id -u)" -ne 0 ]; then echo -e "${RED}Error: Must be run as root.${NC}"; exit 1; fi; }
prompt_yes_no() { local prompt_text="$1"; local choice; read -p "$prompt_text (Y/n): " choice; [[ "${choice:-Y}" =~ ^[Yy]$ ]]; }

# --- Component Functions ---

configure_swap() { 
    echo -e "\n${BLUE}--- Configuring SWAP ---${NC}"; 
    local mem_size_mb=$(free -m | awk '/^Mem:/{print $2}'); 
    local current_swap_mb=$(free -m | awk '/^Swap:/{print $2}'); 
    local swap_file_path="/swapfile_by_script"; 
    
    # Advanced SWAP recommendation logic for optimal performance
    local recommended_swap_mb
    if (( mem_size_mb < 512 )); then
        recommended_swap_mb=1024
    elif (( mem_size_mb < 1024 )); then
        recommended_swap_mb=1536
    elif (( mem_size_mb < 2048 )); then
        recommended_swap_mb=2048

        # Fix: Prevent duplicate SWAP mount (Debian 11 compatibility)
        swapoff -a 2>/dev/null || true
        sed -i '/swapfile_by_script/d' /etc/fstab
        rm -f "$swap_file_path"
        # Fix: avoid duplicate SWAP on reboot by commenting other swap entries (keep only ours)
        cp -a /etc/fstab /etc/fstab.bak_$(date +%s)
        sed -ri '/swapfile_by_script/! s@^([^#].*\s)swap(\s+.*)$@# \1swap\2@' /etc/fstab
    elif (( mem_size_mb < 4096 )); then
        recommended_swap_mb=3072
    elif (( mem_size_mb < 8192 )); then
        recommended_swap_mb=4096
    elif (( mem_size_mb < 16384 )); then
        recommended_swap_mb=6144
    else
        recommended_swap_mb=8192
    fi
    
    echo "Memory: ${mem_size_mb}MB, Current SWAP: ${current_swap_mb}MB"; 
    local user_target_mb; 
    read -p "Recommended SWAP size is ${recommended_swap_mb}MB. Enter desired size (MB) or press Enter: " user_target_mb; 
    local target_swap_mb=${user_target_mb:-$recommended_swap_mb}; 
    
    if ! [[ "$target_swap_mb" =~ ^[0-9]+$ ]]; then 
        echo -e "${RED}Invalid input. Aborting.${NC}"; 
        return 1; 
    fi; 
    
    if (( target_swap_mb <= current_swap_mb )); then 
        echo -e "${GREEN}Current SWAP size is sufficient. No action needed.${NC}"; 
        return; 
    fi; 
    
    if [ -f "$swap_file_path" ]; then 
        swapoff "$swap_file_path" 2>/dev/null || true
        rm -f "$swap_file_path"
        # Fix: avoid duplicate SWAP on reboot by commenting other swap entries (keep only ours)
        cp -a /etc/fstab /etc/fstab.bak_$(date +%s)
        sed -ri '/swapfile_by_script/! s@^([^#].*\s)swap(\s+.*)$@# \1swap\2@' /etc/fstab
        sed -i "\#${swap_file_path}#d" /etc/fstab
    fi
    
    echo "Creating ${target_swap_mb}MB swap file..."; 
    
    if command -v fallocate >/dev/null 2>&1; then
        echo "Using fallocate for fast allocation..."
        fallocate -l ${target_swap_mb}M "$swap_file_path"
        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}fallocate failed, falling back to dd...${NC}"
            dd if=/dev/zero of="$swap_file_path" bs=1M count=${target_swap_mb} status=progress
        fi
    else
        echo "Using dd (this may take a moment)..."
        dd if=/dev/zero of="$swap_file_path" bs=1M count=${target_swap_mb} status=progress
    fi
    
    chmod 600 "$swap_file_path" && mkswap "$swap_file_path" && swapon "$swap_file_path"
    
    if ! grep -qF "$swap_file_path" /etc/fstab; then
        echo "${swap_file_path} none swap sw 0 0" >> /etc/fstab
    fi
    
    if ! grep -q "^vm.swappiness=10" /etc/sysctl.conf; then 
        echo -e "\nvm.swappiness=10" >> /etc/sysctl.conf && sysctl -p > /dev/null; 
    fi; 
    
    echo -e "${GREEN}SWAP configured successfully.${NC}"; 
    free -h; 
}

setup_security_tools() {
    echo -e "\n${BLUE}--- Configuring Security (UFW & Fail2ban) ---${NC}"
    local ssh_port=$(sshd -T | awk '/port/ {print $2}' | head -n 1)
    if [[ -z "$ssh_port" ]]; then echo -e "${RED}FATAL: Could not determine SSH port.${NC}"; return 1; fi
    echo "Detected active SSH port: ${GREEN}${ssh_port}${NC}"
    if ! command -v ufw &> /dev/null; then
        echo "Installing UFW..."; apt-get update >/dev/null; apt-get install -y ufw
        ufw allow "$ssh_port/tcp"; ufw --force enable
        echo -e "${GREEN}UFW installed and configured for SSH port $ssh_port.${NC}"
    else echo -e "${YELLOW}UFW is already installed.${NC}"; fi
    if ! command -v fail2ban-client &> /dev/null; then
        echo "Installing Fail2ban..."; apt-get install -y fail2ban
        cat > /etc/fail2ban/jail.d/sshd.local << EOF
[sshd]
enabled      = true
port         = $ssh_port
backend      = systemd
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
banaction    = ufw
EOF
        systemctl restart fail2ban; echo "Verifying Fail2ban service..."; sleep 3
        if systemctl is-active --quiet fail2ban; then echo -e "${GREEN}Fail2ban started successfully.${NC}"; else echo -e "${RED}Fail2ban failed to start!${NC}"; fi
    else echo -e "${YELLOW}Fail2ban is already installed.${NC}"; fi
}

enable_bbr() { 
    echo -e "\n${BLUE}--- Enabling BBR ---${NC}"; 
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then 
        echo -e "${YELLOW}BBR already enabled.${NC}"; 
        return; 
    fi
    modprobe tcp_bbr
    echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" > /etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null
    echo -e "${GREEN}BBR enabled.${NC}"
}

set_hostname_timezone() { 
    echo -e "\n${BLUE}--- Setting Hostname & Timezone ---${NC}"; 
    read -p "Enter new hostname (or press Enter to skip): " h
    if [ -n "$h" ]; then 
        hostnamectl set-hostname "$h"
        echo "$h" > /etc/hostname   # Fix: persist hostname on Debian 11
        hostname "$h"               # Fix: apply immediately for current session
        # Fix: ensure /etc/hosts reflects the new hostname (Debian 11 compatibility)
        if grep -qE "^127\.0\.1\.1\s" /etc/hosts; then
            sed -ri "s@^(127\.0\.1\.1\s+).*@\1$h@" /etc/hosts
        else
            echo "127.0.1.1\t$h" >> /etc/hosts
        fi
        echo "Hostname set to $h"
    fi
    read -p "Enter UTC offset (+8, -5) (or press Enter to skip): " o
    if [ -n "$o" ]; then 
        s=${o:0:1}
        h=${o:1}
        if [[ "$s" == "+" ]]; then 
            n="Etc/GMT-${h}"
        else 
            n="Etc/GMT+${h}"
        fi
        if timedatectl set-timezone "$n"; then 
            echo "Timezone set to $n (UTC$o)"
        fi
    fi
    echo -e "${GREEN}Configuration complete.${NC}"
}

install_docker() { 
    echo -e "\n${BLUE}--- Installing Docker ---${NC}"; 
    if command -v docker &> /dev/null; then 
        echo -e "${YELLOW}Docker already installed.${NC}"; 
        return
    fi
    apt-get update >/dev/null
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    mkdir -p /etc/apt/sources.list.d
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update >/dev/null
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo -e "${GREEN}Docker installed successfully.${NC}"
}

install_frp() {
    echo -e "\n${BLUE}--- Installing FRPS ---${NC}"
    if [ -f "/etc/systemd/system/frps.service" ]; then 
        echo -e "${YELLOW}FRPS already installed.${NC}"; 
        return
    fi
    
    local bind_port
    read -p "Enter frps bind port [7000]: " bind_port
    bind_port=${bind_port:-7000}
    
    local dashboard_port
    read -p "Enter frps dashboard port [7500]: " dashboard_port
    dashboard_port=${dashboard_port:-7500}
    
    local dashboard_user
    read -p "Enter dashboard username [admin]: " dashboard_user
    dashboard_user=${dashboard_user:-admin}
    
    local dashboard_pass
    read -p "Enter dashboard password [admin123]: " dashboard_pass
    dashboard_pass=${dashboard_pass:-admin123}
    
    local default_token=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
    local auth_token
    read -p "Enter authentication token [${default_token}]: " auth_token
    auth_token=${auth_token:-$default_token}
    
    local latest_version=$(curl -s "https://api.github.com/repos/fatedier/frp/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
    if [[ -z "$latest_version" ]]; then 
        echo -e "${RED}Could not fetch frp version.${NC}"
        return 1
    fi
    
    local vclean=${latest_version#v}
    local url="https://github.com/fatedier/frp/releases/download/${latest_version}/frp_${vclean}_linux_amd64.tar.gz"
    local dir="/root/frp"
    
    mkdir -p "$dir"
    echo "Downloading frp ${latest_version}..."
    wget -qO /tmp/frp.tar.gz "$url" && tar -zxf /tmp/frp.tar.gz -C "$dir" --strip-components=1
    rm /tmp/frp.tar.gz
    chmod +x "${dir}/frps"
    
    cat > "${dir}/frps.toml" << EOF
bindPort = ${bind_port}
auth.method = "token"
auth.token = "${auth_token}"

webServer.port = ${dashboard_port}
webServer.user = "${dashboard_user}"
webServer.password = "${dashboard_pass}"

log.to = "${dir}/frps.log"
log.level = "info"
log.maxDays = 7
EOF

    cat > /etc/systemd/system/frps.service << EOF
[Unit]
Description=FRP Server
After=network.target
[Service]
Type=simple
User=root
ExecStart=${dir}/frps -c ${dir}/frps.toml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable --now frps
    
    if command -v ufw &> /dev/null; then 
        ufw allow ${bind_port}/tcp
        echo "Firewall rule added for port ${bind_port}."
    fi
    
    echo "Verifying frps service..."
    sleep 2
    if systemctl is-active --quiet frps; then 
        echo -e "${GREEN}frps version ${vclean} installed and started successfully.${NC}"
    else 
        echo -e "${RED}frps failed to start!${NC}"
    fi
}

main() {
    check_root
    while true; do
        echo -e "\n${BLUE}VPS Component Manager & Guided Installer${NC}"
        echo "-------------------------------------------"
        echo " 1) Configure SWAP"
        echo " 2) Setup Security (UFW + Fail2ban)"
        echo " 3) Enable BBR"
        echo " 4) Set Hostname & Timezone"
        echo " 5) Install Docker"
        echo " 6) Install FRPS"
        echo "-------------------------------------------"
        echo " 99) Guided Install (Ask for all components)"
        echo " 0) Exit"
        echo "-------------------------------------------"
        read -p "Enter your choice: " choice
        case $choice in
            1) configure_swap ;;
            2) setup_security_tools ;;
            3) enable_bbr ;;
            4) set_hostname_timezone ;;
            5) install_docker ;;
            6) install_frp ;;
            99)
                echo -e "${YELLOW}\nStarting Guided Installation...${NC}"
                if prompt_yes_no "Configure SWAP?"; then configure_swap; fi
                if prompt_yes_no "Setup Security (UFW + Fail2ban)?"; then setup_security_tools; fi
                if prompt_yes_no "Enable BBR?"; then enable_bbr; fi
                if prompt_yes_no "Set Hostname & Timezone?"; then set_hostname_timezone; fi
                if prompt_yes_no "Install Docker?"; then install_docker; fi
                if prompt_yes_no "Install FRPS?"; then install_frp; fi
                echo -e "${GREEN}\nGuided Installation finished.${NC}"
                ;;
            0) echo "Exiting."; break ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
}

main
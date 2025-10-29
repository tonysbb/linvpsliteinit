#!/bin/bash

#================================================================================
# VPS Initialization Script - Production Ready
#
# @author: Tony
# @contributors: Gemini, ChatGPT, Claude AI
# @description: A flexible, interactive script for VPS initial setup with
#               SSH hardening, security tools, and system optimization.
# @os: Debian/Ubuntu
# @license: MIT
#================================================================================

# --- Color Definitions & Setup ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
set -e
LOG_FILE="/root/vps_init_$(date +%Y%m%d_%H%M%S).log"
exec &> >(tee -a "$LOG_FILE")
echo -e "${GREEN}Script started. Log: ${YELLOW}$LOG_FILE${NC}"

# --- Global Summary Variables & Helper Functions ---
SUMMARY_SSH_PORT=""
SUMMARY_HOSTNAME="$(hostname)"
SUMMARY_TIMEZONE="Default"
SUMMARY_SWAP_STATUS="Skipped"
SUMMARY_UFW_STATUS="Skipped"
SUMMARY_UFW_PORTS="N/A"
SUMMARY_FAIL2BAN_STATUS="Skipped"
SUMMARY_BBR_STATUS="Skipped"
SUMMARY_DOCKER_STATUS="Skipped"
SUMMARY_FRP_STATUS="Skipped"
check_root() { if [ "$(id -u)" -ne 0 ]; then echo -e "${RED}Error: Must be run as root.${NC}"; exit 1; fi; }
print_step() { echo -e "\n${BLUE}=======================================================\n${YELLOW}>> Step: $1${NC}\n${BLUE}=======================================================${NC}"; }
prompt_yes_no() { local prompt_text="$1"; local choice; read -p "$prompt_text (Y/n): " choice; [[ "${choice:-Y}" =~ ^[Yy]$ ]]; }

# --- CORE FUNCTIONS ---

change_password() {
    print_step "Set root Password (Mandatory)"
    echo "Please set a new password for the root user."
    passwd
    echo -e "${GREEN}Password changed successfully.${NC}"
}

configure_ssh() {
    print_step "Configure SSH (Mandatory)"
    local new_ssh_port
    while true; do read -p "Enter a new SSH port (10000-65535): " new_ssh_port; if [[ "$new_ssh_port" =~ ^[0-9]+$ ]] && [ "$new_ssh_port" -gt 1024 ] && [ "$new_ssh_port" -lt 65536 ]; then break; fi; echo -e "${RED}Invalid input.${NC}"; done
    SUMMARY_SSH_PORT=$new_ssh_port
    echo -e "New SSH port will be: ${GREEN}$SUMMARY_SSH_PORT${NC}"
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
    cat ~/.ssh/id_ed25519.pub > ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    echo -e "\n${YELLOW}!!! IMPORTANT: Copy and save the private key below. !!!${NC}"
    echo -e "${RED}--- PRIVATE KEY START ---${NC}"; cat ~/.ssh/id_ed25519; echo -e "${RED}---  PRIVATE KEY END  ---${NC}"
    while true; do read -p "Have you saved the private key? (yes/no): " c && [[ "$c" == "yes" ]] && break; done
    rm -f ~/.ssh/id_ed25519
    sed -i.bak -E -e "s/^[#\s]*Port\s+.*/Port ${SUMMARY_SSH_PORT}/" -e "s/^[#\s]*PermitRootLogin\s+.*/PermitRootLogin prohibit-password/" -e "s/^[#\s]*PasswordAuthentication\s+.*/PasswordAuthentication no/" -e "s/^[#\s]*PubkeyAuthentication\s+.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    systemctl restart sshd
    echo "Verifying SSH service..."
    sleep 2
    if ! sshd -T | grep -q "port $SUMMARY_SSH_PORT"; then
        echo -e "${RED}FATAL: SSH verification failed! Please check config using VNC.${NC}"; exit 1
    fi
    echo -e "${GREEN}SSH is now running on port $SUMMARY_SSH_PORT.${NC}"
}

configure_swap() {
    print_step "Configure SWAP File"
    local mem_size_mb=$(free -m | awk '/^Mem:/{print $2}')
    local current_swap_mb=$(free -m | awk '/^Swap:/{print $2}')
    local swap_file_path="/swapfile_by_script"
    
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
    
    echo "Memory: ${mem_size_mb}MB, Current SWAP: ${current_swap_mb}MB"
    local user_target_mb
    read -p "Recommended SWAP size is ${recommended_swap_mb}MB. Enter desired size (MB) or press Enter: " user_target_mb
    local target_swap_mb=${user_target_mb:-$recommended_swap_mb}
    
    if ! [[ "$target_swap_mb" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid input. Skipping.${NC}"
        return
    fi
    
    if (( target_swap_mb <= current_swap_mb )); then
        echo -e "${GREEN}Current SWAP is sufficient.${NC}"
        SUMMARY_SWAP_STATUS="Sufficient, total: $(free -h | awk '/^Swap:/ {print $2}')"
        return
    fi
    
    if [ -f "$swap_file_path" ]; then
        swapoff "$swap_file_path" 2>/dev/null || true
        rm -f "$swap_file_path"
    # Fix: avoid duplicate SWAP on reboot by commenting other swap entries (keep only ours)
    cp -a /etc/fstab /etc/fstab.bak_$(date +%s)
    sed -ri '/swapfile_by_script/! s@^([^#].*\s)swap(\s+.*)$@# \1swap\2@' /etc/fstab
        sed -i "\#${swap_file_path}#d" /etc/fstab
    fi
    
    echo "Creating ${target_swap_mb}MB swap file..."
    
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
    
    chmod 600 "$swap_file_path"
    mkswap "$swap_file_path"
    swapon "$swap_file_path"
    
    if ! grep -qF "$swap_file_path" /etc/fstab; then
        echo "${swap_file_path} none swap sw 0 0" >> /etc/fstab
    fi
    
    if ! grep -q "^vm.swappiness=10" /etc/sysctl.conf; then
        echo -e "\nvm.swappiness=10" >> /etc/sysctl.conf
        sysctl -p > /dev/null
    fi
    
    SUMMARY_SWAP_STATUS="Configured, total: $(free -h | awk '/^Swap:/ {print $2}')"
    echo -e "${GREEN}SWAP configured successfully.${NC}"
    free -h
}

update_and_install_tools() {
    print_step "Update System & Install Tools (Mandatory)"
    apt-get update > /dev/null
    apt-get install -y curl wget dnsutils traceroute software-properties-common ca-certificates gnupg lsb-release
    echo -e "${GREEN}System updated and tools installed.${NC}"
}

setup_security_tools() {
    print_step "Configure Security (UFW & Fail2ban)"
    echo "This step configures UFW (Firewall) and Fail2ban (Intrusion Prevention)."
    if prompt_yes_no "Install UFW Firewall?"; then
        apt-get install -y ufw
        ufw allow $SUMMARY_SSH_PORT/tcp
        ufw --force enable
        SUMMARY_UFW_STATUS="Enabled"
        SUMMARY_UFW_PORTS="$SUMMARY_SSH_PORT"
        echo -e "${GREEN}UFW enabled for port $SUMMARY_SSH_PORT.${NC}"
        if prompt_yes_no "Install Fail2ban?"; then
            apt-get install -y fail2ban
            cat > /etc/fail2ban/jail.d/sshd.local << EOF
[sshd]
enabled      = true
port         = $SUMMARY_SSH_PORT
backend      = systemd
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
banaction    = ufw
EOF
            systemctl restart fail2ban
            echo "Verifying Fail2ban service..."
            sleep 3
            if systemctl is-active --quiet fail2ban; then
                SUMMARY_FAIL2BAN_STATUS="Enabled (monitoring SSH)"
                echo -e "${GREEN}Fail2ban started successfully.${NC}"
            else
                SUMMARY_FAIL2BAN_STATUS="FAILED to start"
                echo -e "${RED}Fail2ban service failed to start! Check logs.${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}Skipping firewall setup. WARNING: Server may be exposed!${NC}"
    fi
}

enable_bbr() { 
    print_step "Enable BBR"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then 
        echo -e "${YELLOW}BBR already enabled.${NC}"; 
        SUMMARY_BBR_STATUS="Already enabled"
        return; 
    fi
    modprobe tcp_bbr
    echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" > /etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null
    SUMMARY_BBR_STATUS="Enabled"
    echo -e "${GREEN}BBR enabled.${NC}"
}

set_hostname_timezone() { 
    print_step "Set Hostname & Timezone"
    if prompt_yes_no "Set a new hostname?"; then 
        read -p "Enter hostname: " h
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
            SUMMARY_HOSTNAME="$h"
            echo "Hostname set to $h"
        fi
    fi
    if prompt_yes_no "Set timezone?"; then 
        read -p "Enter UTC offset (+8, -5) [+9]: " o
        o=${o:-+9}
        s=${o:0:1}
        h=${o:1}
        if [[ "$s" == "+" ]]; then 
            n="Etc/GMT-${h}"
        else 
            n="Etc/GMT+${h}"
        fi
        if timedatectl set-timezone "$n"; then 
            SUMMARY_TIMEZONE="$n (UTC$o)"
            echo "Timezone set to $SUMMARY_TIMEZONE"
        fi
    fi
}

install_docker() { 
    print_step "Install Docker"
    if command -v docker &> /dev/null; then 
        echo -e "${YELLOW}Docker already installed.${NC}"
        SUMMARY_DOCKER_STATUS="Already installed"
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
    SUMMARY_DOCKER_STATUS="Installed"
    echo -e "${GREEN}Docker installed.${NC}"
}

install_frp() {
    print_step "Install FRPS"
    if [ -f "/etc/systemd/system/frps.service" ]; then 
        echo -e "${YELLOW}FRPS already installed.${NC}"
        SUMMARY_FRP_STATUS="Already installed"
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
    
    if command -v ufw &> /dev/null && [[ "$SUMMARY_UFW_STATUS" == "Enabled" ]]; then 
        ufw allow ${bind_port}/tcp
        SUMMARY_UFW_PORTS+=", ${bind_port}"
    fi
    
    echo "Verifying frps service..."
    sleep 2
    if systemctl is-active --quiet frps; then 
        SUMMARY_FRP_STATUS="Installed (v${vclean}, Port: ${bind_port})"
        echo -e "${GREEN}frps version ${vclean} installed and started successfully.${NC}"
    else 
        SUMMARY_FRP_STATUS="FAILED to start"
        echo -e "${RED}frps service failed to start! Check logs.${NC}"
    fi
}

display_summary() { 
    print_step "Final Summary"
    echo -e "------------ System Initialization Complete ------------"
    echo -e "  ${YELLOW}Hostname:${NC}\t\t$SUMMARY_HOSTNAME"
    echo -e "  ${YELLOW}Timezone:${NC}\t\t$SUMMARY_TIMEZONE"
    echo -e "  ${YELLOW}SSH Port (Mandatory):${NC}\t${GREEN}$SUMMARY_SSH_PORT (Verified)${NC}"
    echo -e "  ${YELLOW}SWAP Status:${NC}\t\t$SUMMARY_SWAP_STATUS"
    echo -e "  ${YELLOW}UFW Firewall:${NC}\t\t$SUMMARY_UFW_STATUS (Open: $SUMMARY_UFW_PORTS)"
    echo -e "  ${YELLOW}Fail2Ban:${NC}\t\t$SUMMARY_FAIL2BAN_STATUS"
    echo -e "  ${YELLOW}TCP Congestion Control:${NC}\t$SUMMARY_BBR_STATUS"
    echo -e "  ${YELLOW}Docker:${NC}\t\t\t$SUMMARY_DOCKER_STATUS"
    echo -e "  ${YELLOW}FRPS:${NC}\t\t\t$SUMMARY_FRP_STATUS"
    echo -e "----------------------------------------------------"
    echo -e "\n${RED}IMPORTANT: Use SSH port ${GREEN}$SUMMARY_SSH_PORT${NC} with your private key to log in.${NC}"
    echo -e "${YELLOW}If you skipped UFW, your server may be EXPOSED. Configure firewall immediately.${NC}"
}

main() { 
    check_root
    change_password
    configure_ssh
    update_and_install_tools
    
    if prompt_yes_no "Configure SWAP?"; then 
        configure_swap
    else 
        SUMMARY_SWAP_STATUS="Skipped by user"
    fi
    
    if prompt_yes_no "Configure Security (UFW/Fail2ban)?"; then 
        setup_security_tools
    fi
    
    if prompt_yes_no "Enable BBR?"; then 
        enable_bbr
    else 
        SUMMARY_BBR_STATUS="Skipped by user"
    fi
    
    if prompt_yes_no "Set Hostname & Timezone?"; then 
        set_hostname_timezone
    fi
    
    if prompt_yes_no "Install Docker?"; then 
        install_docker
    else 
        SUMMARY_DOCKER_STATUS="Skipped by user"
    fi
    
    if prompt_yes_no "Install FRPS?"; then 
        install_frp
    else 
        SUMMARY_FRP_STATUS="Skipped by user"
    fi
    
    display_summary
}

main
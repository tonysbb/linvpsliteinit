#!/bin/sh
# NOTE: Changed from bash to sh for Alpine compatibility (ash).

#================================================================================
# VPS Add-on Component Manager
#
# @author: Tony
# @contributors: Gemini, ChatGPT, Claude AI
# @description: A robust, idempotent script to manage VPS components including
#               SWAP, security tools, Docker, FRPS, and system optimizations.
# @os: Debian / Ubuntu / Alpine Linux
# @license: MIT
#================================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

LOG_FILE="/root/components_manager_$(date +%Y%m%d_%H%M%S).log"

start_logging() {
    exec 3>&1 4>&2

    if ! command -v mkfifo > /dev/null 2>&1; then
        exec > "$LOG_FILE" 2>&1
        return
    fi

    LOG_PIPE="/tmp/components_manager_$$.pipe"
    rm -f "$LOG_PIPE"
    if ! mkfifo "$LOG_PIPE"; then
        exec > "$LOG_FILE" 2>&1
        return
    fi

    tee -a "$LOG_FILE" < "$LOG_PIPE" &
    TEE_PID=$!
    exec > "$LOG_PIPE" 2>&1
    rm -f "$LOG_PIPE"
}

cleanup_logging() {
    if [ -n "${TEE_PID:-}" ]; then
        exec 1>&3 2>&4
        exec 3>&- 4>&-
        wait "$TEE_PID" 2>/dev/null || true
    else
        exec 3>&- 4>&-
    fi
}

start_logging
trap cleanup_logging EXIT
printf "${GREEN}Component Manager started. Log: ${YELLOW}%s${NC}\n" "$LOG_FILE"

# --- OS Detection ---
detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"; PKG_MGR="apk"
    elif [ -f /etc/debian_version ]; then
        OS="debian"; PKG_MGR="apt-get"
    else
        printf "${RED}Unsupported OS.${NC}\n"; exit 1
    fi
}

# --- Service Manager Abstraction ---
svc_start()     { [ "$OS" = "alpine" ] && rc-service "$1" start     || systemctl start "$1"; }
svc_restart()   { [ "$OS" = "alpine" ] && rc-service "$1" restart   || systemctl restart "$1"; }
svc_enable()    { [ "$OS" = "alpine" ] && rc-update add "$1" default || systemctl enable "$1"; }
svc_is_active() {
    if [ "$OS" = "alpine" ]; then rc-service "$1" status 2>&1 | grep -q "started"
    else systemctl is-active --quiet "$1"; fi
}

check_root() {
    [ "$(id -u)" -ne 0 ] && printf "${RED}Error: Must be run as root.${NC}\n" && exit 1
}

prompt_yes_no() {
    printf "%s (Y/n): " "$1"; read -r choice
    case "${choice:-Y}" in [Yy]*) return 0;; *) return 1;; esac
}

# =============================================================================
# COMPONENT FUNCTIONS
# =============================================================================

configure_swap() {
    printf "\n${BLUE}--- Configuring SWAP ---${NC}\n"

    mem_size_mb=$(free -m | awk '/^Mem:/{print $2}')
    current_swap_mb=$(free -m | awk '/^Swap:/{print $2}')
    swap_file_path="/swapfile_by_script"

    # NOTE: BUG FIX - original had cleanup code embedded inside an elif branch
    # body, but the indentation made it look like it was part of the elif condition.
    # In bash it happened to work, but it's logically wrong and breaks in sh.
    # Recommendation logic is now cleanly separated from cleanup logic.
    if   [ "$mem_size_mb" -lt 512 ];   then recommended_swap_mb=1024
    elif [ "$mem_size_mb" -lt 1024 ];  then recommended_swap_mb=1536
    elif [ "$mem_size_mb" -lt 2048 ];  then recommended_swap_mb=2048
    elif [ "$mem_size_mb" -lt 4096 ];  then recommended_swap_mb=3072
    elif [ "$mem_size_mb" -lt 8192 ];  then recommended_swap_mb=4096
    elif [ "$mem_size_mb" -lt 16384 ]; then recommended_swap_mb=6144
    else recommended_swap_mb=8192
    fi

    printf "Memory: %sMB, Current SWAP: %sMB\n" "$mem_size_mb" "$current_swap_mb"
    printf "Recommended SWAP: %sMB. Enter desired size (MB) or press Enter: " "$recommended_swap_mb"
    read -r user_target_mb
    target_swap_mb="${user_target_mb:-$recommended_swap_mb}"

    case "$target_swap_mb" in
        ''|*[!0-9]*) printf "${RED}Invalid input. Aborting.${NC}\n"; return 1 ;;
    esac

    if [ "$target_swap_mb" -le "$current_swap_mb" ]; then
        printf "${GREEN}Current SWAP size is sufficient. No action needed.${NC}\n"; return
    fi

    if [ -f "$swap_file_path" ]; then
        swapoff "$swap_file_path" 2>/dev/null || true
        rm -f "$swap_file_path"
        cp -a /etc/fstab "/etc/fstab.bak_$(date +%s)"
        sed -i '/swapfile_by_script/! s|^\([^#].*[[:space:]]\)swap\([[:space:]].*\)$|# \1swap\2|' /etc/fstab
        sed -i "\#${swap_file_path}#d" /etc/fstab
    fi

    printf "Creating %sMB swap file...\n" "$target_swap_mb"

    if command -v fallocate > /dev/null 2>&1; then
        printf "Using fallocate...\n"
        if ! fallocate -l "${target_swap_mb}M" "$swap_file_path" 2>/dev/null; then
            printf "${YELLOW}fallocate failed, falling back to dd...${NC}\n"
            dd if=/dev/zero of="$swap_file_path" bs=1M count="$target_swap_mb" status=progress
        fi
    else
        printf "Using dd (this may take a moment)...\n"
        dd if=/dev/zero of="$swap_file_path" bs=1M count="$target_swap_mb" status=progress
    fi

    chmod 600 "$swap_file_path" && mkswap "$swap_file_path" && swapon "$swap_file_path"

    if ! grep -qF "$swap_file_path" /etc/fstab; then
        printf "%s none swap sw 0 0\n" "$swap_file_path" >> /etc/fstab
    fi

    if ! grep -q "^vm.swappiness=10" /etc/sysctl.conf; then
        printf "\nvm.swappiness=10\n" >> /etc/sysctl.conf && sysctl -p > /dev/null
    fi

    printf "${GREEN}SWAP configured successfully.${NC}\n"
    free -h
}

setup_security_tools() {
    printf "\n${BLUE}--- Configuring Security ---${NC}\n"

    if [ "$OS" = "alpine" ]; then
        setup_security_alpine
    else
        setup_security_debian
    fi
}

setup_security_alpine() {
    # Detect current SSH port for firewall rule
    ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    ssh_port="${ssh_port:-22}"
    printf "Detected SSH port: %s\n" "$ssh_port"

    apk add --no-cache iptables ip6tables

    iptables -F; iptables -X
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    mkdir -p /etc/local.d
    cat > /etc/local.d/iptables.start << 'IEOF'
#!/bin/sh
iptables-restore < /etc/iptables/rules.v4
IEOF
    chmod +x /etc/local.d/iptables.start
    rc-update add local default 2>/dev/null || true

    printf "${GREEN}iptables configured. SSH port %s open.${NC}\n" "$ssh_port"
    printf "${YELLOW}To open additional ports:${NC}\n"
    printf "  iptables -A INPUT -p tcp --dport PORT -j ACCEPT\n"
    printf "  iptables -A INPUT -p udp --dport PORT -j ACCEPT  # for UDP services\n"
    printf "  iptables-save > /etc/iptables/rules.v4\n"
}

setup_security_debian() {
    # NOTE: Original used sshd -T which requires sshd to be running.
    # Safer to read from config file directly.
    ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    if [ -z "$ssh_port" ]; then
        printf "${RED}FATAL: Could not determine SSH port.${NC}\n"; return 1
    fi
    printf "Detected SSH port: ${GREEN}%s${NC}\n" "$ssh_port"

    if ! command -v ufw > /dev/null 2>&1; then
        printf "Installing UFW...\n"
        apt-get update > /dev/null
        apt-get install -y ufw
        ufw allow "$ssh_port/tcp"
        ufw --force enable
        printf "${GREEN}UFW installed and configured for SSH port %s.${NC}\n" "$ssh_port"
    else
        printf "${YELLOW}UFW is already installed.${NC}\n"
    fi

    if ! command -v fail2ban-client > /dev/null 2>&1; then
        printf "Installing Fail2ban...\n"
        apt-get install -y fail2ban
        cat > /etc/fail2ban/jail.d/sshd.local << EOF
[sshd]
enabled      = true
port         = $ssh_port
backend      = systemd
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
banaction    = ufw
EOF
        systemctl restart fail2ban
        sleep 3
        if systemctl is-active --quiet fail2ban; then
            printf "${GREEN}Fail2ban started successfully.${NC}\n"
        else
            printf "${RED}Fail2ban failed to start!${NC}\n"
        fi
    else
        printf "${YELLOW}Fail2ban is already installed.${NC}\n"
    fi
}

enable_bbr() {
    printf "\n${BLUE}--- Enabling BBR ---${NC}\n"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        printf "${YELLOW}BBR already enabled.${NC}\n"; return
    fi

    modprobe tcp_bbr 2>/dev/null || true

    if [ "$OS" = "alpine" ]; then
        grep -q "tcp_congestion_control" /etc/sysctl.conf || \
            printf "net.ipv4.tcp_congestion_control=bbr\n" >> /etc/sysctl.conf
        sysctl -q -e -p /etc/sysctl.conf 2>/dev/null || true
    else
        printf "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" \
            > /etc/sysctl.d/99-bbr.conf
        sysctl --system > /dev/null
    fi

    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        printf "${GREEN}BBR enabled.${NC}\n"
    else
        printf "${YELLOW}BBR could not be confirmed. Kernel may not support it.${NC}\n"
    fi
}

set_hostname_timezone() {
    printf "\n${BLUE}--- Setting Hostname & Timezone ---${NC}\n"
    printf "Enter new hostname (or press Enter to skip): "; read -r h
    if [ -n "$h" ]; then
        if [ "$OS" = "alpine" ]; then
            printf "%s\n" "$h" > /etc/hostname
            printf "hostname=\"%s\"\n" "$h" > /etc/conf.d/hostname
            hostname "$h"
            # NAT VPS workaround: some providers inject hostname at boot
            mkdir -p /etc/local.d
            printf '#!/bin/sh\nhostname %s\n' "$h" > /etc/local.d/hostname.start
            chmod +x /etc/local.d/hostname.start
            rc-update add local default 2>/dev/null || true
        else
            hostnamectl set-hostname "$h"
            printf "%s\n" "$h" > /etc/hostname
            hostname "$h"
            if grep -qE "^127\.0\.1\.1[[:space:]]" /etc/hosts; then
                sed -i "s|^\(127\.0\.1\.1[[:space:]]\+\).*|\1$h|" /etc/hosts
            else
                printf "127.0.1.1\t%s\n" "$h" >> /etc/hosts
            fi
        fi
        printf "Hostname set to %s\n" "$h"
    fi

    printf "Enter UTC offset (+8, -5) (or press Enter to skip): "; read -r o
    if [ -n "$o" ]; then
        sign="${o%${o#?}}"
        hrs="${o#?}"
        [ "$sign" = "+" ] && tz="Etc/GMT-${hrs}" || tz="Etc/GMT+${hrs}"

        if [ "$OS" = "alpine" ]; then
            apk add --no-cache tzdata 2>/dev/null || true
            cp "/usr/share/zoneinfo/${tz}" /etc/localtime 2>/dev/null && \
                printf "%s\n" "$tz" > /etc/timezone
        else
            timedatectl set-timezone "$tz"
        fi
        printf "Timezone set to %s (UTC%s)\n" "$tz" "$o"
    fi

    printf "${GREEN}Configuration complete.${NC}\n"
}

install_docker() {
    printf "\n${BLUE}--- Installing Docker ---${NC}\n"
    if command -v docker > /dev/null 2>&1; then
        printf "${YELLOW}Docker already installed.${NC}\n"; return
    fi

    if [ "$OS" = "alpine" ]; then
        apk add --no-cache docker docker-cli-compose
        rc-update add docker default
        rc-service docker start
        printf "${GREEN}Docker installed on Alpine.${NC}\n"
    else
        apt-get update > /dev/null
        apt-get install -y ca-certificates curl gnupg lsb-release
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && printf "%s" "$ID")/gpg" \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        mkdir -p /etc/apt/sources.list.d
        printf "deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n" \
            "$(dpkg --print-architecture)" \
            "$(. /etc/os-release && printf "%s" "$ID")" \
            "$(lsb_release -cs)" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update > /dev/null
        apt-get install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
        printf "${GREEN}Docker installed successfully.${NC}\n"
    fi
}

install_tmux() {
    printf "\n${BLUE}--- Installing tmux ---${NC}\n"
    if command -v tmux > /dev/null 2>&1; then
        printf "${YELLOW}tmux already installed.${NC}\n"; return
    fi

    if [ "$OS" = "alpine" ]; then
        apk add --no-cache tmux
    else
        apt-get install -y tmux
    fi

    if command -v tmux > /dev/null 2>&1; then
        printf "${GREEN}tmux installed successfully.${NC}\n"
    else
        printf "${RED}tmux installation failed.${NC}\n"
    fi
}

install_mosh() {
    printf "\n${BLUE}--- Installing mosh ---${NC}\n"

    if command -v mosh-server > /dev/null 2>&1; then
        printf "${YELLOW}mosh already installed. Continuing with firewall configuration.${NC}\n"
    else
        if [ "$OS" = "alpine" ]; then
            apk add --no-cache mosh
        else
            apt-get install -y mosh
        fi

        if ! command -v mosh-server > /dev/null 2>&1; then
            printf "${RED}mosh installation failed.${NC}\n"
            return 1
        fi
        printf "${GREEN}mosh installed successfully.${NC}\n"
    fi

    ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    ssh_port="${ssh_port:-22}"
    printf "mosh still uses SSH for login. Detected SSH port: %s\n" "$ssh_port"

    printf "Enter mosh UDP start port [60000]: "; read -r mosh_start_port
    mosh_start_port="${mosh_start_port:-60000}"
    printf "Enter mosh UDP end port [61000]: "; read -r mosh_end_port
    mosh_end_port="${mosh_end_port:-61000}"

    case "$mosh_start_port:$mosh_end_port" in
        *[!0-9:]*|:|*::*) printf "${RED}Invalid mosh port range.${NC}\n"; return 1 ;;
    esac

    if [ "$mosh_start_port" -lt 1 ] || [ "$mosh_start_port" -gt 65535 ] || \
       [ "$mosh_end_port" -lt 1 ] || [ "$mosh_end_port" -gt 65535 ] || \
       [ "$mosh_start_port" -gt "$mosh_end_port" ]; then
        printf "${RED}mosh port range must be 1-65535 and start <= end.${NC}\n"
        return 1
    fi

    mosh_range="${mosh_start_port}:${mosh_end_port}"

    if [ "$OS" = "alpine" ]; then
        if command -v iptables > /dev/null 2>&1 && iptables -L INPUT > /dev/null 2>&1; then
            iptables -C INPUT -p udp --dport "$mosh_range" -j ACCEPT 2>/dev/null || \
                iptables -A INPUT -p udp --dport "$mosh_range" -j ACCEPT
            iptables-save > /etc/iptables/rules.v4
            printf "iptables rule added for UDP %s-%s.\n" "$mosh_start_port" "$mosh_end_port"
        else
            printf "${YELLOW}iptables not active. Open UDP %s-%s manually if needed.${NC}\n" \
                "$mosh_start_port" "$mosh_end_port"
        fi
    else
        if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
            ufw allow "${mosh_start_port}:${mosh_end_port}/udp"
            printf "UFW rule added for UDP %s-%s.\n" "$mosh_start_port" "$mosh_end_port"
        else
            printf "${YELLOW}UFW not active. Open UDP %s-%s manually if needed.${NC}\n" \
                "$mosh_start_port" "$mosh_end_port"
        fi
    fi

    printf "${GREEN}mosh ready.${NC}\n"
}

install_frp() {
    printf "\n${BLUE}--- Installing FRPS ---${NC}\n"

    [ "$OS" = "alpine" ] && already_check="/etc/init.d/frps" || already_check="/etc/systemd/system/frps.service"
    if [ -f "$already_check" ]; then
        printf "${YELLOW}FRPS already installed.${NC}\n"; return
    fi

    printf "Enter frps bind port [7000]: ";      read -r bind_port; bind_port="${bind_port:-7000}"
    printf "Enter frps dashboard port [7500]: "; read -r dash_port; dash_port="${dash_port:-7500}"
    printf "Enter dashboard username [admin]: "; read -r dash_user; dash_user="${dash_user:-admin}"
    printf "Enter dashboard password [admin123]: "; read -r dash_pass; dash_pass="${dash_pass:-admin123}"

    default_token=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
    printf "Enter authentication token [%s]: " "$default_token"; read -r auth_token
    auth_token="${auth_token:-$default_token}"

    # NOTE: grep -Po is PCRE (bashism). Replaced with sed for POSIX compatibility.
    latest_version=$(curl -s "https://api.github.com/repos/fatedier/frp/releases/latest" \
        | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    if [ -z "$latest_version" ]; then
        printf "${RED}Could not fetch frp version.${NC}\n"; return 1
    fi

    vclean="${latest_version#v}"
    url="https://github.com/fatedier/frp/releases/download/${latest_version}/frp_${vclean}_linux_amd64.tar.gz"
    dir="/root/frp"
    mkdir -p "$dir"

    printf "Downloading frp %s...\n" "$latest_version"
    wget -qO /tmp/frp.tar.gz "$url" && tar -zxf /tmp/frp.tar.gz -C "$dir" --strip-components=1
    rm -f /tmp/frp.tar.gz
    chmod +x "${dir}/frps"

    cat > "${dir}/frps.toml" << EOF
bindPort = ${bind_port}
auth.method = "token"
auth.token = "${auth_token}"

webServer.port = ${dash_port}
webServer.user = "${dash_user}"
webServer.password = "${dash_pass}"

log.to = "${dir}/frps.log"
log.level = "info"
log.maxDays = 7
EOF

    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/frps << SVCEOF
#!/sbin/openrc-run
description="FRP Server"
command="${dir}/frps"
command_args="-c ${dir}/frps.toml"
command_background=true
pidfile=/run/frps.pid
output_log="${dir}/frps.log"
error_log="${dir}/frps.log"
depend() { need net; }
SVCEOF
        chmod +x /etc/init.d/frps
        rc-service frps start
        rc-update add frps default

        if iptables -L INPUT > /dev/null 2>&1; then
            iptables -A INPUT -p tcp --dport "$bind_port" -j ACCEPT
            iptables-save > /etc/iptables/rules.v4
            printf "iptables rule added for port %s.\n" "$bind_port"
        fi
    else
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

        if command -v ufw > /dev/null 2>&1; then
            ufw allow "${bind_port}/tcp"
            printf "UFW rule added for port %s.\n" "$bind_port"
        fi
    fi

    sleep 2
    if svc_is_active frps; then
        printf "${GREEN}frps %s installed and started successfully.${NC}\n" "$vclean"
    else
        printf "${RED}frps failed to start! Check %s/frps.log${NC}\n" "$dir"
    fi
}

# =============================================================================
# MAIN MENU
# =============================================================================
main() {
    check_root
    detect_os
    printf "${GREEN}OS: ${YELLOW}%s${NC}\n" "$OS"

    while true; do
        printf "\n${BLUE}VPS Component Manager${NC}\n"
        printf "OS: %s\n" "$OS"
        printf -- "-------------------------------------------\n"
        printf " 1) Configure SWAP\n"
        printf " 2) Setup Security (Firewall + Fail2ban)\n"
        printf " 3) Enable BBR\n"
        printf " 4) Set Hostname & Timezone\n"
        printf " 5) Install Docker\n"
        printf " 6) Install tmux\n"
        printf " 7) Install mosh\n"
        printf " 8) Install FRPS\n"
        printf -- "-------------------------------------------\n"
        printf " 99) Guided Install (all components)\n"
        printf " 0) Exit\n"
        printf -- "-------------------------------------------\n"
        printf "Enter your choice: "; read -r choice

        case "$choice" in
            1) configure_swap ;;
            2) setup_security_tools ;;
            3) enable_bbr ;;
            4) set_hostname_timezone ;;
            5) install_docker ;;
            6) install_tmux ;;
            7) install_mosh ;;
            8) install_frp ;;
            99)
                printf "${YELLOW}\nStarting Guided Installation...${NC}\n"
                prompt_yes_no "Configure SWAP?"       && configure_swap
                prompt_yes_no "Setup Security?"       && setup_security_tools
                prompt_yes_no "Enable BBR?"           && enable_bbr
                set_hostname_timezone
                prompt_yes_no "Install Docker?"       && install_docker
                prompt_yes_no "Install tmux?"         && install_tmux
                prompt_yes_no "Install mosh?"         && install_mosh
                prompt_yes_no "Install FRPS?"         && install_frp
                printf "${GREEN}\nGuided Installation finished.${NC}\n"
                ;;
            0) printf "Exiting.\n"; break ;;
            *) printf "${RED}Invalid option.${NC}\n" ;;
        esac
    done
}

main

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
prepare_log_file() { (umask 077; : > "$LOG_FILE"); chmod 600 "$LOG_FILE"; }

start_logging() {
    prepare_log_file
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

is_container() { [ -f /.dockerenv ] || [ -f /run/systemd/container ] || grep -qaE '(^|/)(docker|lxc|kubepods|containerd)(/|$)' /proc/1/cgroup 2>/dev/null; }
active_time_service() { for s in chrony chronyd ntp ntpd ntpsec openntpd systemd-timesyncd; do svc_is_active "$s" 2>/dev/null && { printf '%s\n' "$s"; return; }; done; return 1; }
zram_active() { awk 'NR>1 && $1 ~ /zram/ {ok=1} END {exit !ok}' /proc/swaps 2>/dev/null; }
zram_capable() { is_container && return 1; [ -d /sys/module/zram ] || { command -v modprobe >/dev/null 2>&1 && modprobe -n zram >/dev/null 2>&1; }; }
normalize_ram_mib() {
    ram_kib=$1
    ram_mib=$((ram_kib / 1024)); [ "$ram_mib" -ge 64 ] || ram_mib=64
    next_power=64
    while [ "$next_power" -lt "$ram_mib" ]; do next_power=$((next_power * 2)); done
    [ $((ram_kib * 10)) -ge $((next_power * 1024 * 9)) ] && ram_mib=$next_power
    printf '%s\n' "$ram_mib"
}
recommend_zram_mib() {
    half=$(( $1 / 2 )); [ "$half" -gt 4096 ] && half=4096
    zram_mib=64
    for tier in 128 256 512 1024 2048 4096; do [ "$half" -ge "$tier" ] && zram_mib=$tier; done
    printf '%s\n' "$zram_mib"
}
recommend_disk_swap_mib() {
    if [ "$1" -lt 2048 ]; then printf '%s\n' $(( $1 * 2 ))
    elif [ "$1" -lt 8192 ]; then printf '%s\n' "$1"
    else printf '4096\n'; fi
}
active_zram_swap_mib() { awk 'NR>1 && $1 ~ /zram/ {sum += $3} END {printf "%d\n", (sum + 512) / 1024}' "${PROC_SWAPS_PATH:-/proc/swaps}"; }
active_disk_swap_mib() { awk 'NR>1 && $1 !~ /zram/ {sum += $3} END {printf "%d\n", (sum + 512) / 1024}' "${PROC_SWAPS_PATH:-/proc/swaps}"; }
active_zram_devices() { awk 'NR>1 && $1 ~ /zram/ {print $1}' /proc/swaps | sort; }
managed_zram_config() { grep -qF 'Managed by linvpsliteinit' "$1" 2>/dev/null; }
swapoff_has_headroom() {
    used_kib=$1
    ram_kib=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    available_kib=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    margin_kib=$((ram_kib / 10)); [ "$margin_kib" -ge 262144 ] || margin_kib=262144
    [ "$available_kib" -ge $((used_kib + margin_kib)) ]
}
swap_used_kib() { awk -v dev="$1" 'NR>1 && $1 == dev {sum += $4} END {printf "%d\n", sum}' /proc/swaps; }
remove_managed_swap() {
    swap_file=/swapfile_by_script
    [ -e "$swap_file" ] || { printf "${YELLOW}Managed disk SWAP does not exist.${NC}\n"; return 0; }
    used_kib=$(swap_used_kib "$swap_file")
    swapoff_has_headroom "$used_kib" || { printf "${RED}Not enough MemAvailable to disable managed disk SWAP safely.${NC}\n"; return 1; }
    prompt_yes_no "Remove only $swap_file and its exact fstab entry?" || return 0
    fstab_backup="/etc/fstab.bak_$(date +%s)"; fstab_tmp="/etc/fstab.linvpsliteinit.$$"
    cp -a /etc/fstab "$fstab_backup" || return 1
    was_active=0
    if awk -v dev="$swap_file" 'NR>1 && $1 == dev {found=1} END {exit !found}' /proc/swaps; then
        was_active=1
        swapoff "$swap_file" || { printf "${RED}swapoff failed; configuration and file were preserved.${NC}\n"; return 1; }
        awk -v dev="$swap_file" 'NR>1 && $1 == dev {found=1} END {exit !found}' /proc/swaps && { printf "${RED}Managed disk SWAP is still active; configuration and file were preserved.${NC}\n"; return 1; }
    fi
    if ! awk -v dev="$swap_file" '!($1 == dev && $3 == "swap")' /etc/fstab > "$fstab_tmp" || ! cat "$fstab_tmp" > /etc/fstab; then
        cp -a "$fstab_backup" /etc/fstab; rm -f "$fstab_tmp"; [ "$was_active" -eq 0 ] || swapon -p 10 "$swap_file" 2>/dev/null || true
        printf "${RED}fstab update failed; the backup was restored and the swap file was preserved.${NC}\n"; return 1
    fi
    rm -f "$fstab_tmp"
    systemctl daemon-reload 2>/dev/null || true
    if ! rm -f "$swap_file"; then
        cp -a "$fstab_backup" /etc/fstab; [ "$was_active" -eq 0 ] || swapon -p 10 "$swap_file" 2>/dev/null || true
        printf "${RED}Could not remove the managed swap file; fstab and active state were restored where possible.${NC}\n"; return 1
    fi
    printf "${GREEN}Managed disk SWAP removed.${NC}\n"
}
remove_managed_zram() {
    if [ "$OS" = "alpine" ]; then zram_config=/etc/conf.d/zram-init; zram_service=zram-init
    else zram_config=/etc/default/zramswap; zram_service=zramswap; fi
    managed_zram_config "$zram_config" || { printf "${YELLOW}No linvpsliteinit-managed ZRAM configuration found; nothing was changed.${NC}\n"; return 0; }
    used_kib=$(awk 'NR>1 && $1 ~ /zram/ {sum += $4} END {printf "%d\n", sum}' /proc/swaps)
    swapoff_has_headroom "$used_kib" || { printf "${RED}Not enough available memory to stop ZRAM safely.${NC}\n"; return 1; }
    prompt_yes_no "Remove only linvpsliteinit-managed ZRAM?" || return 0
    zram_remove_was_active=0; svc_is_active "$zram_service" && zram_remove_was_active=1
    if [ "$OS" = "alpine" ]; then
        zram_remove_was_enabled=0; rc-update show default 2>/dev/null | grep -qw "$zram_service" && zram_remove_was_enabled=1
    else
        zram_remove_was_enabled=0; systemctl is-enabled --quiet "$zram_service" 2>/dev/null && zram_remove_was_enabled=1
    fi
    zram_before=$(active_zram_devices)
    if [ "$OS" = "alpine" ]; then rc-service "$zram_service" stop || return 1
    else systemctl stop "$zram_service" || return 1; fi
    zram_after=$(active_zram_devices)
    if [ "$zram_remove_was_active" -eq 1 ] && [ "$zram_before" = "$zram_after" ]; then
        if [ "$OS" = "alpine" ]; then rc-service "$zram_service" start 2>/dev/null || true
        else systemctl start "$zram_service" 2>/dev/null || true; fi
        printf "${RED}Managed ZRAM did not leave /proc/swaps; service state was restored where possible.${NC}\n"; return 1
    fi
    if [ "$OS" = "alpine" ]; then
        rc-update del "$zram_service" default 2>/dev/null || true
        rc-update show default 2>/dev/null | grep -qw "$zram_service" && { [ "$zram_remove_was_active" -eq 0 ] || rc-service "$zram_service" start 2>/dev/null || true; printf "${RED}Could not disable ZRAM at boot; configuration was preserved.${NC}\n"; return 1; }
    else
        systemctl disable "$zram_service" 2>/dev/null || true
        systemctl is-enabled --quiet "$zram_service" 2>/dev/null && { [ "$zram_remove_was_active" -eq 0 ] || systemctl start "$zram_service" 2>/dev/null || true; printf "${RED}Could not disable ZRAM at boot; configuration was preserved.${NC}\n"; return 1; }
    fi
    if ! rm -f "$zram_config"; then
        if [ "$OS" = "alpine" ]; then
            [ "$zram_remove_was_enabled" -eq 0 ] || rc-update add "$zram_service" default 2>/dev/null || true
            [ "$zram_remove_was_active" -eq 0 ] || rc-service "$zram_service" start 2>/dev/null || true
        else
            [ "$zram_remove_was_enabled" -eq 0 ] || systemctl enable "$zram_service" 2>/dev/null || true
            [ "$zram_remove_was_active" -eq 0 ] || systemctl start "$zram_service" 2>/dev/null || true
        fi
        printf "${RED}Could not remove the ZRAM configuration; service state was restored where possible.${NC}\n"; return 1
    fi
    printf "${GREEN}Managed ZRAM removed; its package was preserved.${NC}\n"
}
chrony_rollback() { if [ "$OS" = "alpine" ]; then rc-service chronyd stop 2>/dev/null || true; rc-update del chronyd default 2>/dev/null || true; else systemctl disable --now chrony 2>/dev/null || true; fi; [ "${timesyncd_disabled:-0}" -eq 1 ] && systemctl enable --now systemd-timesyncd 2>/dev/null || true; }
zram_rollback() {
    if [ "$OS" = "alpine" ]; then rc-service zram-init stop 2>/dev/null || true; rc-update del zram-init default 2>/dev/null || true
    else systemctl disable --now zramswap 2>/dev/null || true; fi
    if [ -n "$zram_backup" ]; then
        [ -f "$zram_backup" ] && cp -a "$zram_backup" "$zram_config" || return 1
        cmp -s "$zram_backup" "$zram_config" || return 1
    else
        rm -f "$zram_config" || return 1
        [ ! -e "$zram_config" ] || return 1
    fi
}
restore_previous_zram() {
    zram_rollback || return 1
    if [ "$OS" = "alpine" ]; then
        [ "$zram_was_enabled" -eq 0 ] || rc-update add zram-init default >/dev/null 2>&1 || return 1
        [ "$zram_was_active" -eq 0 ] || rc-service zram-init start >/dev/null 2>&1 || return 1
        current_enabled=0; rc-update show default 2>/dev/null | grep -qw zram-init && current_enabled=1
        current_active=0; svc_is_active zram-init && current_active=1
    else
        [ "$zram_was_enabled" -eq 0 ] || systemctl enable zramswap >/dev/null 2>&1 || return 1
        [ "$zram_was_active" -eq 0 ] || systemctl start zramswap >/dev/null 2>&1 || return 1
        current_enabled=0; systemctl is-enabled --quiet zramswap 2>/dev/null && current_enabled=1
        current_active=0; svc_is_active zramswap && current_active=1
    fi
    [ "$current_enabled" -eq "$zram_was_enabled" ] && [ "$current_active" -eq "$zram_was_active" ]
}

# =============================================================================
# COMPONENT FUNCTIONS
# =============================================================================

configure_swap() {
    printf "\n${BLUE}--- Configuring SWAP ---${NC}\n"

    mem_size_mb=$(normalize_ram_mib "$(awk '/^MemTotal:/{print $2}' /proc/meminfo)")
    current_swap_mb=$(active_disk_swap_mib)
    swap_file_path="/swapfile_by_script"

    recommended_swap_mb=$(recommend_disk_swap_mib "$mem_size_mb")

    printf "Memory: %sMiB, ZRAM: %sMiB, disk SWAP: %sMiB\n" "$mem_size_mb" "$(active_zram_swap_mib)" "$current_swap_mb"
    [ "$mem_size_mb" -gt 65536 ] && printf "${YELLOW}For RAM above 64GiB, 4096MiB is only a baseline; size by workload.${NC}\n"
    printf "Recommended disk SWAP: %sMiB. Enter desired size or press Enter: " "$recommended_swap_mb"
    read -r user_target_mb
    target_swap_mb="${user_target_mb:-$recommended_swap_mb}"

    case "$target_swap_mb" in
        ''|*[!0-9]*) printf "${RED}Invalid input. Aborting.${NC}\n"; return 1 ;;
    esac

    if [ "$target_swap_mb" -le "$current_swap_mb" ]; then
        printf "${GREEN}Current SWAP size is sufficient. No action needed.${NC}\n"; return
    fi

    if [ -f "$swap_file_path" ]; then
        printf "${YELLOW}Existing managed swap file found; leaving it unchanged.${NC}\n"
        return 0
    fi
    fstab_backup="/etc/fstab.bak_$(date +%s)"
    cp -a /etc/fstab "$fstab_backup" || return 1

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

    if ! chmod 600 "$swap_file_path" || ! mkswap "$swap_file_path" > /dev/null 2>&1 || ! swapon -p 10 "$swap_file_path"; then
        rm -f "$swap_file_path"
        cp -a "$fstab_backup" /etc/fstab
        printf "${RED}SWAP activation failed; previous fstab restored.${NC}\n"
        return 1
    fi

    if ! grep -qF "$swap_file_path" /etc/fstab; then
        printf "%s none swap sw,pri=10 0 0\n" "$swap_file_path" >> /etc/fstab
    fi

    if ! grep -q "^vm.swappiness=10" /etc/sysctl.conf; then
        printf "\nvm.swappiness=10\n" >> /etc/sysctl.conf && sysctl -p > /dev/null
    fi

    printf "${GREEN}SWAP configured successfully.${NC}\n"
    free -h
}

install_chrony() {
    printf "\n${BLUE}--- Install Chrony ---${NC}\n"
    if is_container; then printf "${YELLOW}Container detected; skipping.${NC}\n"; return 0; fi
    current_time_service=$(active_time_service || true)
    timesyncd_disabled=0
    case "$current_time_service" in
        chrony|chronyd) printf "${GREEN}Chrony already active; no restart.${NC}\n"; return 0 ;;
        ntp|ntpd|ntpsec|openntpd) printf "${RED}NTP conflict: %s${NC}\n" "$current_time_service"; return 1 ;;
        systemd-timesyncd) prompt_yes_no "Replace systemd-timesyncd with chrony?" || return 0; systemctl disable --now systemd-timesyncd || return 1; timesyncd_disabled=1 ;;
    esac
    if [ "$OS" = "alpine" ]; then apk add --no-cache chrony && rc-update add chronyd default && rc-service chronyd start || { chrony_rollback; return 1; }; chrony_service=chronyd
    else apt-get update > /dev/null && apt-get install -y chrony && systemctl enable --now chrony || { chrony_rollback; return 1; }; chrony_service=chrony
    fi
    svc_is_active "$chrony_service" || { chrony_rollback; return 1; }
}

configure_zram() {
    printf "\n${BLUE}--- Configure ZRAM ---${NC}\n"
    if is_container || { [ -r /sys/module/zswap/parameters/enabled ] && [ "$(cat /sys/module/zswap/parameters/enabled)" = Y ]; } || ! zram_capable; then printf "${YELLOW}ZRAM skipped: conflicting or unsupported environment.${NC}\n"; return 0; fi
    ram_mib=$(normalize_ram_mib "$(awk '/^MemTotal:/{print $2}' /proc/meminfo)")
    recommended_zram_mib=$(recommend_zram_mib "$ram_mib")
    printf "Recommended ZRAM: %sMiB. Enter size or press Enter: " "$recommended_zram_mib"
    read -r zram_size_mb; zram_size_mb="${zram_size_mb:-$recommended_zram_mib}"
    case "$zram_size_mb" in 64|128|256|512|1024|2048|4096) ;; *) printf "${RED}Use one of: 64 128 256 512 1024 2048 4096.${NC}\n"; return 1 ;; esac
    if [ "$OS" = "alpine" ]; then
        zram_config=/etc/conf.d/zram-init
        zram_was_enabled=0; rc-update show default 2>/dev/null | grep -qw zram-init && zram_was_enabled=1
        zram_was_active=0; svc_is_active zram-init && zram_was_active=1
        zram_had_config=0; [ -f "$zram_config" ] && zram_had_config=1
        [ -f "$zram_config" ] && ! managed_zram_config "$zram_config" && { printf "${YELLOW}Unmanaged ZRAM configuration exists; leaving it unchanged.${NC}\n"; return 0; }
        zram_active && [ ! -f "$zram_config" ] && { printf "${YELLOW}Unmanaged ZRAM active; leaving it unchanged.${NC}\n"; return 0; }
        zram_active && ! swapoff_has_headroom "$(awk 'NR>1 && $1 ~ /zram/ {sum += $4} END {printf "%d\n", sum}' /proc/swaps)" && { printf "${RED}Insufficient memory to resize ZRAM safely.${NC}\n"; return 1; }
        zram_backup=""; [ "$zram_had_config" -eq 0 ] || { zram_backup="${zram_config}.bak_$(date +%s)"; cp -a "$zram_config" "$zram_backup" || return 1; }
        printf '# Managed by linvpsliteinit.\nload_on_start=yes\nunload_on_stop=yes\nnum_devices=1\ntype0=swap\nflag0=100\nsize0=%s\nlabl0=zram_swap\n' "$zram_size_mb" > "$zram_config" || { restore_previous_zram; return 1; }
        apk add --no-cache zram-init || { restore_previous_zram; return 1; }
        rc-update add zram-init default && rc-service zram-init restart || { restore_previous_zram; return 1; }; zram_service=zram-init
    else
        zram_config=/etc/default/zramswap
        zram_was_enabled=0; systemctl is-enabled --quiet zramswap 2>/dev/null && zram_was_enabled=1
        zram_was_active=0; svc_is_active zramswap && zram_was_active=1
        zram_had_config=0; [ -f "$zram_config" ] && zram_had_config=1
        [ -f "$zram_config" ] && ! managed_zram_config "$zram_config" && { printf "${YELLOW}Unmanaged ZRAM configuration exists; leaving it unchanged.${NC}\n"; return 0; }
        zram_active && [ ! -f "$zram_config" ] && { printf "${YELLOW}Unmanaged ZRAM active; leaving it unchanged.${NC}\n"; return 0; }
        zram_active && ! swapoff_has_headroom "$(awk 'NR>1 && $1 ~ /zram/ {sum += $4} END {printf "%d\n", sum}' /proc/swaps)" && { printf "${RED}Insufficient memory to resize ZRAM safely.${NC}\n"; return 1; }
        zram_backup=""; [ "$zram_had_config" -eq 0 ] || { zram_backup="${zram_config}.bak_$(date +%s)"; cp -a "$zram_config" "$zram_backup" || return 1; }
        printf '# Managed by linvpsliteinit.\nSIZE=%s\nPRIORITY=100\n' "$zram_size_mb" > "$zram_config" || { restore_previous_zram; return 1; }
        apt-get update > /dev/null && apt-get install -y zram-tools || { restore_previous_zram; return 1; }
        zram_service=zramswap
        systemctl enable "$zram_service" && systemctl restart "$zram_service" || { restore_previous_zram; return 1; }
    fi
    svc_is_active "$zram_service" && zram_active || { restore_previous_zram; printf "${RED}ZRAM failed.${NC}\n"; return 1; }
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

recommend_network_tuning() {
    mem_size_mb=$(free -m | awk '/^Mem:/{print $2}')

    if [ -z "$mem_size_mb" ] || [ "$mem_size_mb" -lt 1024 ]; then
        recommended_nofile=16384
        recommended_somaxconn=1024
        recommended_syn_backlog=2048
        recommended_buffer_max=4194304
        recommended_file_max=262144
    elif [ "$mem_size_mb" -lt 2048 ]; then
        recommended_nofile=32768
        recommended_somaxconn=2048
        recommended_syn_backlog=4096
        recommended_buffer_max=8388608
        recommended_file_max=524288
    elif [ "$mem_size_mb" -lt 4096 ]; then
        recommended_nofile=51200
        recommended_somaxconn=4096
        recommended_syn_backlog=4096
        recommended_buffer_max=16777216
        recommended_file_max=1048576
    else
        recommended_nofile=65535
        recommended_somaxconn=4096
        recommended_syn_backlog=8192
        recommended_buffer_max=16777216
        recommended_file_max=2097152
    fi
}

apply_advanced_network_tuning() {
    printf "\n${BLUE}--- Applying Advanced Network Tuning ---${NC}\n"
    printf "${YELLOW}Recommended for proxy, FRP, relay, or other high-concurrency workloads.${NC}\n"
    printf "${YELLOW}These settings are conservative defaults, not mandatory for every VPS.${NC}\n"

    recommend_network_tuning
    printf "Detected memory: %sMB\n" "${mem_size_mb:-unknown}"
    printf "Recommended profile:\n"
    printf "  somaxconn: %s\n" "$recommended_somaxconn"
    printf "  tcp_max_syn_backlog: %s\n" "$recommended_syn_backlog"
    printf "  rmem/wmem max: %s bytes\n" "$recommended_buffer_max"
    printf "  fs.file-max: %s\n" "$recommended_file_max"
    printf "  nofile: %s\n" "$recommended_nofile"

    printf "Enter nofile limit [%s]: " "$recommended_nofile"; read -r nofile_limit
    nofile_limit="${nofile_limit:-$recommended_nofile}"
    case "$nofile_limit" in
        ''|*[!0-9]*) printf "${RED}Invalid nofile limit.${NC}\n"; return 1 ;;
    esac
    if [ "$nofile_limit" -lt 1024 ]; then
        printf "${RED}nofile limit must be at least 1024.${NC}\n"
        return 1
    fi

    tfo_value=0
    if prompt_yes_no "Enable TCP Fast Open (TFO)?"; then
        tfo_value=3
    fi

    if [ "$OS" = "alpine" ]; then
        sysctl_file="/etc/sysctl.conf"
        touch "$sysctl_file"
        cp -a "$sysctl_file" "${sysctl_file}.bak_$(date +%s)" 2>/dev/null || true
        sed -i '/# --- linvpsliteinit advanced network tuning (start) ---/,/# --- linvpsliteinit advanced network tuning (end) ---/d' "$sysctl_file"
        cat >> "$sysctl_file" << EOF
# --- linvpsliteinit advanced network tuning (start) ---
net.core.somaxconn=${recommended_somaxconn}
net.ipv4.tcp_max_syn_backlog=${recommended_syn_backlog}
net.core.rmem_max=${recommended_buffer_max}
net.core.wmem_max=${recommended_buffer_max}
net.ipv4.tcp_rmem=4096 87380 ${recommended_buffer_max}
net.ipv4.tcp_wmem=4096 65536 ${recommended_buffer_max}
net.ipv4.tcp_fastopen=${tfo_value}
fs.file-max=${recommended_file_max}
# --- linvpsliteinit advanced network tuning (end) ---
EOF
        sysctl -q -e -p "$sysctl_file" 2>/dev/null || true
    else
        sysctl_file="/etc/sysctl.d/99-advanced-network.conf"
        cat > "$sysctl_file" << EOF
# Managed by linvpsliteinit add_components.sh
net.core.somaxconn=${recommended_somaxconn}
net.ipv4.tcp_max_syn_backlog=${recommended_syn_backlog}
net.core.rmem_max=${recommended_buffer_max}
net.core.wmem_max=${recommended_buffer_max}
net.ipv4.tcp_rmem=4096 87380 ${recommended_buffer_max}
net.ipv4.tcp_wmem=4096 65536 ${recommended_buffer_max}
net.ipv4.tcp_fastopen=${tfo_value}
fs.file-max=${recommended_file_max}
EOF
        sysctl --system > /dev/null
    fi

    mkdir -p /etc/security/limits.d
    cat > /etc/security/limits.d/99-linvpsliteinit-nofile.conf << EOF
# Managed by linvpsliteinit add_components.sh
* soft nofile ${nofile_limit}
* hard nofile ${nofile_limit}
root soft nofile ${nofile_limit}
root hard nofile ${nofile_limit}
EOF

    mkdir -p /etc/profile.d
    cat > /etc/profile.d/99-linvpsliteinit-nofile.sh << EOF
# Managed by linvpsliteinit add_components.sh
ulimit -n ${nofile_limit} >/dev/null 2>&1 || true
EOF

    if [ -f /etc/systemd/system/frps.service ]; then
        if grep -q "^LimitNOFILE=" /etc/systemd/system/frps.service; then
            sed -i "s/^LimitNOFILE=.*/LimitNOFILE=${nofile_limit}/" /etc/systemd/system/frps.service
        else
            sed -i "/^Restart=always$/a LimitNOFILE=${nofile_limit}" /etc/systemd/system/frps.service
        fi
        systemctl daemon-reload
        if systemctl is-active --quiet frps; then
            systemctl restart frps
            printf "Updated frps.service with LimitNOFILE=%s and restarted FRPS.\n" "$nofile_limit"
        else
            printf "Updated frps.service with LimitNOFILE=%s.\n" "$nofile_limit"
        fi
    fi

    printf "${GREEN}Advanced network tuning applied.${NC}\n"
    printf "  somaxconn: %s\n" "$recommended_somaxconn"
    printf "  tcp_max_syn_backlog: %s\n" "$recommended_syn_backlog"
    printf "  rmem/wmem max: %s bytes\n" "$recommended_buffer_max"
    printf "  fs.file-max: %s\n" "$recommended_file_max"
    printf "  tcp_fastopen: %s\n" "$tfo_value"
    printf "  nofile: %s\n" "$nofile_limit"
    printf "${YELLOW}Log out and reconnect for shell nofile limits to fully apply.${NC}\n"
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
LimitNOFILE=51200
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
        printf " 1) Configure disk SWAP\n"
        printf " 2) Configure ZRAM\n"
        printf " 3) Install Chrony\n"
        printf " 4) Setup Security (Firewall + Fail2ban)\n"
        printf " 5) Enable BBR\n"
        printf " 6) Set Hostname & Timezone\n"
        printf " 7) Install Docker\n"
        printf " 8) Install tmux\n"
        printf " 9) Install mosh\n"
        printf " 10) Install FRPS\n"
        printf " 11) Advanced Network Tuning\n"
        printf " 12) Remove managed disk SWAP\n"
        printf " 13) Remove managed ZRAM\n"
        printf -- "-------------------------------------------\n"
        printf " 99) Guided Install (all components)\n"
        printf " 0) Exit\n"
        printf -- "-------------------------------------------\n"
        printf "Enter your choice: "; read -r choice

        case "$choice" in
            1) configure_swap ;;
            2) configure_zram ;;
            3) install_chrony ;;
            4) setup_security_tools ;;
            5) enable_bbr ;;
            6) set_hostname_timezone ;;
            7) install_docker ;;
            8) install_tmux ;;
            9) install_mosh ;;
            10) install_frp ;;
            11) apply_advanced_network_tuning ;;
            12) remove_managed_swap ;;
            13) remove_managed_zram ;;
            99)
                printf "${YELLOW}\nStarting Guided Installation...${NC}\n"
                prompt_yes_no "Configure SWAP?"       && configure_swap
                prompt_yes_no "Configure ZRAM?"        && configure_zram
                prompt_yes_no "Install Chrony?"        && install_chrony
                prompt_yes_no "Setup Security?"       && setup_security_tools
                prompt_yes_no "Enable BBR?"           && enable_bbr
                set_hostname_timezone
                prompt_yes_no "Install Docker?"       && install_docker
                prompt_yes_no "Install tmux?"         && install_tmux
                prompt_yes_no "Install mosh?"         && install_mosh
                prompt_yes_no "Install FRPS?"         && install_frp
                prompt_yes_no "Apply advanced network tuning?" && apply_advanced_network_tuning
                printf "${GREEN}\nGuided Installation finished.${NC}\n"
                ;;
            0) printf "Exiting.\n"; break ;;
            *) printf "${RED}Invalid option.${NC}\n" ;;
        esac
    done
}

main

#!/bin/sh
# NOTE: Changed from bash to sh for Alpine compatibility (ash).
# All bashisms (double brackets, echo -e, etc.) replaced with POSIX sh equivalents.

#================================================================================
# VPS Initialization Script
#
# @author: Tony
# @contributors: Gemini, ChatGPT, Claude AI
# @description: A flexible, interactive script for VPS initial setup with
#               SSH hardening, security tools, and system optimization.
# @os: Debian / Ubuntu / Alpine Linux
# @license: MIT
#================================================================================

# --- Color Definitions ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# NOTE: Removed global `set -e`. It causes silent exits when any subcommand fails,
# making interactive scripts extremely hard to debug. Functions now handle errors
# individually with explicit checks.

LOG_FILE="/root/vps_init_$(date +%Y%m%d_%H%M%S).log"
prepare_log_file() { (umask 077; : > "$LOG_FILE"); chmod 600 "$LOG_FILE"; }

start_logging() {
    prepare_log_file
    exec 3>&1 4>&2

    if ! command -v mkfifo > /dev/null 2>&1; then
        exec > "$LOG_FILE" 2>&1
        return
    fi

    LOG_PIPE="/tmp/vps_init_$$.pipe"
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
printf "${GREEN}Script started. Log: ${YELLOW}%s${NC}\n" "$LOG_FILE"

# --- OS Detection ---
# Detect OS once at startup; all functions branch on this variable.
detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
        PKG_MGR="apk"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        PKG_MGR="apt-get"
    else
        printf "${RED}Unsupported OS. Exiting.${NC}\n"
        exit 1
    fi
    printf "${GREEN}Detected OS: ${YELLOW}${OS}${NC}\n"
}

# --- Service Manager Abstraction ---
# Alpine uses OpenRC; Debian/Ubuntu uses systemd.
svc_start()   { 
    if [ "$OS" = "alpine" ]; then rc-service "$1" start; 
    else systemctl start "$1"; fi
}
svc_restart() { 
    if [ "$OS" = "alpine" ]; then rc-service "$1" restart; 
    else systemctl restart "$1"; fi
}
svc_enable()  { 
    if [ "$OS" = "alpine" ]; then rc-update add "$1" default; 
    else systemctl enable "$1"; fi
}
svc_is_active() {
    if [ "$OS" = "alpine" ]; then rc-service "$1" status 2>&1 | grep -q "started";
    else systemctl is-active --quiet "$1"; fi
}

# --- Package Install Abstraction ---
pkg_install() {
    if [ "$OS" = "alpine" ]; then apk add --no-cache "$@";
    else apt-get install -y "$@"; fi
}

# --- Summary Variables ---
SUMMARY_SSH_PORT=""
SUMMARY_HOSTNAME="$(hostname)"
SUMMARY_TIMEZONE="Default"
SUMMARY_SWAP_STATUS="Skipped"
SUMMARY_ZRAM_STATUS="Skipped"
SUMMARY_CHRONY_STATUS="Skipped"
SUMMARY_FIREWALL_STATUS="Skipped"
SUMMARY_FIREWALL_PORTS="N/A"
SUMMARY_FAIL2BAN_STATUS="Skipped"
SUMMARY_BBR_STATUS="Skipped"
SUMMARY_DOCKER_STATUS="Skipped"
SUMMARY_TMUX_STATUS="Skipped"
SUMMARY_MOSH_STATUS="Skipped"
SUMMARY_FRP_STATUS="Skipped"

# --- Helper Functions ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "${RED}Error: Must be run as root.${NC}\n"; exit 1
    fi
}

print_step() {
    printf "\n${BLUE}=======================================================\n"
    printf "${YELLOW}>> Step: %s${NC}\n" "$1"
    printf "${BLUE}=======================================================${NC}\n"
}

prompt_yes_no() {
    # NOTE: [[ ]] is a bashism. Replaced with case statement for POSIX sh.
    printf "%s (Y/n): " "$1"
    read -r choice
    case "${choice:-Y}" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
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
# CORE FUNCTIONS
# =============================================================================

change_password() {
    print_step "Set root Password (Mandatory)"
    printf "Please set a new password for the root user.\n"
    passwd
    printf "${GREEN}Password changed successfully.${NC}\n"
}

configure_ssh() {
    print_step "Configure SSH (Mandatory)"

    # Validate SSH port input
    while true; do
        printf "Enter a new SSH port (1025-65535): "
        read -r new_ssh_port
        # NOTE: [[ =~ ]] is a bashism. Use case or expr for POSIX sh.
        case "$new_ssh_port" in
            ''|*[!0-9]*)
                printf "${RED}Invalid input: not a number.${NC}\n"; continue ;;
        esac
        if [ "$new_ssh_port" -gt 1024 ] && [ "$new_ssh_port" -lt 65536 ]; then
            break
        fi
        printf "${RED}Port must be between 1025 and 65535.${NC}\n"
    done
    SUMMARY_SSH_PORT="$new_ssh_port"

    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    # NOTE: -q suppresses output to tty; key is generated server-side for display.
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
    cat ~/.ssh/id_ed25519.pub > ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

    printf "\n${YELLOW}!!! IMPORTANT: Copy and save the private key below. !!!${NC}\n" >&3
    printf "${RED}--- PRIVATE KEY START ---${NC}\n" >&3
    cat ~/.ssh/id_ed25519 >&3
    printf "${RED}---  PRIVATE KEY END  ---${NC}\n" >&3

    while true; do
        printf "Have you saved the private key? (yes/no): "
        read -r c
        [ "$c" = "yes" ] && break
    done
    rm -f ~/.ssh/id_ed25519

    # Modify sshd_config
    SSHD_CONFIG="/etc/ssh/sshd_config"
    # NOTE: Original used sed -E with complex regex that can fail silently if lines
    # are commented differently. Safer to write a clean config from scratch.
    # We preserve any existing Include directives on Alpine/Debian 12.
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
    # Remove old Port/Auth lines, then append clean config
    grep -vE "^[[:space:]]*(#[[:space:]]*)?(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)[[:space:]]" \
        "$SSHD_CONFIG" > "${SSHD_CONFIG}.tmp"
    cat >> "${SSHD_CONFIG}.tmp" << EOF

# --- Added by vps_init.sh ---
Port ${SUMMARY_SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF
    mv "${SSHD_CONFIG}.tmp" "$SSHD_CONFIG"

    # Restart SSH
    # NOTE: On Alpine the service is named 'sshd'; on Debian it may be 'ssh' or 'sshd'.
    if [ "$OS" = "alpine" ]; then
        rc-service sshd restart
        SSHD_SVC="sshd"
    else
        # Debian 11/12: service name may be 'ssh' or 'sshd'
        if systemctl list-units --type=service | grep -q "^  ssh\.service"; then
            SSHD_SVC="ssh"
        else
            SSHD_SVC="sshd"
        fi
        systemctl restart "$SSHD_SVC"
    fi

    sleep 2

    # Verify SSH port
    if ! sshd -T | grep -q "port $SUMMARY_SSH_PORT"; then
        printf "${RED}FATAL: SSH verification failed! Check config manually via VNC.${NC}\n"
        exit 1
    fi
    printf "${GREEN}SSH is now running on port %s.${NC}\n" "$SUMMARY_SSH_PORT"
}

update_and_install_tools() {
    print_step "Update System & Install Tools (Mandatory)"
    if [ "$OS" = "alpine" ]; then
        apk update
        apk add --no-cache curl wget bind-tools traceroute ca-certificates openssl
    else
        apt-get update > /dev/null
        apt-get install -y curl wget dnsutils traceroute \
            software-properties-common ca-certificates gnupg lsb-release
    fi
    printf "${GREEN}System updated and tools installed.${NC}\n"
}

install_chrony() {
    print_step "Configure Chrony"
    if is_container; then SUMMARY_CHRONY_STATUS="Skipped: container"; return 0; fi
    current_time_service=$(active_time_service || true)
    timesyncd_disabled=0
    case "$current_time_service" in
        chrony|chronyd) SUMMARY_CHRONY_STATUS="Already active"; return 0 ;;
        ntp|ntpd|ntpsec|openntpd) SUMMARY_CHRONY_STATUS="Conflict: $current_time_service"; return 1 ;;
        systemd-timesyncd)
            prompt_yes_no "Replace systemd-timesyncd with chrony?" || { SUMMARY_CHRONY_STATUS="Kept systemd-timesyncd"; return 0; }
            systemctl disable --now systemd-timesyncd || return 1
            timesyncd_disabled=1 ;;
    esac
    if [ "$OS" = "alpine" ]; then apk add --no-cache chrony && rc-update add chronyd default && rc-service chronyd start || { chrony_rollback; return 1; }; chrony_service=chronyd
    else apt-get install -y chrony && systemctl enable --now chrony || { chrony_rollback; return 1; }; chrony_service=chrony
    fi
    svc_is_active "$chrony_service" || { chrony_rollback; SUMMARY_CHRONY_STATUS="Chrony failed"; return 1; }
    SUMMARY_CHRONY_STATUS="Enabled; sync pending or complete"
}

configure_zram() {
    print_step "Configure ZRAM"
    if is_container || { [ -r /sys/module/zswap/parameters/enabled ] && [ "$(cat /sys/module/zswap/parameters/enabled)" = Y ]; } || ! zram_capable; then
        SUMMARY_ZRAM_STATUS="Skipped: conflicting or unsupported environment"
        return 0
    fi
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
        [ -f "$zram_config" ] && ! managed_zram_config "$zram_config" && { SUMMARY_ZRAM_STATUS="Skipped: unmanaged ZRAM configuration"; return 0; }
        zram_active && [ ! -f "$zram_config" ] && { SUMMARY_ZRAM_STATUS="Skipped: unmanaged ZRAM active"; return 0; }
        zram_active && ! swapoff_has_headroom "$(awk 'NR>1 && $1 ~ /zram/ {sum += $4} END {printf "%d\n", sum}' /proc/swaps)" && { SUMMARY_ZRAM_STATUS="Skipped: insufficient memory to resize ZRAM"; return 1; }
        zram_backup=""; [ "$zram_had_config" -eq 0 ] || { zram_backup="${zram_config}.bak_$(date +%s)"; cp -a "$zram_config" "$zram_backup" || return 1; }
        printf '# Managed by linvpsliteinit.\nload_on_start=yes\nunload_on_stop=yes\nnum_devices=1\ntype0=swap\nflag0=100\nsize0=%s\nlabl0=zram_swap\n' "$zram_size_mb" > "$zram_config" || { restore_previous_zram; return 1; }
        apk add --no-cache zram-init || { restore_previous_zram; return 1; }
        rc-update add zram-init default && rc-service zram-init restart || { restore_previous_zram; return 1; }; zram_service=zram-init
    else
        zram_config=/etc/default/zramswap
        zram_was_enabled=0; systemctl is-enabled --quiet zramswap 2>/dev/null && zram_was_enabled=1
        zram_was_active=0; svc_is_active zramswap && zram_was_active=1
        zram_had_config=0; [ -f "$zram_config" ] && zram_had_config=1
        [ -f "$zram_config" ] && ! managed_zram_config "$zram_config" && { SUMMARY_ZRAM_STATUS="Skipped: unmanaged ZRAM configuration"; return 0; }
        zram_active && [ ! -f "$zram_config" ] && { SUMMARY_ZRAM_STATUS="Skipped: unmanaged ZRAM active"; return 0; }
        zram_active && ! swapoff_has_headroom "$(awk 'NR>1 && $1 ~ /zram/ {sum += $4} END {printf "%d\n", sum}' /proc/swaps)" && { SUMMARY_ZRAM_STATUS="Skipped: insufficient memory to resize ZRAM"; return 1; }
        zram_backup=""; [ "$zram_had_config" -eq 0 ] || { zram_backup="${zram_config}.bak_$(date +%s)"; cp -a "$zram_config" "$zram_backup" || return 1; }
        printf '# Managed by linvpsliteinit.\nSIZE=%s\nPRIORITY=100\n' "$zram_size_mb" > "$zram_config" || { restore_previous_zram; return 1; }
        apt-get install -y zram-tools || { restore_previous_zram; return 1; }
        zram_service=zramswap
        systemctl enable "$zram_service" && systemctl restart "$zram_service" || { restore_previous_zram; return 1; }
    fi
    if svc_is_active "$zram_service" && zram_active; then SUMMARY_ZRAM_STATUS="Enabled: ${zram_size_mb}MiB"; else restore_previous_zram; SUMMARY_ZRAM_STATUS="ZRAM failed"; return 1; fi
}

configure_swap() {
    print_step "Configure SWAP File"

    # NOTE: BUG in original - the `swapoff/sed/rm` cleanup block for 1024-2048MB
    # range was INSIDE the if-elif chain but NOT inside a branch body (missing `fi`
    # placement caused it to run unconditionally for that range). Fixed below by
    # separating cleanup logic from recommendation logic.

    local mem_size_mb
    mem_size_mb=$(normalize_ram_mib "$(awk '/^MemTotal:/{print $2}' /proc/meminfo)")
    local current_swap_mb
    current_swap_mb=$(active_disk_swap_mib)
    local swap_file_path="/swapfile_by_script"

    recommended_swap_mb=$(recommend_disk_swap_mib "$mem_size_mb")

    printf "Memory: %sMiB, ZRAM: %sMiB, disk SWAP: %sMiB\n" "$mem_size_mb" "$(active_zram_swap_mib)" "$current_swap_mb"
    [ "$mem_size_mb" -gt 65536 ] && printf "${YELLOW}For RAM above 64GiB, 4096MiB is only a baseline; size by workload.${NC}\n"
    printf "Recommended disk SWAP is %sMiB. Enter desired size or press Enter: " "$recommended_swap_mb"
    read -r user_target_mb
    target_swap_mb="${user_target_mb:-$recommended_swap_mb}"

    # Validate input
    case "$target_swap_mb" in
        ''|*[!0-9]*)
            printf "${RED}Invalid input. Skipping SWAP.${NC}\n"; return ;;
    esac

    if [ "$target_swap_mb" -le "$current_swap_mb" ]; then
        printf "${GREEN}Current SWAP is sufficient.${NC}\n"
        SUMMARY_SWAP_STATUS="Sufficient, total: $(free -h | awk '/^Swap:/{print $2}')"
        return
    fi

    # Never resize a live swap file in place; preserve existing workload state.
    if [ -f "$swap_file_path" ]; then
        SUMMARY_SWAP_STATUS="Existing managed swap preserved"
        printf "${YELLOW}Existing managed swap file found; leaving it unchanged.${NC}\n"
        return 0
    fi
    fstab_backup="/etc/fstab.bak_$(date +%s)"
    cp -a /etc/fstab "$fstab_backup" || return 1

    printf "Creating %sMB swap file...\n" "$target_swap_mb"

    # NOTE: fallocate does not work on all filesystems (e.g. btrfs, some network FS).
    # Try fallocate first, fall back to dd.
    if command -v fallocate > /dev/null 2>&1; then
        printf "Using fallocate...\n"
        if ! fallocate -l "${target_swap_mb}M" "$swap_file_path" 2>/dev/null; then
            printf "${YELLOW}fallocate failed, falling back to dd...${NC}\n"
            dd if=/dev/zero of="$swap_file_path" bs=1M count="$target_swap_mb" status=progress
        fi
    else
        printf "Using dd (may take a moment)...\n"
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
        printf "\nvm.swappiness=10\n" >> /etc/sysctl.conf
        sysctl -p > /dev/null
    fi

    SUMMARY_SWAP_STATUS="Configured, total: $(free -h | awk '/^Swap:/{print $2}')"
    printf "${GREEN}SWAP configured successfully.${NC}\n"
    free -h
}

setup_security_tools() {
    print_step "Configure Firewall & Intrusion Prevention"

    if [ "$OS" = "alpine" ]; then
        # Alpine: use iptables
        setup_security_alpine
    else
        # Debian/Ubuntu: use UFW + Fail2ban
        setup_security_debian
    fi
}

setup_security_alpine() {
    printf "${BLUE}Alpine: configuring iptables${NC}\n"
    apk add --no-cache iptables ip6tables

    # Flush and set defaults
    iptables -F; iptables -X
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p tcp --dport "$SUMMARY_SSH_PORT" -j ACCEPT

    # Persist rules across reboots
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    # NOTE: Alpine has no iptables-persistent package; use local.d instead.
    mkdir -p /etc/local.d
    cat > /etc/local.d/iptables.start << 'IEOF'
#!/bin/sh
iptables-restore < /etc/iptables/rules.v4
IEOF
    chmod +x /etc/local.d/iptables.start
    rc-update add local default 2>/dev/null || true

    SUMMARY_FIREWALL_STATUS="iptables (Alpine)"
    SUMMARY_FIREWALL_PORTS="$SUMMARY_SSH_PORT"
    printf "${GREEN}iptables configured. SSH port %s open.${NC}\n" "$SUMMARY_SSH_PORT"
    printf "${YELLOW}To open additional ports later:${NC}\n"
    printf "  iptables -A INPUT -p tcp --dport PORT -j ACCEPT\n"
    printf "  iptables-save > /etc/iptables/rules.v4\n"

    # NOTE: fail2ban is available on Alpine but requires extra config.
    # Skipping for now as sshd brute-force protection is partially handled by
    # iptables default DROP + key-only auth.
    SUMMARY_FAIL2BAN_STATUS="Not applicable (Alpine, key-only SSH)"
}

setup_security_debian() {
    apt-get install -y ufw
    ufw allow "$SUMMARY_SSH_PORT/tcp"
    ufw --force enable
    SUMMARY_FIREWALL_STATUS="UFW Enabled"
    SUMMARY_FIREWALL_PORTS="$SUMMARY_SSH_PORT"
    printf "${GREEN}UFW enabled for port %s.${NC}\n" "$SUMMARY_SSH_PORT"

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
        sleep 3
        if systemctl is-active --quiet fail2ban; then
            SUMMARY_FAIL2BAN_STATUS="Enabled (monitoring SSH)"
            printf "${GREEN}Fail2ban started successfully.${NC}\n"
        else
            SUMMARY_FAIL2BAN_STATUS="FAILED to start"
            printf "${RED}Fail2ban failed to start! Check logs.${NC}\n"
        fi
    fi
}

enable_bbr() {
    print_step "Enable BBR"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        printf "${YELLOW}BBR already enabled.${NC}\n"
        SUMMARY_BBR_STATUS="Already enabled"
        return
    fi

    # NOTE: modprobe is a no-op on many VPS kernels where BBR is built-in.
    # Ignore failure gracefully.
    modprobe tcp_bbr 2>/dev/null || true

    # NOTE: net.core.default_qdisc may report "unknown key" on some Alpine/older
    # kernels. Write both anyway; sysctl will skip unknown keys with --ignore.
    if [ "$OS" = "alpine" ]; then
        # Alpine: write to sysctl.conf directly
        grep -q "tcp_congestion_control" /etc/sysctl.conf || \
            printf "net.ipv4.tcp_congestion_control=bbr\n" >> /etc/sysctl.conf
        sysctl -q -e -p /etc/sysctl.conf 2>/dev/null || true
    else
        printf "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" \
            > /etc/sysctl.d/99-bbr.conf
        sysctl --system > /dev/null
    fi

    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        SUMMARY_BBR_STATUS="Enabled"
        printf "${GREEN}BBR enabled.${NC}\n"
    else
        SUMMARY_BBR_STATUS="Failed (kernel may not support BBR)"
        printf "${YELLOW}BBR could not be confirmed. Kernel may not support it.${NC}\n"
    fi
}

set_hostname_timezone() {
    print_step "Set Hostname & Timezone"

    if prompt_yes_no "Set a new hostname?"; then
        printf "Enter hostname: "
        read -r h
        if [ -n "$h" ]; then
            if [ "$OS" = "alpine" ]; then
                # NOTE: On some NAT VPS the host injects the hostname at boot,
                # overriding /etc/hostname. Use local.d as a workaround.
                printf "%s\n" "$h" > /etc/hostname
                printf "hostname=\"%s\"\n" "$h" > /etc/conf.d/hostname
                hostname "$h"
                # Ensure local.d override exists for NAT VPS that inject hostname
                mkdir -p /etc/local.d
                printf '#!/bin/sh\nhostname %s\n' "$h" > /etc/local.d/hostname.start
                chmod +x /etc/local.d/hostname.start
                rc-update add local default 2>/dev/null || true
            else
                hostnamectl set-hostname "$h"
                printf "%s\n" "$h" > /etc/hostname
                hostname "$h"
                # Update /etc/hosts
                if grep -qE "^127\.0\.1\.1[[:space:]]" /etc/hosts; then
                    sed -i "s|^\(127\.0\.1\.1[[:space:]]\+\).*|\1$h|" /etc/hosts
                else
                    printf "127.0.1.1\t%s\n" "$h" >> /etc/hosts
                fi
            fi
            SUMMARY_HOSTNAME="$h"
            printf "Hostname set to %s\n" "$h"
        fi
    fi

    if prompt_yes_no "Set timezone?"; then
        printf "Enter UTC offset (+8, -5) [+9]: "
        read -r o
        o="${o:-+9}"
        sign="${o%${o#?}}"   # first character
        hrs="${o#?}"         # rest

        if [ "$sign" = "+" ]; then
            tz="Etc/GMT-${hrs}"
        else
            tz="Etc/GMT+${hrs}"
        fi

        if [ "$OS" = "alpine" ]; then
            # NOTE: Alpine uses /etc/timezone + ln -sf; no timedatectl by default.
            apk add --no-cache tzdata 2>/dev/null || true
            cp "/usr/share/zoneinfo/${tz}" /etc/localtime 2>/dev/null && \
                printf "%s\n" "$tz" > /etc/timezone
            printf "Timezone set to %s (UTC%s)\n" "$tz" "$o"
            SUMMARY_TIMEZONE="${tz} (UTC${o})"
        else
            if timedatectl set-timezone "$tz"; then
                SUMMARY_TIMEZONE="${tz} (UTC${o})"
                printf "Timezone set to %s\n" "$SUMMARY_TIMEZONE"
            fi
        fi
    fi
}

install_docker() {
    print_step "Install Docker"
    if command -v docker > /dev/null 2>&1; then
        printf "${YELLOW}Docker already installed.${NC}\n"
        SUMMARY_DOCKER_STATUS="Already installed"
        return
    fi

    if [ "$OS" = "alpine" ]; then
        # NOTE: Alpine uses its own docker package, not Docker's upstream repo.
        apk add --no-cache docker docker-cli-compose
        rc-update add docker default
        rc-service docker start
        SUMMARY_DOCKER_STATUS="Installed (Alpine package)"
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
        SUMMARY_DOCKER_STATUS="Installed"
        printf "${GREEN}Docker installed.${NC}\n"
    fi
}

install_tmux() {
    print_step "Install tmux"
    if command -v tmux > /dev/null 2>&1; then
        printf "${YELLOW}tmux already installed.${NC}\n"
        SUMMARY_TMUX_STATUS="Already installed"
        return
    fi

    pkg_install tmux

    if command -v tmux > /dev/null 2>&1; then
        if [ "$OS" = "alpine" ]; then
            SUMMARY_TMUX_STATUS="Installed (Alpine package)"
        else
            SUMMARY_TMUX_STATUS="Installed"
        fi
        printf "${GREEN}tmux installed.${NC}\n"
    else
        SUMMARY_TMUX_STATUS="FAILED to install"
        printf "${RED}tmux installation failed.${NC}\n"
    fi
}

install_mosh() {
    print_step "Install Mosh"

    if command -v mosh-server > /dev/null 2>&1; then
        printf "${YELLOW}mosh already installed. Continuing with firewall configuration.${NC}\n"
    else
        pkg_install mosh
        if ! command -v mosh-server > /dev/null 2>&1; then
            SUMMARY_MOSH_STATUS="FAILED to install"
            printf "${RED}mosh installation failed.${NC}\n"
            return
        fi
        printf "${GREEN}mosh installed.${NC}\n"
    fi

    ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    ssh_port="${ssh_port:-22}"
    printf "mosh still uses SSH for login. Detected SSH port: %s\n" "$ssh_port"

    printf "Enter mosh UDP start port [60000]: "
    read -r mosh_start_port
    mosh_start_port="${mosh_start_port:-60000}"
    printf "Enter mosh UDP end port [61000]: "
    read -r mosh_end_port
    mosh_end_port="${mosh_end_port:-61000}"

    case "$mosh_start_port:$mosh_end_port" in
        *[!0-9:]*|:|*::*) printf "${RED}Invalid mosh port range.${NC}\n"; SUMMARY_MOSH_STATUS="Invalid port range"; return ;;
    esac

    if [ "$mosh_start_port" -lt 1 ] || [ "$mosh_start_port" -gt 65535 ] || \
       [ "$mosh_end_port" -lt 1 ] || [ "$mosh_end_port" -gt 65535 ] || \
       [ "$mosh_start_port" -gt "$mosh_end_port" ]; then
        printf "${RED}mosh port range must be 1-65535 and start <= end.${NC}\n"
        SUMMARY_MOSH_STATUS="Invalid port range"
        return
    fi

    mosh_range="${mosh_start_port}:${mosh_end_port}"
    firewall_note="No firewall changes"

    if [ "$OS" = "alpine" ]; then
        if command -v iptables > /dev/null 2>&1 && iptables -L INPUT > /dev/null 2>&1; then
            iptables -C INPUT -p udp --dport "$mosh_range" -j ACCEPT 2>/dev/null || \
                iptables -A INPUT -p udp --dport "$mosh_range" -j ACCEPT
            iptables-save > /etc/iptables/rules.v4
            firewall_note="iptables opened UDP ${mosh_start_port}-${mosh_end_port}"
            if [ "$SUMMARY_FIREWALL_PORTS" != "N/A" ]; then
                SUMMARY_FIREWALL_PORTS="${SUMMARY_FIREWALL_PORTS}, UDP ${mosh_start_port}-${mosh_end_port} (mosh)"
            fi
        fi
        SUMMARY_MOSH_STATUS="Installed (UDP ${mosh_start_port}-${mosh_end_port})"
    else
        if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
            ufw allow "${mosh_start_port}:${mosh_end_port}/udp"
            firewall_note="UFW opened UDP ${mosh_start_port}-${mosh_end_port}"
            if [ "$SUMMARY_FIREWALL_PORTS" != "N/A" ]; then
                SUMMARY_FIREWALL_PORTS="${SUMMARY_FIREWALL_PORTS}, UDP ${mosh_start_port}-${mosh_end_port} (mosh)"
            fi
        fi
        SUMMARY_MOSH_STATUS="Installed (UDP ${mosh_start_port}-${mosh_end_port})"
    fi

    printf "${GREEN}mosh ready.${NC} %s\n" "$firewall_note"
}

install_frp() {
    print_step "Install FRPS"

    # Check if already installed
    if [ "$OS" = "alpine" ]; then
        already_check="/etc/init.d/frps"
    else
        already_check="/etc/systemd/system/frps.service"
    fi
    if [ -f "$already_check" ]; then
        printf "${YELLOW}FRPS already installed.${NC}\n"
        SUMMARY_FRP_STATUS="Already installed"
        return
    fi

    printf "Enter frps bind port [7000]: "; read -r bind_port;     bind_port="${bind_port:-7000}"
    printf "Enter frps dashboard port [7500]: "; read -r dash_port; dash_port="${dash_port:-7500}"
    printf "Enter dashboard username [admin]: "; read -r dash_user; dash_user="${dash_user:-admin}"
    printf "Enter dashboard password [admin123]: "; read -r dash_pass; dash_pass="${dash_pass:-admin123}"

    default_token=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
    printf "Enter authentication token [%s]: " "$default_token"; read -r auth_token
    auth_token="${auth_token:-$default_token}"

    # NOTE: grep -Po is a bashism (PCRE). Replaced with grep -o + sed for POSIX.
    latest_version=$(curl -s "https://api.github.com/repos/fatedier/frp/releases/latest" \
        | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    if [ -z "$latest_version" ]; then
        printf "${RED}Could not fetch frp version. Check network.${NC}\n"
        return 1
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
        # Alpine: OpenRC service
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

        # Open firewall port if iptables is active
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

        if command -v ufw > /dev/null 2>&1 && [ "$SUMMARY_FIREWALL_STATUS" = "UFW Enabled" ]; then
            ufw allow "${bind_port}/tcp"
            SUMMARY_FIREWALL_PORTS="${SUMMARY_FIREWALL_PORTS}, ${bind_port}"
        fi
    fi

    sleep 2
    if svc_is_active frps; then
        SUMMARY_FRP_STATUS="Installed (v${vclean}, Port: ${bind_port})"
        printf "${GREEN}frps %s installed and started.${NC}\n" "$vclean"
    else
        SUMMARY_FRP_STATUS="FAILED to start"
        printf "${RED}frps failed to start! Check %s/frps.log${NC}\n" "$dir"
    fi
}

display_summary() {
    print_step "Final Summary"
    printf -- "------------ System Initialization Complete ------------\n"
    printf "  Hostname:\t\t%s\n"             "$SUMMARY_HOSTNAME"
    printf "  Timezone:\t\t%s\n"             "$SUMMARY_TIMEZONE"
    printf "  SSH Port:\t\t${GREEN}%s (Verified)${NC}\n" "$SUMMARY_SSH_PORT"
    printf "  SWAP Status:\t\t%s\n"          "$SUMMARY_SWAP_STATUS"
    printf "  ZRAM Status:\t\t%s\n"          "$SUMMARY_ZRAM_STATUS"
    printf "  Chrony:\t\t%s\n"              "$SUMMARY_CHRONY_STATUS"
    printf "  Firewall:\t\t%s (Open: %s)\n" "$SUMMARY_FIREWALL_STATUS" "$SUMMARY_FIREWALL_PORTS"
    printf "  Fail2Ban:\t\t%s\n"             "$SUMMARY_FAIL2BAN_STATUS"
    printf "  BBR:\t\t\t%s\n"               "$SUMMARY_BBR_STATUS"
    printf "  Docker:\t\t%s\n"              "$SUMMARY_DOCKER_STATUS"
    printf "  tmux:\t\t\t%s\n"              "$SUMMARY_TMUX_STATUS"
    printf "  mosh:\t\t\t%s\n"              "$SUMMARY_MOSH_STATUS"
    printf "  FRPS:\t\t\t%s\n"              "$SUMMARY_FRP_STATUS"
    printf "  OS:\t\t\t%s\n"               "$OS"
    printf "  Log:\t\t\t%s\n"              "$LOG_FILE"
    printf -- "----------------------------------------------------\n"
    printf "\n${RED}IMPORTANT: Use SSH port ${GREEN}%s${NC}${RED} with your saved private key to reconnect.${NC}\n" \
        "$SUMMARY_SSH_PORT"
    printf "${BLUE}TIP:${NC} For proxy, FRP, relay, or other high-concurrency workloads,\n"
    printf "     run ${YELLOW}./add_components.sh${NC} and choose ${YELLOW}Advanced Network Tuning${NC}.\n"
    if [ "$SUMMARY_FIREWALL_STATUS" = "Skipped" ]; then
        printf "${YELLOW}WARNING: Firewall was skipped. Configure it immediately.${NC}\n"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    check_root
    detect_os

    case "${1:-}" in
        --remove-managed-swap) remove_managed_swap; return ;;
        --remove-managed-zram) remove_managed_zram; return ;;
        --help) printf 'Usage: %s [--remove-managed-swap|--remove-managed-zram]\n' "$0"; return ;;
        '') ;;
        *) printf "${RED}Unknown option: %s${NC}\n" "$1"; return 2 ;;
    esac

    change_password
    configure_ssh
    update_and_install_tools

    if prompt_yes_no "Install and enable Chrony?"; then install_chrony; else SUMMARY_CHRONY_STATUS="Skipped by user"; fi

    if prompt_yes_no "Configure SWAP?"; then
        configure_swap
    else
        SUMMARY_SWAP_STATUS="Skipped by user"
    fi

    if prompt_yes_no "Configure ZRAM?"; then configure_zram; else SUMMARY_ZRAM_STATUS="Skipped by user"; fi

    if prompt_yes_no "Configure Firewall?"; then
        setup_security_tools
    fi

    if prompt_yes_no "Enable BBR?"; then
        enable_bbr
    else
        SUMMARY_BBR_STATUS="Skipped by user"
    fi

    set_hostname_timezone

    if prompt_yes_no "Install Docker?"; then
        install_docker
    else
        SUMMARY_DOCKER_STATUS="Skipped by user"
    fi

    if prompt_yes_no "Install tmux?"; then
        install_tmux
    else
        SUMMARY_TMUX_STATUS="Skipped by user"
    fi

    if prompt_yes_no "Install Mosh?"; then
        install_mosh
    else
        SUMMARY_MOSH_STATUS="Skipped by user"
    fi

    if prompt_yes_no "Install FRPS?"; then
        install_frp
    else
        SUMMARY_FRP_STATUS="Skipped by user"
    fi

    display_summary
}

main "$@"

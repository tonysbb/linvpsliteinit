# Audit Quick Reference Guide

This is a condensed reference for developers addressing the audit findings.

## 🔴 Critical Fixes Required (DO NOT DEPLOY WITHOUT THESE)

### 1. Fix Misplaced Code (Lines 84-90)
**Current:** Lines 84-90 are inside the `if/elif` chain that sets `recommended_swap_mb`  
**Fix:** Move these 7 lines to **after line 99** (after the `fi` that closes the if/elif chain)

```bash
# Current location (WRONG):
77:     if (( mem_size_mb < 512 )); then
...
82:         recommended_swap_mb=2048
83: 
84:     # Fix: Prevent duplicate SWAP mount   <-- THIS IS IN THE WRONG PLACE
85:     swapoff -a 2>/dev/null || true        <-- THESE LINES
...                                            <-- NEED TO MOVE
90:     sed -ri '/swapfile_by_script/! ...    <-- DOWN
91:     elif (( mem_size_mb < 4096 )); then   <-- THIS elif IS UNREACHABLE
```

**Correct location:**
```bash
98:         recommended_swap_mb=8192
99:     fi
100:                                           <-- INSERT LINES 84-90 HERE
101:     echo "Memory: ${mem_size_mb}MB..."
```

### 2. Stop Logging Private SSH Key
**Line 56** displays the private key which gets logged to file via **line 18**.

**Option A - Disable logging temporarily:**
```bash
# Before line 56, add:
exec &>/dev/tty  # Redirect to terminal only

# After line 58 (after rm -f ~/.ssh/id_ed25519), add:
exec &> >(tee -a "$LOG_FILE")  # Resume logging
```

**Option B - Don't display key (better):**
Remove lines 55-58 entirely and document alternative secure key retrieval method.

### 3. Fix SSH Port Documentation
**Line 48** - Choose one approach:

**Option A - Match documentation to code:**
```bash
read -p "Enter a new SSH port (1025-65535, recommended >10000): " new_ssh_port
```

**Option B - Match code to documentation:**
```bash
if [[ "$new_ssh_port" =~ ^[0-9]+$ ]] && [ "$new_ssh_port" -ge 10000 ] && [ "$new_ssh_port" -le 65535 ]; then
```

## 🟠 High Priority Fixes (Production Hardening)

### Add Shell Options (Line 16)
```bash
set -euo pipefail  # Instead of just: set -e
```

### Validate passwd Command (Line 41)
```bash
if ! passwd; then
    echo -e "${RED}Password change failed or cancelled.${NC}"
    exit 1
fi
```

### Verify SSH Restart (After line 60)
```bash
if ! systemctl restart sshd; then
    echo -e "${RED}FATAL: SSH failed to restart!${NC}"
    systemctl status sshd
    exit 1
fi
```

### Fix Infinite Loop (Line 57)
```bash
while true; do
    read -r -p "Have you saved the private key? (yes/no): " c
    case "${c,,}" in
        yes|y) break ;;
        no|n) echo "Please save the key." ;;
        *) echo "Please answer yes or no." ;;
    esac
done
```

### Add SWAP Size Bounds (After line 104)
```bash
# Validate range
if [ "$target_swap_mb" -lt 128 ] || [ "$target_swap_mb" -gt 65536 ]; then
    echo -e "${RED}SWAP must be 128-65536 MB.${NC}"
    return 1
fi

# Check disk space
local available_mb=$(df /root | awk 'NR==2 {print int($4/1024)}')
if [ "$target_swap_mb" -gt "$available_mb" ]; then
    echo -e "${RED}Insufficient disk space. Available: ${available_mb}MB${NC}"
    return 1
fi
```

### Validate Hostname (After line 218)
```bash
read -r -p "Enter hostname: " h
if [ -n "$h" ]; then
    if ! [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        echo -e "${RED}Invalid hostname format.${NC}"
        return 1
    fi
    if [ ${#h} -gt 253 ]; then
        echo -e "${RED}Hostname too long (max 253).${NC}"
        return 1
    fi
    # ... proceed with hostnamectl
fi
```

### Extract SWAP Cleanup to Function
```bash
cleanup_swap() {
    local swap_file_path="/swapfile_by_script"
    swapoff -a 2>/dev/null || true
    sed -i '/swapfile_by_script/d' /etc/fstab
    rm -f "$swap_file_path"
    
    # Single backup
    if [ ! -f "/etc/fstab.bak_vps_init" ]; then
        cp -a /etc/fstab "/etc/fstab.bak_vps_init"
    fi
    
    sed -ri '/swapfile_by_script/! s@^([^#].*\s)swap(\s+.*)$@# \1swap\2@' /etc/fstab
}
```

Call once before creating new swap (around line 100).

### Add Download Verification
For Docker (line 260):
```bash
local expected_fingerprint="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
local temp_key=$(mktemp)
curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" -o "$temp_key"
local actual=$(gpg --with-colons --import-options show-only --import "$temp_key" 2>/dev/null | awk -F: '/^fpr:/ {print $10}')
if [ "$actual" != "$expected_fingerprint" ]; then
    echo -e "${RED}Docker GPG key verification failed!${NC}"
    rm -f "$temp_key"
    return 1
fi
gpg --dearmor -o /etc/apt/keyrings/docker.gpg < "$temp_key"
rm -f "$temp_key"
```

For FRP (line 311):
```bash
# Download checksums
local checksum_url="${url%.tar.gz}_checksums.txt"
wget -qO /tmp/frp_checksums.txt "$checksum_url"

# Download and verify
wget -qO /tmp/frp.tar.gz "$url"
cd /tmp
if ! sha256sum -c --ignore-missing frp_checksums.txt 2>/dev/null | grep -q "frp_${vclean}_linux_amd64.tar.gz: OK"; then
    echo -e "${RED}FRP checksum verification failed!${NC}"
    rm -f /tmp/frp*
    return 1
fi
cd - >/dev/null
```

### Generate Strong FRP Password (Line 291-292)
```bash
local default_pass=$(tr -dc 'a-zA-Z0-9!@#$%^&*' < /dev/urandom | head -c 20)
read -r -p "Enter dashboard password [random]: " dashboard_pass
dashboard_pass=${dashboard_pass:-$default_pass}
echo -e "${YELLOW}Dashboard password: ${dashboard_pass}${NC}"
```

### Add File Locking
Wrap critical config edits:
```bash
(
    flock -x 200 || { echo "Failed to lock file"; exit 1; }
    # ... edit operations
) 200>/var/lock/vps_init_ssh.lock
```

## 🟡 Medium Priority (Robustness)

- Add `-r` to all `read` commands (prevents backslash interpretation)
- Add timeouts to network operations: `curl --max-time 30`
- Add retries: `wget --tries=3`
- Implement global error trap for cleanup
- Standardize backup file naming (single backup, not timestamped)
- Fix fallocate error check (line 131)
- Validate FRP ports (numeric, 1024-65535)
- Validate timezone offset (-14 to +14)

## 🔵 Low Priority (Polish)

- Extract magic numbers to constants at top
- Add function documentation headers
- Standardize error message format
- Add comprehensive comments
- Improve code formatting (break long lines)

## Quick Test Commands

```bash
# Test on fresh VM
bash vps_init.sh

# Check log doesn't contain private key
grep -i "BEGIN OPENSSH PRIVATE KEY" /root/vps_init_*.log
# Should return nothing!

# Test SWAP recommendations
# With 512MB RAM -> should recommend 1024MB
# With 2GB RAM -> should recommend 3072MB (not 2048MB after fix!)

# Verify SSH configuration
sshd -T | grep -E "port|permitrootlogin|passwordauth|pubkeyauth"
```

## Files Modified Summary

- **vps_init.sh** - All changes in this file
- **No other files need modification** (audit is documentation-only)

## Estimated Time to Fix

- **Critical issues:** 2-3 hours
- **High priority:** 4-6 hours  
- **Medium priority:** 3-4 hours
- **Testing:** 4 hours
- **Total:** ~14-18 hours

## Need Help?

Refer to:
- `AUDIT_REPORT.md` - Detailed findings with examples
- `AUDIT_CHECKLIST.md` - Validation checklist
- `AUDIT_SUMMARY.md` - Executive overview

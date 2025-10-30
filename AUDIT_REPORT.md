# VPS Init Script Audit Report

**Script:** `vps_init.sh` (418 lines)  
**Date:** 2024  
**Auditor:** Security & Code Quality Review  

---

## Executive Summary

This audit identifies **2 CRITICAL**, **8 HIGH**, **12 MEDIUM**, and **9 LOW** severity issues across error handling, input validation, resource management, security, concurrency, and code quality domains. The most severe findings include:

1. **CRITICAL**: Private SSH key logged to file and displayed unsecurely (lines 18, 56)
2. **CRITICAL**: Misplaced code block breaks SWAP logic flow (lines 84-90)
3. **HIGH**: No verification of remote download integrity (Docker, FRP)
4. **HIGH**: Insufficient error handling on critical system operations

---

## 1. Error Handling & Exit Safety

### CRITICAL-001: Logic-Breaking Code Placement
**Location:** Lines 84-90  
**Severity:** CRITICAL

**Issue:**  
Code block appears inside the `if/elif` chain (lines 77-99) that calculates `recommended_swap_mb`. This breaks control flow:

```bash
77:     if (( mem_size_mb < 512 )); then
78:         recommended_swap_mb=1024
...
82:         recommended_swap_mb=2048
83: 
84:     # Fix: Prevent duplicate SWAP mount (Debian 11 compatibility)
85:     swapoff -a 2>/dev/null || true
86:     sed -i '/swapfile_by_script/d' /etc/fstab
87:     rm -f "$swap_file_path"
88:     # Fix: avoid duplicate SWAP on reboot...
89:     cp -a /etc/fstab /etc/fstab.bak_$(date +%s)
90:     sed -ri '/swapfile_by_script/! s@^([^#].*\s)swap(\s+.*)$@# \1swap\2@' /etc/fstab
91:     elif (( mem_size_mb < 4096 )); then  # This elif is unreachable!
```

**Impact:**  
- Lines 91-99 become unreachable
- Systems with 2GB-16GB+ RAM always get 2048MB recommendation
- Premature SWAP cleanup executes before user even confirms size
- Potential data corruption from `sed -i` operations on fstab

**Recommendation:**  
Move lines 84-90 to after line 99, before the `echo "Memory: ..."` statement at line 101.

---

### HIGH-001: Missing `set -u` and `set -o pipefail`
**Location:** Line 16  
**Severity:** HIGH

**Issue:**  
Script has `set -e` but lacks:
- `set -u`: Allows undefined variables to expand to empty strings silently
- `set -o pipefail`: Pipelines succeed if last command succeeds, even if earlier ones fail

**Example Risk:**  
```bash
# Line 299: If curl fails but grep succeeds with empty input
local latest_version=$(curl -s "..." | grep -Po '...')
# latest_version could be empty, causing issues at line 306
```

**Recommendation:**  
```bash
set -euo pipefail
```

---

### HIGH-002: Unvalidated `passwd` Command Success
**Location:** Lines 38-43  
**Severity:** HIGH

**Issue:**  
`passwd` command (line 41) can fail if:
- User cancels (Ctrl+C)
- Passwords don't match
- Password doesn't meet complexity requirements
- PAM module errors

Script continues regardless, falsely reporting "Password changed successfully" (line 42).

**Recommendation:**  
```bash
if ! passwd; then
    echo -e "${RED}Password change failed or cancelled.${NC}"
    exit 1
fi
```

---

### HIGH-003: SSH Restart Without Immediate Verification
**Location:** Lines 60-66  
**Severity:** HIGH

**Issue:**  
`systemctl restart sshd` (line 60) returns immediately but SSH may take time to bind to new port or could fail to start. The 2-second sleep (line 62) is arbitrary. If SSH fails, user is locked out.

**Existing Mitigation:**  
Lines 63-65 perform post-verification with `sshd -T`, which is good.

**Issue:**  
No check of `systemctl restart` exit code. If it fails immediately, the script continues to sleep and then checks config parse (not runtime status).

**Recommendation:**  
```bash
if ! systemctl restart sshd; then
    echo -e "${RED}FATAL: SSH service failed to restart!${NC}"
    systemctl status sshd
    exit 1
fi
```

---

### MEDIUM-001: Fragile `$?` Check with `set -e`
**Location:** Lines 131-134  
**Severity:** MEDIUM

**Issue:**  
```bash
fallocate -l ${target_swap_mb}M "$swap_file_path"
if [ $? -ne 0 ]; then
```

With `set -e`, if `fallocate` fails, script exits before reaching the `if` check. The check is unreachable.

**Recommendation:**  
```bash
if ! fallocate -l ${target_swap_mb}M "$swap_file_path" 2>/dev/null; then
    echo -e "${YELLOW}fallocate failed, falling back to dd...${NC}"
    dd if=/dev/zero of="$swap_file_path" bs=1M count=${target_swap_mb} status=progress
fi
```

---

### MEDIUM-002: Unverified Critical Service Operations
**Location:** Lines 170, 185, 342  
**Severity:** MEDIUM

**Issue:**  
Service start/restart commands lack immediate error checking:
- Line 170: `ufw --force enable` 
- Line 185: `systemctl restart fail2ban`
- Line 342: `systemctl enable --now frps`

**Existing Mitigation:**  
Fail2ban (lines 187-194) and frps (lines 349-357) have post-verification checks.

**Issue:**  
UFW enable has no verification. If it fails, firewall isn't protecting system but script continues.

**Recommendation:**  
```bash
if ! ufw --force enable; then
    echo -e "${RED}UFW failed to enable!${NC}"
    exit 1
fi
```

---

### MEDIUM-003: Piped Docker GPG Key Installation
**Location:** Line 260  
**Severity:** MEDIUM

**Issue:**  
```bash
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
```

If `curl` fails mid-stream, `gpg` might process partial data and create corrupted keyring. The `-f` flag helps but doesn't guarantee atomicity.

**Recommendation:**  
Download to temp file first, verify non-empty, then process:
```bash
local temp_key=$(mktemp)
if ! curl -fsSL "https://..." -o "$temp_key" || [ ! -s "$temp_key" ]; then
    echo -e "${RED}Failed to download Docker GPG key${NC}"
    rm -f "$temp_key"
    return 1
fi
gpg --dearmor -o /etc/apt/keyrings/docker.gpg < "$temp_key"
rm -f "$temp_key"
```

---

### MEDIUM-004: No Global Error Trap/Cleanup
**Location:** Global scope  
**Severity:** MEDIUM

**Issue:**  
If script exits unexpectedly (killed, network error, disk full), system may be left in inconsistent state:
- Partially configured SSH (locked out)
- Incomplete swap configuration
- Half-written config files

**Recommendation:**  
Add trap handler:
```bash
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n${RED}Script failed at line $BASH_LINENO. Check $LOG_FILE${NC}"
        # Potentially restore backups here
    fi
}
trap cleanup EXIT
```

---

### LOW-001: Silenced Errors in SWAP Cleanup
**Location:** Lines 85, 118  
**Severity:** LOW

**Issue:**  
`swapoff -a 2>/dev/null || true` suppresses all errors. While intentional for idempotency, it hides real issues (e.g., busy swap device).

**Recommendation:**  
More selective error handling or at least log suppressed errors to the main log file.

---

## 2. Input Validation & Boundary Checks

### CRITICAL-002: SSH Port Range Mismatch in Documentation
**Location:** Lines 48  
**Severity:** CRITICAL (Documentation/UX)

**Issue:**  
Prompt says "10000-65535" but validation accepts 1025-65535:
```bash
read -p "Enter a new SSH port (10000-65535): " new_ssh_port
if [[ "$new_ssh_port" =~ ^[0-9]+$ ]] && [ "$new_ssh_port" -gt 1024 ] && [ "$new_ssh_port" -lt 65536 ]; then
```

**Impact:**  
User enters 2222, which is accepted but violates their expectation. Well-known ports (1024-9999) are less secure as they're more commonly scanned.

**Recommendation:**  
Match validation to documentation:
```bash
read -p "Enter a new SSH port (1025-65535, recommended >10000): " new_ssh_port
if [[ "$new_ssh_port" =~ ^[0-9]+$ ]] && [ "$new_ssh_port" -ge 1025 ] && [ "$new_ssh_port" -le 65535 ]; then
```

Or enforce 10000-65535 as stated.

---

### HIGH-004: Infinite Loop Risk in SSH Key Confirmation
**Location:** Line 57  
**Severity:** HIGH

**Issue:**  
```bash
while true; do read -p "Have you saved the private key? (yes/no): " c && [[ "$c" == "yes" ]] && break; done
```

User must type exactly "yes" (case-sensitive). Typo or confusion traps them indefinitely. No escape mechanism. Could cause script hang in automated environments.

**Recommendation:**  
```bash
while true; do
    read -p "Have you saved the private key? (yes/no): " c
    case "${c,,}" in  # Convert to lowercase
        yes|y) break ;;
        no|n) echo "Please save the key before proceeding." ;;
        *) echo "Please answer 'yes' or 'no'." ;;
    esac
done
```

---

### HIGH-005: Unbounded SWAP Size Input
**Location:** Lines 103-109  
**Severity:** HIGH

**Issue:**  
User can enter any numeric value for SWAP size. No upper bound check.

**Example:**  
User enters 999999999 MB (~954 TB), script attempts to allocate, causing:
- Disk full
- System crash
- Hours of dd operations

**Recommendation:**  
```bash
local target_swap_mb=${user_target_mb:-$recommended_swap_mb}

if ! [[ "$target_swap_mb" =~ ^[0-9]+$ ]] || [ "$target_swap_mb" -lt 128 ] || [ "$target_swap_mb" -gt 65536 ]; then
    echo -e "${RED}Invalid input. SWAP must be 128-65536 MB.${NC}"
    return 1
fi

# Also check available disk space
local available_mb=$(df /root | awk 'NR==2 {print int($4/1024)}')
if [ "$target_swap_mb" -gt "$available_mb" ]; then
    echo -e "${RED}Insufficient disk space. Available: ${available_mb}MB${NC}"
    return 1
fi
```

---

### HIGH-006: Hostname Input Not Validated
**Location:** Lines 218-231  
**Severity:** HIGH

**Issue:**  
Hostname (`$h`) accepted without validation. User could enter:
- Spaces: `"my server"` 
- Special chars: `"server!@#$%"`
- Over 253 chars
- Starting with hyphen or dot

**Impact:**  
System utilities may fail, DNS issues, systemd errors.

**Recommendation:**  
```bash
read -p "Enter hostname: " h
if [ -n "$h" ]; then
    # Validate hostname format (RFC 1123)
    if ! [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        echo -e "${RED}Invalid hostname format.${NC}"
        return 1
    fi
    if [ ${#h} -gt 253 ]; then
        echo -e "${RED}Hostname too long (max 253 chars).${NC}"
        return 1
    fi
    hostnamectl set-hostname "$h"
    # ... rest of code
fi
```

---

### MEDIUM-005: Fragile Timezone Parsing
**Location:** Lines 234-246  
**Severity:** MEDIUM

**Issue:**  
Timezone logic assumes single-char sign and numeric offset:
```bash
read -p "Enter UTC offset (+8, -5) [+9]: " o
o=${o:-+9}
s=${o:0:1}  # First char
h=${o:1}    # Rest
```

**Problems:**
- If user enters "8" (no sign), `s="8"`, check fails
- If user enters "+08", `h="08"`, creates "Etc/GMT-08" (valid but inconsistent)
- If user enters "UTC+8" or "+8.5", breaks
- No validation that `h` is numeric

**Recommendation:**  
```bash
read -p "Enter UTC offset (+8, -5) [+9]: " o
o=${o:-+9}
# Remove spaces
o="${o// /}"
# Validate format
if ! [[ "$o" =~ ^[+-]?[0-9]+$ ]]; then
    echo -e "${RED}Invalid offset format.${NC}"
    return 1
fi
# Ensure sign prefix
[[ "$o" =~ ^[0-9] ]] && o="+$o"
s=${o:0:1}
h=${o:1}
# Validate range
if [ "$h" -lt 0 ] || [ "$h" -gt 14 ]; then
    echo -e "${RED}UTC offset must be -14 to +14.${NC}"
    return 1
fi
```

---

### MEDIUM-006: FRP Port Inputs Unvalidated
**Location:** Lines 278-292  
**Severity:** MEDIUM

**Issue:**  
FRP bind_port, dashboard_port accept any input, no numeric/range validation:
```bash
read -p "Enter frps bind port [7000]: " bind_port
bind_port=${bind_port:-7000}
# No validation!
```

**Recommendation:**  
```bash
while true; do
    read -p "Enter frps bind port [7000]: " bind_port
    bind_port=${bind_port:-7000}
    if [[ "$bind_port" =~ ^[0-9]+$ ]] && [ "$bind_port" -ge 1024 ] && [ "$bind_port" -le 65535 ]; then
        break
    fi
    echo -e "${RED}Invalid port. Must be 1024-65535.${NC}"
done
```

Same for dashboard_port.

---

### MEDIUM-007: FRP Token Generation Could Fail
**Location:** Line 294  
**Severity:** MEDIUM

**Issue:**  
```bash
local default_token=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
```

Theoretically, if `/dev/urandom` unavailable or `head` killed early, token could be empty or short.

**Recommendation:**  
```bash
local default_token=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32)
if [ ${#default_token} -ne 32 ]; then
    echo -e "${RED}Failed to generate secure token.${NC}"
    return 1
fi
```

---

### LOW-002: prompt_yes_no Default Not Always Clear
**Location:** Line 34  
**Severity:** LOW

**Issue:**  
```bash
read -p "$prompt_text (Y/n): " choice
[[ "${choice:-Y}" =~ ^[Yy]$ ]]
```

Pattern "(Y/n)" suggests default is Yes, which matches implementation. However, in some contexts, skipping security features by default (pressing Enter) may not be ideal.

**Recommendation:**  
Document this behavior clearly in comments. Consider making default configurable per-call for security-critical prompts.

---

### LOW-003: Empty FRP Username/Password Accepted
**Location:** Lines 286-292  
**Severity:** LOW

**Issue:**  
If user presses Enter without input, defaults apply (admin/admin123). But if they enter empty space or special string, it's accepted without validation.

**Recommendation:**  
Validate non-empty after removing whitespace:
```bash
read -p "Enter dashboard username [admin]: " dashboard_user
dashboard_user=$(echo "$dashboard_user" | xargs)  # Trim whitespace
dashboard_user=${dashboard_user:-admin}
```

---

## 3. Resource & State Management

### CRITICAL-003: Private SSH Key Logged to File
**Location:** Lines 18, 56  
**Severity:** CRITICAL

**Issue:**  
Line 18 redirects all output (including stderr) to log file:
```bash
exec &> >(tee -a "$LOG_FILE")
```

Line 56 displays private key:
```bash
cat ~/.ssh/id_ed25519
```

**Impact:**  
Private key is written to `/root/vps_init_TIMESTAMP.log`, which:
- Persists after script ends
- May be backed up to cloud storage
- Accessible to anyone with root access later
- Violates key security best practices

**Recommendation:**  
Critical: Temporarily disable logging for sensitive operations:
```bash
# Before displaying key
exec &>/dev/tty  # Redirect to terminal only
echo -e "\n${YELLOW}!!! IMPORTANT: Copy and save the private key below. !!!${NC}"
cat ~/.ssh/id_ed25519
# After user confirms
exec &> >(tee -a "$LOG_FILE")  # Resume logging
```

Or better: Never display private key - guide user to save it via SCP/SFTP before deleting.

---

### HIGH-007: Duplicate SWAP Configuration Code
**Location:** Lines 84-90 (misplaced) and 117-123  
**Severity:** HIGH

**Issue:**  
Identical cleanup code duplicated:
```bash
# Lines 84-90 (misplaced in if/elif)
swapoff -a 2>/dev/null || true
sed -i '/swapfile_by_script/d' /etc/fstab
rm -f "$swap_file_path"
cp -a /etc/fstab /etc/fstab.bak_$(date +%s)
sed -ri '/swapfile_by_script/! s@^([^#].*\s)swap(\s+.*)$@# \1swap\2@' /etc/fstab

# Lines 117-123 (inside if [ -f "$swap_file_path" ])
swapoff "$swap_file_path" 2>/dev/null || true
rm -f "$swap_file_path"
cp -a /etc/fstab /etc/fstab.bak_$(date +%s)
sed -ri '/swapfile_by_script/! s@^([^#].*\s)swap(\s+.*)$@# \1swap\2@' /etc/fstab
sed -i "\#${swap_file_path}#d" /etc/fstab
```

**Impact:**  
- Code duplication
- Maintenance burden
- Multiple fstab backups created (never cleaned)
- Potential for drift between versions

**Recommendation:**  
Extract to function:
```bash
cleanup_swap() {
    swapoff -a 2>/dev/null || true
    sed -i '/swapfile_by_script/d' /etc/fstab
    rm -f "$swap_file_path"
    
    # Single backup per run
    if [ ! -f "/etc/fstab.bak_vps_init" ]; then
        cp -a /etc/fstab "/etc/fstab.bak_vps_init"
    fi
    
    # Comment out other swap entries
    sed -ri '/swapfile_by_script/! s@^([^#].*\s)swap(\s+.*)$@# \1swap\2@' /etc/fstab
}
```

Call once before creating new swap.

---

### HIGH-008: Unbounded fstab Backup Growth
**Location:** Lines 89, 121  
**Severity:** HIGH

**Issue:**  
Each run creates new backup:
```bash
cp -a /etc/fstab /etc/fstab.bak_$(date +%s)
```

**Impact:**  
- Multiple runs = multiple backups accumulating in `/etc/`
- Clutter
- Confusion about which backup to restore
- Never cleaned up

**Recommendation:**  
Use consistent backup name:
```bash
# Create backup only if it doesn't exist (first run)
if [ ! -f /etc/fstab.bak_vps_init ]; then
    cp -a /etc/fstab /etc/fstab.bak_vps_init
    echo "Original fstab backed up to /etc/fstab.bak_vps_init"
fi
```

Or implement rotation (keep last 3).

---

### MEDIUM-008: SSH Backup File Never Removed
**Location:** Line 59  
**Severity:** MEDIUM

**Issue:**  
```bash
sed -i.bak ...
```
Creates `/etc/ssh/sshd_config.bak` but never cleans it up.

**Recommendation:**  
Either:
1. Document that backup is intentional for recovery
2. Remove after verification: `rm -f /etc/ssh/sshd_config.bak`
3. Use consistent naming like other backups

---

### MEDIUM-009: Log File Descriptor Leak Risk
**Location:** Line 18  
**Severity:** MEDIUM

**Issue:**  
```bash
exec &> >(tee -a "$LOG_FILE")
```

Process substitution creates subshell with `tee`. If script exits abnormally, `tee` process may persist.

**Recommendation:**  
Add cleanup trap:
```bash
TEE_PID=""
exec &> >(tee -a "$LOG_FILE" & TEE_PID=$!)
trap 'kill $TEE_PID 2>/dev/null' EXIT
```

**Note:** This is low-probability issue as shell cleanup usually handles it.

---

### MEDIUM-010: Temporary FRP Archive Not Always Cleaned
**Location:** Line 312  
**Severity:** MEDIUM

**Issue:**  
```bash
wget -qO /tmp/frp.tar.gz "$url" && tar -zxf /tmp/frp.tar.gz -C "$dir" --strip-components=1
rm /tmp/frp.tar.gz
```

If `tar` fails, `rm` doesn't execute due to `set -e`, leaving ~20MB file in `/tmp`.

**Recommendation:**  
```bash
wget -qO /tmp/frp.tar.gz "$url"
tar -zxf /tmp/frp.tar.gz -C "$dir" --strip-components=1
rm -f /tmp/frp.tar.gz  # Always cleanup
```

Or use trap:
```bash
trap 'rm -f /tmp/frp.tar.gz' EXIT RETURN
```

---

### LOW-004: Hardcoded SWAP Path
**Location:** Line 73  
**Severity:** LOW

**Issue:**  
`swap_file_path="/swapfile_by_script"` hardcoded. If root filesystem is small, swap could fail. No option to specify different partition.

**Recommendation:**  
Allow configuration via variable at top of script or detect largest filesystem.

---

### LOW-005: sysctl.conf Duplicate Check Fragile
**Location:** Lines 148-150  
**Severity:** LOW

**Issue:**  
```bash
if ! grep -q "^vm.swappiness=10" /etc/sysctl.conf; then
    echo -e "\nvm.swappiness=10" >> /etc/sysctl.conf
```

Exact match required. If line exists with different spacing (`vm.swappiness = 10` or `vm.swappiness=10 # comment`), duplicate added.

**Recommendation:**  
```bash
if ! grep -qE '^\s*vm\.swappiness\s*=' /etc/sysctl.conf; then
    echo "vm.swappiness=10" >> /etc/sysctl.conf
else
    sed -ri 's/^\s*vm\.swappiness\s*=.*/vm.swappiness=10/' /etc/sysctl.conf
fi
```

---

## 4. Security Posture

### CRITICAL (See CRITICAL-003 above): Private Key Logging

---

### HIGH-009: No Integrity Verification for Docker Installation
**Location:** Lines 260-265  
**Severity:** HIGH

**Issue:**  
Downloads Docker GPG key and packages without checksum/signature verification beyond HTTPS:
```bash
curl -fsSL https://download.docker.com/linux/.../gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
```

**Risk:**  
- Compromised Docker CDN
- MITM attacks (cert pinning not enforced)
- Arbitrary code execution via malicious packages

**Existing Mitigation:**  
- Uses HTTPS (partial protection)
- Uses official Docker GPG key for package verification

**Recommendation:**  
Add key fingerprint verification:
```bash
local expected_fingerprint="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
local temp_key=$(mktemp)
curl -fsSL "https://..." -o "$temp_key"

# Import and verify fingerprint
local actual_fingerprint=$(gpg --with-colons --import-options show-only --import "$temp_key" 2>/dev/null | awk -F: '/^fpr:/ {print $10}')
if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
    echo -e "${RED}Docker GPG key fingerprint mismatch!${NC}"
    rm -f "$temp_key"
    return 1
fi
```

---

### HIGH-010: No Integrity Verification for FRP Download
**Location:** Lines 299-312  
**Severity:** HIGH

**Issue:**  
Downloads FRP binary from GitHub without checksum verification:
```bash
wget -qO /tmp/frp.tar.gz "$url"
```

**Risk:**  
- Compromised GitHub account
- MITM during download
- Arbitrary code execution as root

**Recommendation:**  
Download and verify checksum file:
```bash
local checksum_url="${url%.tar.gz}_checksums.txt"
wget -qO /tmp/frp_checksums.txt "$checksum_url"

# Verify checksum exists for our file
if ! grep -q "frp_${vclean}_linux_amd64.tar.gz" /tmp/frp_checksums.txt; then
    echo -e "${RED}Checksum file missing for our architecture${NC}"
    return 1
fi

# Download and verify
wget -qO /tmp/frp.tar.gz "$url"
cd /tmp
if ! sha256sum -c --ignore-missing frp_checksums.txt 2>/dev/null; then
    echo -e "${RED}FRP checksum verification failed!${NC}"
    rm -f /tmp/frp*
    return 1
fi
```

---

### HIGH-011: Default FRP Credentials Insecure
**Location:** Lines 286-292  
**Severity:** HIGH

**Issue:**  
Default dashboard credentials are weak and well-known:
```bash
dashboard_user=${dashboard_user:-admin}
dashboard_pass=${dashboard_pass:-admin123}
```

**Impact:**  
If user accepts defaults (presses Enter), FRP dashboard accessible with admin/admin123. Common target for automated attacks.

**Recommendation:**  
Generate strong random password by default:
```bash
local default_pass=$(tr -dc 'a-zA-Z0-9!@#$%^&*' < /dev/urandom | head -c 20)
read -p "Enter dashboard password [${default_pass}]: " dashboard_pass
dashboard_pass=${dashboard_pass:-$default_pass}
echo -e "${YELLOW}Dashboard password: ${dashboard_pass}${NC}"
```

Or require user to set password explicitly.

---

### MEDIUM-011: Command Injection Risk in User Inputs
**Location:** Lines 48, 103, 218, 234, 278-292  
**Severity:** MEDIUM

**Issue:**  
User inputs used in commands without proper quoting in some contexts. While most uses are quoted, shell expansions could theoretically occur.

**Example:**  
Line 220: `hostnamectl set-hostname "$h"` - properly quoted  
Line 221: `echo "$h" > /etc/hostname` - properly quoted  
Line 225: `sed -ri "s@^(127\.0\.1\.1\s+).*@\1$h@"` - `$h` unquoted in replacement string

If hostname contains `@` or `\`, sed could behave unexpectedly.

**Recommendation:**  
Ensure all user inputs are validated before use and/or escaped:
```bash
h_escaped=$(printf '%s\n' "$h" | sed 's/[[\.*^$()+?{|]/\\&/g')
sed -ri "s@^(127\.0\.1\.1\s+).*@\1${h_escaped}@" /etc/hosts
```

Or better: validate strictly per HIGH-006 to prevent special chars.

---

### MEDIUM-012: prompt_yes_no Lacks `-r` Flag
**Location:** Line 34  
**Severity:** MEDIUM

**Issue:**  
```bash
read -p "$prompt_text (Y/n): " choice
```

Without `-r`, backslashes in input are interpreted as escape sequences.

**Example:**  
User types `Y\n` → could break logic  

**Recommendation:**  
```bash
read -r -p "$prompt_text (Y/n): " choice
```

Apply to all `read` statements in script (lines 48, 57, 103, 218, 234, 279, 282, 286, 290, 296).

---

### LOW-006: Root Privilege Assumption
**Location:** Line 32  
**Severity:** LOW

**Issue:**  
Script requires root but performs all operations as root, including downloading/compiling.

**Recommendation:**  
For operations not requiring root (downloads, tar extraction), consider using `sudo -u nobody` or dedicated service account. (This is aspirational; current approach is acceptable for initialization script.)

---

### LOW-007: Sensitive Token Displayed in Prompt Default
**Location:** Line 296  
**Severity:** LOW

**Issue:**  
```bash
read -p "Enter authentication token [${default_token}]: " auth_token
```

If someone is shoulder-surfing or screen-sharing, default token visible.

**Recommendation:**  
```bash
read -p "Enter authentication token (or press Enter for random): " auth_token
auth_token=${auth_token:-$default_token}
echo -e "${YELLOW}Authentication token: ${auth_token}${NC}"
```

---

## 5. Concurrency & Performance Considerations

### HIGH-012: No File Locking on Shared Resources
**Location:** Lines 59, 86, 122, 144, 148  
**Severity:** HIGH

**Issue:**  
Multiple critical system files edited without locking:
- `/etc/ssh/sshd_config` (line 59)
- `/etc/fstab` (lines 86, 122, 144)
- `/etc/sysctl.conf` (line 148)

**Risk:**  
If multiple processes (other scripts, automation, duplicate vps_init runs) edit simultaneously:
- File corruption
- Race conditions
- Incomplete writes

**Recommendation:**  
Use `flock` for critical sections:
```bash
(
    flock -x 200 || { echo "Failed to acquire lock"; exit 1; }
    sed -i.bak ... /etc/ssh/sshd_config
    systemctl restart sshd
) 200>/var/lock/vps_init_ssh.lock
```

Apply to all config file modifications.

---

### MEDIUM-013: SSH Restart During Active Session
**Location:** Line 60  
**Severity:** MEDIUM

**Issue:**  
`systemctl restart sshd` while user connected via SSH. If SSH configuration invalid or service fails to start, user disconnected and locked out.

**Existing Mitigation:**  
- Line 63-65: Verification after restart
- Script runs with `set -e`, exits on failure
- User likely has VNC/console access on VPS

**Recommendation:**  
Explicitly warn user:
```bash
echo -e "${YELLOW}WARNING: SSH will restart. Ensure you have console access!${NC}"
read -p "Press Enter to continue or Ctrl+C to abort..."
systemctl restart sshd
```

Add comment suggesting testing new port in parallel session before closing current one.

---

### MEDIUM-014: Long-Running dd/fallocate Without Timeout
**Location:** Lines 130-138  
**Severity:** MEDIUM

**Issue:**  
Creating large swap file (e.g., 8GB) can take minutes with `dd`. No timeout or progress indication (beyond `status=progress`).

**Risk:**  
Script appears hung, user may kill it mid-operation, leaving partial swap file consuming disk.

**Recommendation:**  
- Implement timeout wrapper
- Pre-check disk space (see HIGH-005)
- Consider using `dd` with `oflag=direct` for better performance
```bash
timeout 600 dd if=/dev/zero of="$swap_file_path" bs=1M count=${target_swap_mb} status=progress oflag=direct
if [ $? -eq 124 ]; then
    echo -e "${RED}SWAP creation timed out after 10 minutes.${NC}"
    rm -f "$swap_file_path"
    return 1
fi
```

---

### MEDIUM-015: Network Operations Without Retry/Timeout
**Location:** Lines 160, 260, 264, 299, 311  
**Severity:** MEDIUM

**Issue:**  
`apt-get update`, `curl`, `wget` lack retry logic and custom timeouts. On poor network, script could hang for default timeout (minutes) or fail on transient errors.

**Recommendation:**  
Add timeouts and retries:
```bash
# For apt
apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=10 update

# For curl
curl -fsSL --retry 3 --retry-delay 5 --max-time 30 ...

# For wget  
wget --tries=3 --timeout=30 -qO /tmp/frp.tar.gz "$url"
```

---

### LOW-008: Potential Race in GitHub API Call
**Location:** Line 299  
**Severity:** LOW

**Issue:**  
```bash
local latest_version=$(curl -s "https://api.github.com/repos/fatedier/frp/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
```

GitHub API rate-limited (60 req/hour for unauthenticated). If limit exceeded, returns error JSON, `grep` extracts nothing, `latest_version` empty.

**Recommendation:**  
Check for empty result:
```bash
if [[ -z "$latest_version" ]]; then
    echo -e "${RED}Could not fetch frp version. GitHub API may be rate-limited.${NC}"
    echo "You can manually specify version or try again later."
    read -p "Enter FRP version (e.g., v0.52.0) or 'skip': " manual_version
    if [[ "$manual_version" == "skip" ]]; then
        return 1
    fi
    latest_version="$manual_version"
fi
```

---

## 6. Code Quality & Maintainability

### CRITICAL (See CRITICAL-001 above): Misplaced Code Block

---

### HIGH-013: Long, Complex sed Command
**Location:** Line 59  
**Severity:** HIGH (Maintainability)

**Issue:**  
```bash
sed -i.bak -E -e "s/^[#\s]*Port\s+.*/Port ${SUMMARY_SSH_PORT}/" -e "s/^[#\s]*PermitRootLogin\s+.*/PermitRootLogin prohibit-password/" -e "s/^[#\s]*PasswordAuthentication\s+.*/PasswordAuthentication no/" -e "s/^[#\s]*PubkeyAuthentication\s+.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
```

Single line, 4 regex patterns, hard to read, debug, or modify.

**Recommendation:**  
Break into multiple lines or use heredoc:
```bash
sed -i.bak -E \
    -e "s/^[#\s]*Port\s+.*/Port ${SUMMARY_SSH_PORT}/" \
    -e "s/^[#\s]*PermitRootLogin\s+.*/PermitRootLogin prohibit-password/" \
    -e "s/^[#\s]*PasswordAuthentication\s+.*/PasswordAuthentication no/" \
    -e "s/^[#\s]*PubkeyAuthentication\s+.*/PubkeyAuthentication yes/" \
    /etc/ssh/sshd_config
```

Or use multiple sed calls with comments.

---

### MEDIUM-016: Inconsistent Command Checking
**Location:** Various  
**Severity:** MEDIUM

**Issue:**  
Script uses different patterns to check command existence:
- Line 128: `command -v fallocate >/dev/null 2>&1`
- Line 252: `command -v docker &> /dev/null`
- Line 344: `command -v ufw &> /dev/null`

Both work but inconsistent. `&>` is bashism, `>/dev/null 2>&1` is POSIX.

**Recommendation:**  
Standardize on `command -v ... >/dev/null 2>&1` throughout for POSIX compliance.

---

### MEDIUM-017: Magic Numbers Lack Context
**Location:** Lines 77-99, 279-292  
**Severity:** MEDIUM

**Issue:**  
Hardcoded values without named constants:
- SWAP sizes (512, 1024, 2048, 8192 MB)
- FRP ports (7000, 7500)
- Sleep durations (2, 3 seconds)

**Recommendation:**  
Define at top of script:
```bash
readonly DEFAULT_FRP_BIND_PORT=7000
readonly DEFAULT_FRP_DASHBOARD_PORT=7500
readonly SSH_RESTART_WAIT_SECONDS=2
readonly MIN_MEM_FOR_2GB_SWAP=2048
# etc.
```

Use variables in code for clarity and maintainability.

---

### MEDIUM-018: Lack of Function Comments
**Location:** Various functions  
**Severity:** MEDIUM

**Issue:**  
Functions like `configure_swap()`, `install_frp()` perform complex operations but lack header comments describing:
- Purpose
- Parameters
- Side effects
- Return values

**Recommendation:**  
Add structured comments:
```bash
# configure_swap: Creates and activates swap file if needed
# Globals: SUMMARY_SWAP_STATUS
# Arguments: None (interactive prompts)
# Returns: 0 on success, 1 on error
# Side effects: Modifies /etc/fstab, /etc/sysctl.conf
configure_swap() {
    # ...
}
```

---

### LOW-009: Inconsistent Error Messages
**Location:** Various  
**Severity:** LOW

**Issue:**  
Error messages use different formats:
- Line 64: `"FATAL: SSH verification failed!"`
- Line 107: `"Invalid input. Skipping."`
- Line 193: `"Fail2ban service failed to start! Check logs."`

Some say "FATAL", others don't. Some suggest actions, others don't.

**Recommendation:**  
Standardize error format:
```bash
# ERROR: <what failed>. <why/impact>. <remediation>
echo -e "${RED}ERROR: SSH verification failed. Config may be invalid. Check using VNC.${NC}"
```

---

### LOW-010: Potential Quoting Issues
**Location:** Lines 130, 133  
**Severity:** LOW

**Issue:**  
```bash
fallocate -l ${target_swap_mb}M "$swap_file_path"
dd if=/dev/zero of="$swap_file_path" bs=1M count=${target_swap_mb}
```

`${target_swap_mb}` unquoted. While numeric variables don't need quoting for word splitting, consistency would improve readability.

**Recommendation:**  
Quote all variable expansions unless explicitly relying on word splitting:
```bash
fallocate -l "${target_swap_mb}M" "$swap_file_path"
```

---

## 7. Positive Findings / Existing Controls

### Strengths Identified:

1. **Comprehensive Logging** (Line 18): All actions logged with timestamp for audit trail.

2. **Post-Operation Verification** (Lines 63-65, 187-194, 349-357): Critical services verified after start/restart.

3. **Interactive Confirmations**: User must explicitly accept each major component, reducing accidental installations.

4. **Backup Creation**: Configuration files backed up before modification (line 59, 89, 121).

5. **Use of `set -e`**: Fails fast on errors in most cases (though not perfect).

6. **SSH Security Best Practices**:
   - Key-based authentication enforced
   - Password auth disabled
   - Root login limited to key-only

7. **Firewall Integration**: UFW and Fail2ban properly configured together.

8. **Modern Crypto**: Uses ed25519 SSH keys (line 52), strong modern standard.

9. **Summary Display** (Lines 360-375): Comprehensive final report of all changes.

10. **BBR TCP Optimization** (Lines 201-213): Modern performance enhancement.

---

## 8. Priority Recommendations Summary

### Must Fix (CRITICAL):
1. **CRITICAL-001**: Move misplaced code block (lines 84-90) after line 99
2. **CRITICAL-002**: Fix SSH port validation/documentation mismatch (line 48)
3. **CRITICAL-003**: Prevent private key logging (lines 18, 56)

### Should Fix (HIGH):
1. **HIGH-001**: Add `set -u` and `set -o pipefail` (line 16)
2. **HIGH-002**: Validate `passwd` success (line 41)
3. **HIGH-003**: Verify `systemctl restart sshd` (line 60)
4. **HIGH-004**: Fix infinite loop risk (line 57)
5. **HIGH-005**: Bound SWAP size input (lines 103-109)
6. **HIGH-006**: Validate hostname input (line 218)
7. **HIGH-007**: Eliminate duplicate SWAP code (lines 84-90, 117-123)
8. **HIGH-008**: Control fstab backup growth (lines 89, 121)
9. **HIGH-009**: Verify Docker download integrity (line 260)
10. **HIGH-010**: Verify FRP download integrity (line 311)
11. **HIGH-011**: Improve default FRP credentials (lines 286-292)
12. **HIGH-012**: Add file locking for config edits (various)
13. **HIGH-013**: Improve sed readability (line 59)

### Consider (MEDIUM):
- All MEDIUM-001 through MEDIUM-018 issues per detailed descriptions above

### Polish (LOW):
- All LOW-001 through LOW-010 issues for production hardening

---

## Conclusion

The `vps_init.sh` script provides a solid foundation for VPS initialization with good security practices. However, it requires critical fixes before production use:

1. **Fix code placement bug** that breaks SWAP logic
2. **Protect private SSH key** from logging
3. **Add comprehensive input validation**
4. **Implement download integrity verification**
5. **Improve error handling** with `set -u`, `set -o pipefail`, and explicit checks

After addressing HIGH and CRITICAL issues, the script will provide a robust, secure VPS initialization experience suitable for production environments.

---

**Total Issues Found:**
- Critical: 3
- High: 13
- Medium: 18
- Low: 10
- **Total: 44 findings**

**Estimated Effort to Remediate HIGH/CRITICAL:**
- ~8-12 hours for experienced developer
- Testing on VM: +4 hours
- Documentation updates: +2 hours
- **Total: ~14-18 hours**

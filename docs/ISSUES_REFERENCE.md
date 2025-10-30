# Issues Reference Table

Quick lookup table for all identified issues with direct file locations and fix priorities.

## Critical Issues (P1)

| ID | Issue | File(s) | Line(s) | Effort | Impact |
|----|-------|---------|---------|--------|--------|
| #1 | SWAP function structural bug | vps_init.sh | 84-90, 117-123 | Medium | CRITICAL |
| #1 | SWAP function structural bug | add_components.sh | 41-47, 74-79 | Medium | CRITICAL |
| #2 | Private key displayed in terminal | vps_init.sh | 55-57 | Low | CRITICAL |
| #3 | No timeout on Docker GPG fetch | vps_init.sh | 260 | Low | HIGH |
| #3 | No timeout on FRP API call | vps_init.sh | 299 | Low | HIGH |
| #3 | No timeout on FRP download | vps_init.sh | 311 | Low | HIGH |
| #3 | No timeout on Docker GPG fetch | add_components.sh | 187 | Low | HIGH |
| #3 | No timeout on FRP API call | add_components.sh | 224 | Low | HIGH |
| #3 | No timeout on FRP download | add_components.sh | 236 | Low | HIGH |

## High Priority Issues (P2)

| ID | Issue | File(s) | Line(s) | Effort | Impact |
|----|-------|---------|---------|--------|--------|
| #4 | No hostname validation | vps_init.sh | 218 | Medium | HIGH |
| #4 | No SSH port reservation check | vps_init.sh | 48 | Low | HIGH |
| #4 | No SWAP size upper bound | vps_init.sh | 103 | Low | HIGH |
| #4 | No FRP port validation | vps_init.sh | 279-284 | Medium | HIGH |
| #4 | No password strength check | vps_init.sh | 286-292 | Medium | HIGH |
| #4 | No timezone validation | vps_init.sh | 235 | Low | MEDIUM |
| #4 | No hostname validation | add_components.sh | 149 | Medium | HIGH |
| #4 | No SWAP size upper bound | add_components.sh | 60 | Low | HIGH |
| #5 | Aggressive error handling (set -e) | vps_init.sh | 16 | High | HIGH |
| #5 | Aggressive error handling (set -e) | add_components.sh | 16 | High | HIGH |
| #6 | Credentials in logs | vps_init.sh | 18, 294, 292 | Medium | HIGH |
| #6 | Credentials in logs | add_components.sh | 18, 219, 217 | Medium | HIGH |
| #7 | SSH verification race condition | vps_init.sh | 61-66 | Low | HIGH |

## Medium Priority Issues (P3)

| ID | Issue | File(s) | Line(s) | Effort | Impact |
|----|-------|---------|---------|--------|--------|
| #8 | Code duplication | Both scripts | Multiple | High | MEDIUM |
| #9 | Insufficient error context | vps_init.sh | 186-194 | Low | MEDIUM |
| #9 | Insufficient error context | vps_init.sh | 351-357 | Low | MEDIUM |
| #9 | Insufficient error context | add_components.sh | 130-132 | Low | MEDIUM |
| #9 | Insufficient error context | add_components.sh | 274-280 | Low | MEDIUM |
| #10 | prompt_yes_no could be more robust | vps_init.sh | 34 | Low | LOW |
| #10 | prompt_yes_no could be more robust | add_components.sh | 22 | Low | LOW |
| #11 | /etc/hosts modification fragility | vps_init.sh | 224-228 | Medium | MEDIUM |
| #11 | /etc/hosts modification fragility | add_components.sh | 155-159 | Medium | MEDIUM |
| #12 | No rollback mechanism | vps_init.sh | 45-67 | High | HIGH |

## Low Priority Issues (P4)

| ID | Issue | File(s) | Line(s) | Effort | Impact |
|----|-------|---------|---------|--------|--------|
| #13 | Memory calculation precision | vps_init.sh | 71 | Low | LOW |
| #13 | Memory calculation precision | add_components.sh | 28 | Low | LOW |
| #14 | Inconsistent color usage | Both scripts | Multiple | Low | LOW |
| #15 | No progress indicators | Both scripts | Multiple | Low | LOW |
| #16 | Hardcoded paths | Both scripts | Multiple | Low | LOW |

## Issue Categories

### By Severity
- **CRITICAL**: 2 issues (1 structural bug affecting both scripts, 1 credential exposure)
- **HIGH**: 11 issues (validation, timeouts, error handling, credentials)
- **MEDIUM**: 5 issues (code quality, error context, rollback)
- **LOW**: 4 issues (polish, UX improvements)

### By File
- **vps_init.sh**: 18 specific locations with issues
- **add_components.sh**: 15 specific locations with issues
- **Both scripts**: 6 systemic patterns

### By Type
- **Security**: 6 issues (#2, #4 validation, #6 credentials)
- **Reliability**: 7 issues (#1 structure, #3 timeouts, #5 error handling, #7 race, #12 rollback)
- **Code Quality**: 6 issues (#8 duplication, #9 error context, #10-11 robustness)
- **Technical Debt**: 4 issues (#13-16 polish)

## Quick Fix Checklist

### Phase 1: Critical Fixes (Day 1)
- [ ] Fix SWAP function structure in vps_init.sh (lines 84-90, 117-123)
- [ ] Fix SWAP function structure in add_components.sh (lines 41-47, 74-79)
- [ ] Replace private key display with secure file save (vps_init.sh:55-57)
- [ ] Add timeouts to all curl commands (6 locations)
- [ ] Add timeouts to all wget commands (2 locations)
- [ ] Secure log file permissions (both scripts:18)

### Phase 2: Security Hardening (Week 1)
- [ ] Implement hostname validation function
- [ ] Add port validation and reservation checks
- [ ] Add SWAP size upper bounds
- [ ] Validate FRP ports before use
- [ ] Add password strength requirements
- [ ] Implement timezone validation
- [ ] Replace set -e with explicit error handling
- [ ] Mask credentials in output/logs

### Phase 3: Robustness (Week 2)
- [ ] Improve SSH verification with retry loop
- [ ] Add detailed error context to all service failures
- [ ] Implement rollback mechanism for SSH config
- [ ] Improve /etc/hosts handling with cloud-init detection
- [ ] Add pre-flight checks (disk space, network, OS version)

### Phase 4: Code Quality (Week 3-4)
- [ ] Extract common functions to shared library
- [ ] Remove code duplication
- [ ] Standardize color usage
- [ ] Add progress indicators
- [ ] Centralize path constants

## Testing Matrix

After fixing each issue, test on:

| OS Version | Issue #1 | Issue #2 | Issue #3 | Issue #4 | Issue #5 |
|------------|----------|----------|----------|----------|----------|
| Debian 11  | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| Debian 12  | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| Ubuntu 20.04 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| Ubuntu 22.04 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| Ubuntu 24.04 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |

## Related Documents

- **Full Analysis**: [ROBUSTNESS_AUDIT_REPORT.md](./ROBUSTNESS_AUDIT_REPORT.md)
- **Quick Summary**: [AUDIT_SUMMARY.md](./AUDIT_SUMMARY.md)
- **Documentation Index**: [README.md](./README.md)

---

**Legend:**
- P1 = Priority 1 (Critical - Fix Immediately)
- P2 = Priority 2 (High - Fix This Sprint)
- P3 = Priority 3 (Medium - Next Cycle)
- P4 = Priority 4 (Low - Technical Debt)

**Last Updated**: 2024

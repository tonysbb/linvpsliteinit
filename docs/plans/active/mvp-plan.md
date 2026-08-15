# linvpsliteinit 收敛版 MVP 计划

## 目标

把 `linvpsliteinit` 做成通用 VPS 初始化工具的最小可靠增量：

- `vps_init.sh`：纯净新系统的初始 ZRAM/Chrony 基线；
- `add_components.sh`：已有系统的保守 ZRAM/Chrony 增量组件。

舰队只作为最低兼容样本，不是设计上限；本轮不修改舰队。

## 本轮 Must

1. 修复本次功能直接涉及的日志私钥泄漏和 swap 误伤边界。
2. 增加最小环境检测：容器、已有 ZRAM、zswap、时间服务冲突。
3. 增加 Debian/Ubuntu `zram-tools` 配置：`PERCENT=50`、`PRIORITY=100`，不指定算法。
4. 增加 Alpine `zram-init` 单设备 swap 配置：RAM 50%、优先级 100。
5. 增加 Chrony client-only 可选安装；已有 chrony 只验证，timesyncd 默认不替换，其他 NTP 守护进程冲突即停止。
6. 更新三份 README 与 CHANGELOG，说明两个入口的生命周期边界。

## 非目标

- 不修改舰队、不部署、不重启远程节点。
- 不主动启用 zswap。
- 不做防火墙、SSH、FRPS、网络调优的整体重构。
- 不做多设备 ZRAM、ZRAM 文件系统、writeback、动态算法选择、自动迁移和远程编排。
- 不新增控制面、数据库、daemon 或第三方仓库。

## 任务

### Task 1：最小安全修复

- 私钥输出绕过 tee 日志，日志文件权限为 600。
- 已有脚本 swap 文件不原地 swapoff/删除重建；只新增本项目自己的 swap 条目，不修改未知 swap。
- `mkswap`/`swapon`/持久化失败时删除残件并恢复 fstab 备份。

### Task 2：ZRAM

- 纯净机和组件菜单均提供独立入口。
- 容器、已有活动 ZRAM、zswap 或内核能力不足时安全跳过。
- Debian/Ubuntu 使用 `zram-tools` 最小配置。
- Alpine 使用 `zram-init` 单 swap 设备最小配置。
- 配置文件带时间戳备份；启动后未出现活动 ZRAM 则停止、撤销自启、恢复配置。
- 不卸载已有包，不修改已有磁盘 swap，不接管未知 ZRAM。

### Task 3：Chrony

- 已运行 chrony：不重启，只验证。
- systemd-timesyncd：`vps_init.sh` 可在用户确认后替换；`add_components.sh` 默认保留，明确确认后替换。
- ntp/ntpsec/openntpd：中止且不写配置。
- 容器：跳过。
- 只安装 NTP client，不写 `allow`，不开放 UDP 123。
- 安装或启用失败时恢复 timesyncd。

### Task 4：QA 与文档

- `sh -n`、`dash -n`、`shellcheck -S error`、`git diff --check`。
- 静态断言覆盖入口、配置字段、冲突检测、回滚和生命周期文档。
- 不在本机或舰队执行安装操作。
- 独立只读 Review 一轮，修复 blocker 后复核一次。

## 最小验收矩阵

- Debian 11/12、Ubuntu 20/22/24、Alpine。
- 无 swap、已有脚本 swap、已有 ZRAM、zswap 已启用。
- chrony、systemd-timesyncd、ntpd 类服务、无时间服务。
- 容器环境。
- 重复执行和安装/启动失败回滚。
- 日志不含私钥或秘密值。

## 复杂度预算

- 新增主要功能：2 个。
- 每个入口新增约 60–90 行以内为目标。
- 新增服务、控制面、数据库：0。
- Review：实现 Review 1 次、修复复核 1 次。
- 超出预算 30%、出现第二条大型支线或计划无法解释主要实现时立即停止。

## 交付门槛

- 两个生命周期入口行为清晰且文档一致。
- 核心路径和失败路径有真实静态/行为证据。
- 未知已有配置默认不被接管。
- 独立 Review 无 blocker。
- active plan 收口，工作区和 commit 状态清晰。

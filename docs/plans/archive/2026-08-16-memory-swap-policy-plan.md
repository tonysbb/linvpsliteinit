# ZRAM 与磁盘 Swap 策略改进计划

## 目标

在保持两个脚本单文件可运行的前提下，统一实现可解释的 ZRAM 档位、独立磁盘 Swap 推荐、项目自有 Swap/ZRAM 的安全删除，并在代码完成后再进入舰队 L3 串行部署审批。

## Must

1. 标称 RAM 归一化：实际容量达到下一二次幂档位 90% 时按标称容量计算。
2. ZRAM：`min(RAM/2, 4096 MiB)` 后向下取 `64/128/256/512/1024/2048/4096 MiB` 档位，priority 100。
3. 磁盘 Swap：只统计非 ZRAM 活动 Swap；`RAM<2GiB → 2×RAM`、`2GiB≤RAM<8GiB → RAM`、`RAM≥8GiB → 4096MiB`；不扣减 ZRAM。
4. 已有磁盘 Swap 不自动缩小、重建或接管；项目创建的 `/swapfile_by_script` 使用低于 ZRAM 的优先级。
5. 增加删除项目自有 `/swapfile_by_script` 和带项目标记的 ZRAM；删除前检查可用内存，失败时不删除持久化配置或文件。
6. zswap 已启用时不叠加 ZRAM；脚本不主动启用 zswap。
7. 两个脚本保持 POSIX sh；更新三语 README 与 CHANGELOG。

## 非目标

- 不删除第三方 Swap/ZRAM。
- 不卸载软件包。
- 不自动缩放已有 Swap。
- 不配置 zswap、ZRAM writeback、压缩算法或多 ZRAM 设备。
- 本开发阶段不修改舰队节点。

## 删除契约

### 磁盘 Swap

仅处理 `/swapfile_by_script`。先备份 fstab，检查 `MemAvailable >= SwapUsed + max(256MiB, RAM/10)`，确认后执行 `swapoff`；只有确认设备退出 `/proc/swaps` 后才精确移除 fstab 行并删除文件。失败时保留原配置和文件。

### ZRAM

仅处理配置中含 `Managed by linvpsliteinit` 标记的 `zramswap`/`zram-init`。检查内存余量并确认后停止服务；确认 ZRAM 退出 `/proc/swaps` 后取消自启并删除项目配置，保留软件包和磁盘 Swap。

## 验收

- 行为测试覆盖 RAM 归一化、ZRAM 档位、20GiB、磁盘 Swap 边界、ZRAM/磁盘分类。
- 删除路径静态/模拟测试覆盖管理标记、内存余量、精确目标和失败保护。
- `sh -n`、`dash -n`、`shellcheck -S error`、`git diff --check` 全部通过。
- 独立 Review 无 BLOCKER/MAJOR。
- README/CHANGELOG 与行为一致。
- 提交并 push 后，以固定 commit 和 SHA-256 另行提交舰队 L3 串行计划。

## 复杂度预算

- 生产脚本：两个现有脚本，每个净新增不超过约 120 行。
- 测试：1 个 POSIX sh 行为测试文件。
- 新依赖/服务：0。
- Review：一轮审查、一轮定点复核。
- 若新增超过预算 30% 或需要共享运行时/新控制面，立即停止并重新决策。

## 舰队口径

- inventory 登记 11 台，含已销毁 WAPHK，不含 BRODE。
- 当前有效远程成员 10 台；加 BRODE 后当前有效舰队总数 11 台。
- PHJUS 是成员但保持只读；WAPHK 不参与部署。
- 开发完成不等于批准部署，舰队写入必须再次通过 L3 批次确认。

# PalIndustrialController 开发交接（v0.3.0-rc.1 · 待真机验收）

当前主线源码已整合 **P0（工业总控加固）+ P1（只读帕鲁工业顾问）+ P2（七页原创管理面板与趋势图）**，全部 **17 项 Lua 5.4 回归测试** 与全模块 `luac54 -p` 语法校验均已通过。按用户要求，本轮未继续拉起游戏做 P1/P2 实机交互测试，后续真机验收交由 Codex 在隔离环境中完成。

## 源码清单（`PalIndustrialController/Scripts/`）

| 文件 | 职责 |
| --- | --- |
| `main.lua` | 按键绑定、UE4SS 游戏线程入口、目标与 v2 任务日志持久化、自动补货主循环、人工核验接管（完整保留 rc.4 修复）、7 页视图调度与顾问按需触发 |
| `industrial_game.lua` | 动态据点/普通仓库/配方设备快照、共享配方解锁检查、供电与路径状态采集、本地原版下单预检与跨据点双端核验调拨 |
| `industrial_planner.lua` | 纯 Lua 递归供应链规划、保底库存守恒、备选调拨路径、缺电/寻路/队列/待搬精准诊断 |
| `industrial_journal.lua` | v1/v2 任务日志原子替换、跨重启人工核验标记持久化、拓扑变更与超时 fail-closed 拦截 |
| `industrial_workforce.lua` | **P1 新增**：按需只读读取据点 `WorkerDirector` 在岗帕鲁、玩家锁定偏好（`OffWorkSuitabilityList`）、玩家帕鲁终端及种族表（绝不修改游戏状态） |
| `industrial_advisor.lua` | **P1 升级**：纯 Lua 瓶颈因果链分析、非劳动力与劳动力严格区分、已有帕鲁优先（含机会成本）、3 种策略（`low_cost`/`balanced`/`max_throughput`）与可折叠高级培养 |
| `industrial_dashboard.lua` | **P2 恢复整合**：7 页数据视图（总览/库存/生产/物流/帕鲁顾问/统计/设置）、生产异常告警与 20 条物流记录环缓 |
| `industrial_history.lua` | 有界连续库存采样（30 样本 / 128 物品 / 断连重置），返回真实趋势序列 |
| `industrial_panel.lua` | **P2 升级**：`980×620` 原创暗色工业 UMG 面板、4 KPI 卡、7 页签栏、告警高亮与真实库存趋势条形图 |

## 已有实机证据（2026-11-27）

- `.local/p0-acceptance/p0-snapshot-comparison.log`：12 轮 A/B 快照对照，`12/12 matching=true`，扫描中位数 `134.5 ms → 105.5 ms`。
- `.local/p0-acceptance/rc4-live-recursive-and-p1-probe-UE4SS.log`：
  - 钉子 `73 → 78` 入库确认、金属锭守恒于 `16` 保底、日志清空；
  - 钉子目标提至 `83` 后自动递归下单 `CopperIngot ×1` → 熔炼入库 → 自动触发下游 `MachineParts ×1`；
  - 实机读通 3 据点 `WorkerDirector` 在岗帕鲁、供电模块、工作可达性及 `GetDatabaseCharacterParameter` 中文名查询。

## Codex 接手后的建议真机验收顺序

1. 先运行 `.local/lua54/native/lua54.exe tests/run.lua` 确认 17 项回归通过。
2. 用隔离测试目录 `-UserDir="C:\Users\sunyi\AppData\Local\Temp\PalIndustrialP0Acceptance"`（世界 `0F9F4305C0D44909BE7642DAA3401981`）部署 `PalIndustrialController/Scripts/*.lua`（不要覆盖 `PalIndustrialController-original-before-p0-acceptance` 备份与正式存档）。
3. 进游戏依次实机验证：
   - **P2 UI**：`Ctrl+F10` 打开面板，`Ctrl+F9` / `Ctrl+Shift+F9` 走完 7 个页签，核对 `1280×800` 及全屏下中文显示、无越界重叠、翻页与编辑框正常；
   - **P1 顾问**：切到「帕鲁顾问」页核对在岗帕鲁/终端候补读取、验证 `Ctrl+E`（3 策略切换）与 `Ctrl+D`（高级培养展开/折叠），确认全程只读无报错；
   - **P2 统计**：等待 >= 2 个 8 秒周期后查看目标物品趋势条形图；
   - **P0 边界**：复核手动取消订单、目标仓满格、设备断电三种异常场景下的安全暂停与恢复。
4. 验收全部通过且需要切回正式存档时，先关闭游戏，将 `UE4SS/Mods/PalIndustrialController` 移出并从 `UE4SS/PalIndustrialController-original-before-p0-acceptance` 恢复或安装验收后的正式包。

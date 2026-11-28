# PalIndustrialController v0.3.0-rc.1 审查与测试报告

## 基线与版本演进

当前工作区在 `v0.2.0-rc.4` 的 P0 持久化核验基线上完成 **P0 加固 + P1 帕鲁工业顾问 + P2 七页原创界面** 的增量实现。所有游戏引擎接口均以本机 UE4SS 生成的 `CXXHeaderDump/Pal.hpp` 与 `Pal_enums.hpp` 为准，并对核心类完成了实机采样验证。

| 阶段 / 模块 | v0.2.0-rc.4 基线 | v0.3.0-rc.1 实现状态 |
| --- | --- | --- |
| P0 工业总控 | 动态据点增删、跨据点调拨、本地下单、日志 v2 人工核验持久化、共享配方缓存 | 新增设备供电状态（`UPalMapObjectEnergyModule`）与寻路可达（`CannotApproachByWork`）采集；新增缺电/寻路/满仓回归；补齐真实两级递归链实机日志 |
| P1 帕鲁工业顾问 | 基础静态建议（无实时帕鲁读取） | 新增按需只读适配器 `industrial_workforce.lua` 与纯推荐引擎 `industrial_advisor.lua`：读取在岗帕鲁状态与玩家关闭工种（`OffWorkSuitabilityList`）、帕鲁终端候补、严格隔离非劳动力瓶颈、优先已有帕鲁并标明机会成本、支持 3 种策略（`Ctrl+E`）与折叠式高级培养（`Ctrl+D`） |
| P2 管理与体验 | 3 视图简化面板 | 基于 rc.4 核验核心整合 7 页暗色原创 UMG 面板（总览/库存/生产/物流/帕鲁顾问/统计/设置），新增真实连续样本库存趋势条形图与双向切页快捷键 |

## 已执行验证（区分实机实测与独立 Lua 回归）

### A. 独立 Lua 5.4 回归与语法检查（`v0.3.0-rc.1`，全部通过）
- 全量 9 个模块 + `tests/run.lua` 通过本机 `luac54 -p` 语法校验，无错误。
- 运行 `lua54.exe tests/run.lua`：**17 项回归全部通过**，覆盖：
  1. 五据点动态拓扑增删与暂缺模型保护
  2. 每轮共享配方解锁/禁用检查并在下轮重读
  3. 三据点跨据点递归上游生产规划
  4. 共享原料保底库存与批量取整
  5. 受阻调拨路径自动切换备选来源
  6. 排队/待搬/未知队列/同步未完成防重复下单
  7. 循环配方在规划预算内安全终止
  8. 任务日志 v1/v2 读写与写入中断（`.tmp`）安全拦截
  9. 订单入库核验与撤站/拓扑变化后人工核验标记持久化
  10. 原版跨据点调拨双端差额核验与意图先持久化
  11. 远程执行拒绝与预检失败分类（缺电等）
  12. 只读诊断在无劳动力数据时诚实标注未知
  13. **新增（P0）**：设备缺电（`energy`）、路径受阻（`path`）与目的地仓库满格拒单且零扣料
  14. **新增（P1）**：`industrial_workforce.lua` 只读采集据点工人、`OffWorkSuitabilityList` 玩家锁定项与帕鲁终端候补
  15. **新增（P1）**：`industrial_advisor.lua` 严格不将缺料归因于劳动力、终端帕鲁优先于其他据点、机会成本展示、三种策略排序差异与玩家等级长期目标标记、可折叠高级培养建议
  16. **新增（P2）**：`industrial_dashboard.lua` 7 页导航、生产页缺电告警、物流 20 条有界队列、`industrial_history.lua` 返回连续趋势序列
  17. 库存历史有界采样与断连/拓扑变化/间隔超限重置

### B. Windows Steam 隔离单人存档实机实测（`v0.2.0-rc.4` 候选 + SDK 探针，2026-11-27）
- 环境：Windows Steam `1.0.5.102999` + UE4SS Experimental `2281fa31`，严格使用 `-UserDir="C:\Users\sunyi\AppData\Local\Temp\PalIndustrialP0Acceptance"` 隔离副本（世界 `0F9F4305C0D44909BE7642DAA3401981`）。
- **P0 动态拓扑与重启核验**（此前实测日志见 `.local/p0-acceptance/`）：第四据点建造/拆除、跨据点调拨、撤站显示 `?` 并写入日志 v2 人工核验标记、重启仍拦截、`Ctrl+Shift+R` 接管后单批生产入库均通过。
- **P0 完整两级递归实测**（日志保存于 `.local/p0-acceptance/rc4-live-recursive-and-p1-probe-UE4SS.log`）：
  - `22:39:14` 自动受理 `MachineParts ×1` → `22:42:34` 实机搬运入库确认，钉子 `73 → 78`，金属锭守恒于 `16` 保底，订单日志清空。
  - `22:44:09` 将钉子目标提至 `83`（金属锭保底仍为 `16`）→ 自动递归触发上游熔炉 `CopperIngot ×1` → `22:46:02` 熔炼完成并搬运入库（`Delivery inferred: CopperIngot`）→ 同秒自动触发下游 `MachineParts ×1`（`CopperIngot` 扣回 `16`，`MachineParts` 排队 `5`）。
- **P0 扫描性能 12 轮 A/B 对照**（`.local/p0-acceptance/p0-snapshot-comparison.log`）：
  - 3 据点、24 仓库、14 设备同场景交替实测 12 轮，12/12 `matching=true`。
  - 原版 `rc.4`：范围 `108–157 ms`，中位数 `134.5 ms`。
  - 共享配方检查候选版：范围 `99–133 ms`，中位数 `105.5 ms`（单次扫描中位数降低约 21.6%）。
- **P1 核心 SDK 对象实机探针**（同份 `rc4-live-recursive-and-p1-probe-UE4SS.log`）：
  - 实机读通 3 个据点的 `UPalBaseCampModel.WorkerDirector.CharacterContainer.SlotArray`（据点1：4 名工人；据点2：13 名工人；据点3：0 名工人），完整读出 `SaveParameter.CharacterID`、等级、星级、SAN、饱食率、生病、睡眠、夜行、死亡、`CurrentWorkSuitability`、1–13 项 `GetWorkSuitabilityRankWithCharacterRank`。
  - 实机读通 `UPalMapObjectEnergyModule`（`IsRequiredEnergy` / `GetCurrentState`）、`UPalMapObjectWorkeeModule`（`CannotApproachByWork` / `GetWorkProgress`）、`UPalDatabaseCharacterParameter:GetLocalizedCharacterName`（实测 `Anubis → 阿努比斯`）。

### C. 待 Codex 接手完成的真机实测清单（尚未在运行游戏中验证）
1. 将 `v0.3.0-rc.1` 源码部署到隔离环境启动游戏，逐页检查 **7 页原创 UMG 面板**（总览/库存/生产/物流/帕鲁顾问/统计/设置）在 `1280×800` 与全屏下的排版、中文渲染、翻页及 `Ctrl+F9` / `Ctrl+Shift+F9` 切页流畅度。
2. 在「帕鲁顾问」页实机核验：
   - 按需读取在岗帕鲁与帕鲁终端（`PalPlayerDataPalStorage.TargetContainer`）耗时与准确性
   - 验证 `Ctrl+E` 切换 3 种策略与 `Ctrl+D` 展开/折叠高级培养建议
   - 核对玩家手动关闭某工种后，顾问是否准确识别并保持只读不改写
3. 在「统计」页实机观察连续采样 >= 2 次后的趋势条形图渲染。
4. 实机复核 P0 剩余人工异常边界（游戏内手动取消原版订单、塞满目标箱后触发调拨、断开据点电力）并最终验收 1 小时运行稳定性与帧时间对照。

## 兼容性矩阵

| 环境 | 状态与边界 |
| --- | --- |
| Windows Steam 1.0.5.102999 + UE4SS Experimental `2281fa31`（单人） | P0 主线与 SDK 探针已实机验证；`v0.3.0-rc.1` P1/P2 全部通过 Lua 5.4 回归，待真机 UI 验收 |
| Windows Steam 房主 / 多人客户端 / 专用服务器 | 未验收；当前写入依赖本地权威玩家与 UMG 客户端界面，后续单独验收专服权威执行与并发幂等 |
| 远征所自动派遣 | 未实现；后续按先只读缺料建议、后受控自动派遣顺序迭代 |
| Steam Deck / Linux Proton / macOS / 主机 | 未验证 |

# 变更日志

## v0.4.0-rc.2

- **全鼠标可交互 UMG 面板与输入隔离**：
  - 保留 `Ctrl+F10` 打开/关闭面板；打开后自动显示鼠标并通过 `SetInputMode_UIOnlyEx(..., bFlushInput = true)` 隔离游戏内按键，避免点击和打字触发攻击、建造或交互；关闭后自动交还鼠标和 `GameOnly` 输入。
  - 左侧 7 个导航项与右上角「✕ 关闭」升级为真实 UMG `UButton`，收起界面内大段快捷键说明，保留全部原有快捷键供熟练玩家使用。
  - 首页按当前状态只显示「启动补货」或「暂停补货」按钮；需要人工核验时列出具体待核验订单与「查看订单」入口，进入生产作业/据点调拨页核对后再提供「确认接管」按钮。
  - 库存页顶部直接内嵌 `UEditableTextBox` 搜索框与「搜索 / 清除 / 显示范围」按钮；点击任意物品行即可在右侧直接编辑或 ±10 调整目标数量并点「保存目标」。
  - 设置页全部 8 项单页直出，所有开关、选项与「导出蓝图」均改为可点击控件。
  - 顾问页继续保持默认不自动读取在岗帕鲁与帕鲁终端，仅在玩家手动点击高风险按钮或按 `Ctrl+F8` 时执行。
- **验证**：全部 17 个 Lua 文件通过 `luac54 -p`（0 错误），22 项 Lua 5.4 回归测试全部通过，并通过纯鼠标端到端流程模拟；实机隔离存档验收待执行。

## v0.4.0-rc.1

- **P0 调度与配置扩展**：
  - 新增 [industrial_config.lua](PalIndustrialController/Scripts/industrial_config.lua)：按存档/公会原子持久化运行模式（原版平衡/工业自动化/极限效率）、滞回区间（`hysteresisPct`）、据点分工角色、设备禁用开关与各项 P1/P2/P3 功能开关。
  - [industrial_planner.lua](PalIndustrialController/Scripts/industrial_planner.lua) 支持滞回防抖、据点角色优先级、手动禁用设备过滤、库存「实际/预留/可用/缺口」拆解与配方依赖链展示；[industrial_game.lua](PalIndustrialController/Scripts/industrial_game.lua) 扩展空闲设备工种启发式并传递玩家 Pawn。
- **P1 工业顾问补全与 SDK 修复**：
  - [industrial_workforce.lua](PalIndustrialController/Scripts/industrial_workforce.lua) 修正 `DarkScorpion`/`CatMage`/`LeafMonkey`/`HadesBird` 种族 ID 错配；改用 `Pal.hpp` 实证接口 `APalCharacter:GetCharacterParameterComponent():GetLevel()` 读取玩家等级；帕鲁终端动态扫描全量槽位（默认 960，上限 1920）；`MonsterParameterDataTable` 过滤 `IsUncapturable`/Boss 并读取 `MeshCapsuleRadius` 体型；新增已拥有种族统计与同类 MOD 冲突探测（如 `PalWorkPriority`）。
  - [industrial_advisor.lua](PalIndustrialController/Scripts/industrial_advisor.lua) 扩展至最多 3 只图鉴推荐并标明「已拥有/未拥有」、大体型寻路惩罚、团队工种协同加分与高阶剧透隐藏；高级培养改为解析玩家真实帕鲁 `passives` 词条以识别已有优质配种亲本。
- **P2 指标、需求预测、岗位优化、多语言与交互式设置**：
  - [industrial_history.lua](PalIndustrialController/Scripts/industrial_history.lua) 接入实测入库产出、跨据点内部调拨去重后的估算消耗速率、平均提前期与真实设备利用率（%）。
  - 新增 [industrial_forecast.lua](PalIndustrialController/Scripts/industrial_forecast.lua)：默认关闭、可选开启的 EWMA 需求预测补货（含保底/上限钳制、冷启动回退固定目标与可信度标注）。
  - 新增 [industrial_workforce_opt.lua](PalIndustrialController/Scripts/industrial_workforce_opt.lua)：严格尊重 `OffWorkSuitabilityList` 锁定岗位、健康/SAN 限制与 120s 防震荡冷却的岗位优化建议引擎；检测到同类 MOD 时自动锁定只读防抢占。
  - 新增 [industrial_i18n.lua](PalIndustrialController/Scripts/industrial_i18n.lua)（`zh-CN` / `en-US` 独立语言包）；升级 [industrial_dashboard.lua](PalIndustrialController/Scripts/industrial_dashboard.lua) 与 [industrial_panel.lua](PalIndustrialController/Scripts/industrial_panel.lua) 支持交互式设置页、控件裁剪、自动换行与无重叠排版。
- **P3 模拟、全局规划、蓝图与开放扩展 API**：
  - 新增 [industrial_simulator.lua](PalIndustrialController/Scripts/industrial_simulator.lua)：只读 What-If 扩建/换帕鲁模拟（上游阻塞时拒绝虚报增益）、多据点全局发展规划与有界自适应调度反馈。
  - 新增 [industrial_blueprint.lua](PalIndustrialController/Scripts/industrial_blueprint.lua)：`Ctrl+B` 导出版本化工业蓝图（`PalIndustrialBlueprint\t1`），支持 fail-closed 校验导入与合并/覆盖。
  - 新增 [industrial_api.lua](PalIndustrialController/Scripts/industrial_api.lua)：通过 `_G.PalIndustrialControllerAPI`（`v1.0.0`）提供故障隔离的事件订阅、冲突声明、种族扩展与只读状态查询接口。
- **测试与验证**：全部 17 个 Lua 文件通过 `luac54 -p`（0 错误），[tests/run.lua](tests/run.lua) 扩展至 **22 项独立 Lua 5.4 回归测试全部通过**（含 7 页 UMG 布局校验与 P0/P1/P2/P3 全链路验证）；实机游戏内交互验收待后续在隔离存档执行。

## v0.3.0-rc.1

- **P0 加固与收尾**：
  - 设备快照新增供电状态（`UPalMapObjectEnergyModule`）、帕鲁路径可达性（`CannotApproachByWork`）与所需工种采集，规划器可直接识别缺电（`energy`）与路径受阻（`path`）。
  - 保留 `v0.2.0-rc.4` 的第二版任务日志持久化、人工核验标记（`?`）、跨据点动态增删及每轮共享配方解锁/禁用检查优化（实机 12 轮 A/B 对照中位数 `134.5 ms → 105.5 ms`）。
  - 补充缺电、路径受阻与目标仓满格拒绝调拨回归测试。
- **P1 帕鲁工业顾问（独立、可选、默认只读）**：
  - 新增 `industrial_workforce.lua`：仅在打开「帕鲁顾问」页签时按需读取各据点 `WorkerDirector` 在岗帕鲁（等级、星级、SAN、饱食、生病、睡眠、夜行、工作适应性与玩家手动关闭项 `OffWorkSuitabilityList`）及玩家帕鲁终端库存；绝不修改任何游戏对象、帕鲁或存档，故障自动隔离不影响核心调度。
  - 升级 `industrial_advisor.lua`：严格区分非劳动力阻塞（缺料、缺配方、缺电、满仓、寻路、人工核验）与真实劳动力瓶颈；优先建议调配玩家已有帕鲁（终端零机会成本优先，其次其他据点并标明机会成本，尊重玩家关闭的工种）；支持三种图鉴推荐策略（低成本 / 综合收益 / 极限产能，`Ctrl+E` 切换）与按需折叠的高级培养/词条/浓缩/配种建议（`Ctrl+D` 展开/折叠），不虚构捕获坐标或精确吞吐百分比。
- **P2 七页原创管理面板与趋势可视化**：
  - 在 `v0.2.0-rc.4` 核验基线上整合 `industrial_dashboard.lua`、`industrial_panel.lua`、`industrial_history.lua` 与 `main.lua`，恢复七页暗色工业面板（总览 / 库存 / 生产 / 物流 / 帕鲁顾问 / 统计 / 设置）。
  - `Ctrl+F9` / `Ctrl+Shift+F9` 双向切换页签，`PageUp` / `PageDown` 翻页；统计页新增基于真实连续样本的库存趋势条形图，不虚构产耗速率。
- **测试**：独立 Lua 5.4 回归扩展至 **17 项全部通过**；全量 9 个模块通过 `luac54 -p` 语法检查。

## v0.2.0-rc.4

- P0 持久化人工核验状态。订单所属据点或仓库集合改变，以及等待超时后，重启仍须手工接管。数量无法核验时，库存面板显示 `?`。
- 第二版任务日志兼容读取第一版。回滚所需的日志和存档配对方法见安装说明。

## v0.2.0-rc.3

- 将顾问和统计归到 Ctrl+F9 视图切换，避开实测中触发建造菜单和全屏切换的旧键位。
- P0 跨据点递归规划可在角色当前据点执行其他据点所需的上游工序。备选调拨来源按可调量选择，原版调拨需核验源、目标容器余额。
- P0 据点随公会的原版列表动态加入和退出。任务入库记录绑定自己的据点和仓库集合，防止其他据点新增或拆除影响其入库判断。
- P0 增加按存档和公会持久化的任务记录。在下单和调拨前记录意图，恢复时审查现有设备和仓库。遇到无法确认的执行结果时暂停并保留记录。库存目标格式兼容 v0.1.0。
- P0 分列库存、原版排队、设备待搬和待核验量。原版预检失败按设备配方或调拨路径有限重试。限制批量和调度步数，减少重复计划。
- P1 新增按需打开的只读工业顾问，展示可确认的材料、设备、供电、搬运或访问问题与检查建议。
- P2 在现有游戏内面板沿用原创色板，增加基于真实库存采样的有界净变化统计。完整的游戏内验收和开放能力范围见 [测试报告](docs/TEST_REPORT.md)。

## v0.1.0

- 初始版支持公会库存汇总、库存目标、普通仓库发现、跨据点原料调拨和角色所在据点的原版下单。

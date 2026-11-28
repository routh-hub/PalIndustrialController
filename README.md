# 帕鲁工业总控 · Pal Industrial Controller

《幻兽帕鲁》的 UE4SS Lua MOD。设定库存目标后，系统按公会已读取的据点、原版配方和设备规划递归补货，安排角色所在据点生产，并从同公会仓库调拨原料；内置七页全鼠标可点击原创 UMG 面板、按需读取的只读工业顾问、真实产耗趋势与需求预测、工业模拟、蓝图导出与开放扩展 API。

**v0.4.0-rc.2** 在 `v0.2.0-rc.4` 的 P0 持久化核验基线上完成 **P0/P1/P2/P3 功能整合 + 全鼠标交互 UMG 面板改造**：
- 按 `Ctrl+F10` 打开面板自动显示鼠标并锁定游戏内按键（防止误触攻击/建造/交互），点击左栏切页、右上角关闭并交还输入；
- 首页单一「启动补货 / 暂停补货」按钮，待核验时列出具体订单与「查看订单 → 确认接管」流程；
- 库存页直出搜索框与行内目标编辑器，设置页全部开关/选项与「导出蓝图」均可直接点击；
- 顾问页默认不自动读取在岗帕鲁与终端，避免触发已知崩溃；
- 代码层通过全部 **17 个 Lua 文件 `luac54 -p` 校验**、**22 项 Lua 5.4 回归测试** 与 **纯鼠标端到端流程模拟**；`v0.4.0-rc.2` 游戏内实机交互验收待隔离存档确认。

- [安装、升级、操作与回滚](PalIndustrialController/README.md)
- [兼容性、实现审查与测试报告](docs/TEST_REPORT.md)
- [开发交接清单](docs/HANDOFF.md)
- [变更日志](CHANGELOG.md)

## English

A UE4SS Lua mod for local host worlds in Palworld. Set stock targets, recursively plan multi-base supply chains, dispatch native production at the player's current base, and manage restock, production queues, cross-base transfers, read-only bottleneck advice, stock trends, forecasts, settings, and blueprints through a mouse-clickable 7-tab UMG dashboard (`Ctrl+F10`). `v0.4.0-rc.2` passes `luac54` checks on all 17 Lua files, 22 standalone Lua 5.4 regression tests, and a full mouse-only E2E harness; live in-game acceptance on an isolated save is queued next.

## 许可证 · License

[MIT](LICENSE)

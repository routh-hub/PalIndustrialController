# 帕鲁工业总控 · Pal Industrial Controller

《幻兽帕鲁》的 UE4SS Lua MOD，用于统计公会库存、设定补货目标，以及在游戏中调拨原料和下达生产订单。

- 汇总同一公会各据点的仓库库存、排队数量及设备上的待搬产物。
- 面板打开或自动补货运行时，每 8 秒扫描一次。刚建成的普通物品箱、兼容的配方设备和据点会加入统计，拆除后会移出。
- 库存目标按存档和公会保存。自动补货可跨据点调原料，并向角色所在据点的设备下单。

## 安装与使用

已验证 **Windows Steam《幻兽帕鲁》1.0.5.102999** 和 **UE4SS Experimental (Palworld) `2281fa31`**，适用于本地单人或房主世界。游戏中的面板为简体中文。

1. 订阅并在游戏的「选项 → 管理 MOD」中启用前置。 [UE4SS Experimental (Palworld)](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587)
2. 将安装包里的 `PalIndustrialController` 文件夹复制到游戏目录的 `Mods/NativeMods/UE4SS/Mods/`，然后重新启动游戏。保留文件夹内的 `enabled.txt`。
3. 进存档按 `Ctrl+F10` 打开面板，`Ctrl+F` 搜索物品，`Ctrl+G` 设置库存目标，`F4` 确认输入或切换自动补货。

支持范围及详细操作见 [使用说明](PalIndustrialController/README.md)。

## English

A Chinese-language UE4SS Lua mod for Palworld. It shows guild-wide inventory and lets a single-player or listen-server host set stock targets. It scans guild bases, ordinary storage chests, and compatible recipe stations every eight seconds while the panel or auto-restocking is active. Materials can be transferred between guild bases, and automatic production orders are issued at the player's current base.

Tested with Windows Steam Palworld **1.0.5.102999** and UE4SS Experimental (Palworld) **`2281fa31`**. Extract the `PalIndustrialController` folder into `Mods/NativeMods/UE4SS/Mods/`. In game, use `Ctrl+F10` to open the panel, `Ctrl+F` to search, `Ctrl+G` to edit a target, and `F4` to confirm or toggle auto-restocking.

## 许可证 · License

[MIT](LICENSE)

# 快捷键旧格式样本

`key-combos.json` 是当前 App 默认值或现有测试值按各自 Codable 形状保存的兼容样本，**不是用户导出文件**。只保留快捷键所在设置节，其他 App 业务设置不属于 Frit。来源和固定提交：

- Stox d97ddd9：`Sources/Stox/Hotkey.swift` 的 `HotkeyBinding.defaultToggle`；`SettingsStore.swift` 用 JSONEncoder 保存该对象到 `hotkey.toggle`。
- Proxi f765bf4：`Sources/Proxi/Models/AppConfig.swift` 的 `HotkeyBinding.defaultToggle` 和 `toggleHotkey`。
- Pop db38be6：`PopTests/ShortcutAndWindowTests.swift` 中现有 `pluginHotKeys` JSON 的有效项；测试同时验证 `AppSettings` 的编码/解码。
- Meno 51c1186：`Tests/MenoCoreTests/SettingsTests.swift` 的 `quickOpen` 绑定（⌃⌥S）；`KeyModifiers` 的合成 Codable 对象保存紧凑 rawValue。

测试会用对应原 Codable 形状复现这些值，再与固定样本比较，防止把 Carbon 位误当成紧凑位。实际用户设置导出样本尚未提供。

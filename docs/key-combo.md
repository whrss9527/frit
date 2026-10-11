# 快捷键数据模型

`FritCore.KeyCombo` 以 Meno 的 Foundation 模型为底。业务动作、插件 ID、菜单栏项目和冲突集合仍由各 App 保存。`KeyCodeNames` 提供 ANSI 默认名称和布局无关的功能/特殊键；实际键盘布局由 FritSystem 处理。

`KeyModifiers` 内部依次用 1、2、4、8 表示 control、option、shift、command。`carbonFlags` 与 `init(carbonFlags:)` 双向转换 Carbon 的 4096、2048、512、256；Caps Lock、Fn 等非这四种修饰键不参与转换。

JSON 解码接受 Meno 的 `{"rawValue":3}` 对象，以及旧 Stox、Proxi、Pop 的标量。数值 ≥ 256 按 Carbon 位解释，较小数值按紧凑位解释。额外的 `display` 字段会忽略，显示文字由模型和当前键盘布局重新产生。编码继续写 Meno 既有的对象格式，避免旧版 Meno 读不懂新设置；切换旧 Carbon 模型的 App 时，应连同读写一起替换，而不是让旧版 Carbon App 继续读取新格式。

`problem(osMajorVersion:minimum:)` 默认 `.commandOptionOrControl`，普通键要求 ⌘、⌥ 或 ⌃，F1–F20 可以单独用。`.any` 允许 Shift 组合；`.commandOrControl` 即使功能键也要求 ⌘ 或 ⌃。所有策略都遵守 macOS 15 开始只带 Option（含 Option+Shift）不能注册的系统限制。函数只返回问题，不请求权限或注册快捷键。

来源：Meno `Sources/MenoCore/Settings/KeyCombo.swift` 的模型、键名和 `Tests/MenoCoreTests/SettingsTests.swift` 的测试（51c1186）；对照 Stox `Sources/Stox/Hotkey.swift`（d97ddd9）、Proxi `Sources/Proxi/Models/AppConfig.swift` 和 `System/Hotkeys.swift`（f765bf4）、Pop `Pop/System/KeyCombo.swift` 与 `PopTests/ShortcutAndWindowTests.swift`（db38be6）。兼容样本的出处及限制见 [测试说明](../Tests/FritCoreTests/Fixtures/README.md)。

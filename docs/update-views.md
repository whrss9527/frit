# 更新条和更新区

```swift
import FritCore
import FritUpdate

UpdateBanner(updater: updater, openDetails: { showAbout = true })
UpdateSection(updater: updater, pageURLOpener: { NSWorkspace.shared.open($0) })
```

组件只提供内容、字体和内部间距。卡片或玻璃背景由 App 包装，不依赖 FritUI。公共视图覆盖所有 Phase，包含大小未知的下载、线路说明、校验、安装、重启、错误、跳过、手动下载、App 管理设置入口和搬到应用程序的说明。Pop 的 Form 更新页与 Meno 的 AboutPane 保留在 App，只接公共数据源。

App 改界面语言时设置 `FritLocalization.languageOverride = "en"` 或 `"zh-Hans"`，跟随系统时设为 nil。钩子位于 FritCore，线程安全；视图观察变化，在运行时重选模块 lproj。不会更改 AppleLanguages，不依赖 Foundation 缓存失效；`en-US` 会回退到 en。日期使用对应 Locale，错误描述每次读取都按当前语言生成。

文案唯一来源为 `Sources/FritUpdate/Resources/Localizable.xcstrings`，源语言 zh-Hans，提供 en。`scripts/generate-localizations.py` 同步产生两份 lproj/Localizable.strings；catalog 作为编写源排除出构建，避免 Xcode 同时编译它和生成资源造成重复输出。字符串用 `String(localized:bundle: .module)` 或显式覆盖的模块语言包读取，原生 SwiftPM 与 Xcode 后端使用同一份译文。改文案后运行生成脚本；`--check` 校验代码键、两种译文、占位符和生成结果，CI 会检查。

## 预览 Sample.app

在 macOS 上执行 `bash Examples/UpdateSample/make-app.sh`，然后 `open dist/UpdateSample.app`。切换状态依次检查未检查、检查中、最新、跳过、可用、两种下载、校验、安装、重启、校验失败、App 管理拦截；下方显示搬家说明。切换语言无需重启 App。

`Updater.preview(configuration:phase:lastChecked:)` 用于 Sample 与 SwiftUI 预览。这种对象的网络检查和安装入口不会执行；可以安全点击组件按钮。需要真实安装的测试使用普通 Updater，见 `MacUpdateTests`，Sample 完整更新 e2e 在 #22 中扩展。

来源：Stox `Sources/Stox/UpdateViews.swift` 与 `Resources/{en,zh-Hans}.lproj/Localizable.strings`（d97ddd9），对照 Proxi 同名 UI 和语言文件（f765bf4）。App 专有的“自选”提示改为公共的“设置和数据”，外层 glassCard 留给 App。

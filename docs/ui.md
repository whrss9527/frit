# 公共界面组件

`FritUI` 是独立产品，仅在 macOS 导出界面 API，最低 macOS 13。不自动安装监听、创建窗口或改动外观设置。四个 App 的接入分别开 PR，对比各自已有截图；发布这个模块不代表 App 已迁移。

```swift
import FritUI
import SwiftUI

Text("内容").padding().fritGlass(in: Capsule(), tint: .blue)
Text("卡片").padding().fritGlassCard(cornerRadius: 14, prominent: true)
Text("浮窗").padding().fritGlassSurface(RoundedRectangle(cornerRadius: 20))
Button("确定") {}.buttonStyle(FritGlassButtonStyle(prominent: true))
```

三种表面保留原样式差异：`fritGlass(in:tint:interactive:clear:)` 来自 Meno，旧系统包含渐变、阴影及高对比度边框；`fritGlassCard(cornerRadius:prominent:)` 来自 Stox/Proxi，旧系统使用材质和细边；`fritGlassSurface(_:tint:)` 来自 Pop，旧系统使用窗口后模糊。所有新玻璃 API 同时检查编译器 6.2 和 macOS 26。Meno 的圆角卡片可以用第一种入口传入圆角矩形，不把不同表面机械统一。

`GlassGroup(spacing:content:)` 组合玻璃；`FritGlassButtonStyle` 与 `View.fritGlassButtonStyle(prominent:)` 均保留新系统原生按钮和旧系统磨砂按钮。`HoverRowStyle`、`IconButtonStyle` 来自 Stox；`VisualEffectBackground(material:blending:cornerRadius:)` 提供可更新材质、混合方式及圆角遮罩。

`FloatingPanel(level:)` 默认不接收键盘焦点，不成为主窗口；需要输入时设置 `allowsKey = true`，把 `FirstMouseHostingView(rootView:)` 作为内容。`pinned` 调整拖动及层级，取消钉住后恢复 `unpinnedLevel`。`onResignKey` 始终通知调用方，是否隐藏由 App 按钉住状态决定。`onEscape` 返回 true 可先处理内部搜索；未处理时执行 `onClose`，没有回调则关闭面板。`keyEquivalentHandler` 接收未组字的 keyDown，方向键、修饰键及导航策略由 App 决定；组字期间不交给导航或关闭钩子。

面板直接转发当前文本编辑器的 ⌘X/C/V/A/Z 与 ⌘⇧Z；不会把编辑动作发给其他窗口。无 Edit 菜单的 App 可显式调用 `TextEditingShortcuts.install()`，在销毁时 `uninstall()`。快捷键录入会话持有 `isSuspended` 的恢复责任，库不会自动接管四 App 不同的录入生命周期。

不包含 AuroraBackground、ColorDot、SelectionHighlight、Theme、Pop 的 Motion 或诊断开关，也不声明四 App 的默认外观已相同。

UI CI 在临时托管 Mac 中创建自己的窗口，通过合成器截取并拒绝空白图片，普通单测不请求个人会话的屏幕录制。指定 AppKit 的四种外观不等于切换系统“提高对比度”；附件的 JSON 单独记录真实系统开关。系统辅助功能设置随实际会话验证，不根据文件名冒充通过。

来源：`meno@935888e` 的 `Sources/Meno/UI/Glass/Glass.swift`、`Support/TextEditingShortcuts.swift`；`stox@53deb79` 的 `Sources/Stox/Glass.swift`、`PanelWindow.swift`；`pop@137efa3` 的 `Pop/UI/Glass.swift`。公共化时补充显式初始化、可移除监听、文本编辑器目标和输入法保护。

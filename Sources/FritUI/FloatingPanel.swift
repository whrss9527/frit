#if os(macOS)
// 来源：meno@935888e Sources/Meno/UI/Glass/Glass.swift；事件/钉住来自 stox@53deb79 Sources/Stox/PanelWindow.swift。
import AppKit
import SwiftUI

/// 面板没有成为主窗口时也能响应第一次点击。
public final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 透明、不激活 App 的浮动面板；是否可输入、关闭和导航由调用方控制。
open class FloatingPanel: NSPanel {
    public var allowsKey = false
    public var onResignKey: (() -> Void)?
    /// 返回 true 表示内部已处理 Esc（例如清空搜索），否则执行 onClose 或 close。
    public var onEscape: (() -> Bool)?
    public var onClose: (() -> Void)?
    /// 在 sendEvent 中拦截未组字的 keyDown；导航键及修饰键策略由 App 判断。
    public var keyEquivalentHandler: ((NSEvent) -> Bool)?
    public var unpinnedLevel: NSWindow.Level = .statusBar {
        didSet { if !pinned { level = unpinnedLevel } }
    }
    public var pinned = false {
        didSet {
            isMovable = pinned
            isMovableByWindowBackground = pinned
            level = pinned ? .floating : unpinnedLevel
        }
    }

    public override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                         backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        isMovable = false
        level = unpinnedLevel
    }

    public override convenience init() {
        self.init(level: .statusBar)
    }

    public convenience init(level: NSWindow.Level) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        unpinnedLevel = level
    }

    open override var canBecomeKey: Bool { allowsKey }
    open override var canBecomeMain: Bool { false }

    open override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    private var isComposingText: Bool {
        (firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    open override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !isComposingText, keyEquivalentHandler?(event) == true { return }
        super.sendEvent(event)
    }

    open override func cancelOperation(_ sender: Any?) {
        guard !isComposingText, onEscape?() != true else { return }
        if let onClose { onClose() } else { close() }
    }

    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if TextEditingShortcuts.handle(event, in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
#endif

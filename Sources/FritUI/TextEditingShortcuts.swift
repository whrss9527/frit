#if os(macOS)
// 来源：meno@935888e Sources/Meno/Support/TextEditingShortcuts.swift；编辑动作限定到当前窗口的文本编辑器。
import AppKit

/// 无菜单栏的程序可选择安装本地监听；浮动面板不需要全局安装。
@MainActor
public enum TextEditingShortcuts {
    private static var monitor: Any?
    /// 快捷键录入期间由调用方暂停，结束后由同一个录入会话恢复。
    public static var isSuspended = false

    public static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) ? nil : event }
        }
    }

    public static func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// 仅处理文本编辑器的标准编辑组合键；不把动作发送给其他窗口或 App 功能。
    @discardableResult
    public static func handle(_ event: NSEvent, in window: NSWindow? = nil) -> Bool {
        guard !isSuspended, event.type == .keyDown,
              let window = window ?? NSApp.keyWindow,
              let editor = window.firstResponder as? NSTextView,
              !editor.hasMarkedText(),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: Selector
        if flags == [.command, .shift], key == "z" {
            action = Selector(("redo:"))
        } else if flags == .command {
            switch key {
            case "x": action = #selector(NSText.cut(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            default: return false
            }
        } else {
            return false
        }
        return NSApp.sendAction(action, to: editor, from: window)
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import FritUI

@MainActor
final class PanelTests: XCTestCase {
    private func panel() -> FloatingPanel {
        _ = NSApplication.shared
        let panel = FloatingPanel(level: .popUpMenu)
        panel.allowsKey = true
        return panel
    }

    private func event(_ key: String, flags: NSEvent.ModifierFlags = [], window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
    }

    private func editor(in panel: FloatingPanel) -> NSTextView {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        editor.isEditable = true
        editor.allowsUndo = true
        panel.contentView = editor
        XCTAssertTrue(panel.makeFirstResponder(editor))
        return editor
    }

    func testFirstClickAndPanelFocusAreExplicit() {
        _ = NSApplication.shared
        let panel = FloatingPanel()
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.hidesOnDeactivate)
        panel.allowsKey = true
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(FirstMouseHostingView(rootView: Text("首击")).acceptsFirstMouse(for: nil))
    }

    func testPinningRestoresConfiguredLevelAndDoesNotSuppressFocusCallback() {
        let panel = panel()
        defer { panel.close() }
        var resigns = 0
        panel.onResignKey = { resigns += 1 }
        panel.pinned = true
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        panel.unpinnedLevel = .statusBar
        XCTAssertEqual(panel.level, .floating)
        panel.resignKey()
        XCTAssertEqual(resigns, 1)
        panel.pinned = false
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertFalse(panel.isMovable)
    }

    func testCompositionKeepsEscapeAndNavigationWithTextInput() throws {
        let panel = panel()
        defer { panel.close() }
        let editor = editor(in: panel)
        var escapes = 0
        var closes = 0
        var navigation = 0
        panel.onEscape = { escapes += 1; return true }
        panel.onClose = { closes += 1 }
        panel.keyEquivalentHandler = { _ in navigation += 1; return true }
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        panel.sendEvent(try event("\u{f701}", window: panel))
        XCTAssertEqual(navigation, 0)
        panel.cancelOperation(nil)
        XCTAssertEqual(escapes, 0)
        XCTAssertEqual(closes, 0)
        XCTAssertFalse(TextEditingShortcuts.handle(try event("a", flags: .command, window: panel), in: panel))
        // 组字结束后，同一 App 导航钩子才恢复。
        editor.unmarkText()
        panel.sendEvent(try event("\u{f701}", window: panel))
        XCTAssertEqual(navigation, 1)
        panel.cancelOperation(nil)
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(closes, 0)
        panel.onEscape = { false }
        panel.cancelOperation(nil)
        XCTAssertEqual(closes, 1)
    }

    func testEditingTargetsOwnTextViewAndRespectsRecorderSuspension() throws {
        let panel = panel()
        defer { panel.close(); TextEditingShortcuts.isSuspended = false }
        let editor = editor(in: panel)
        editor.string = "hello 中文"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let selectAll = try event("a", flags: [.command, .capsLock], window: panel)
        XCTAssertTrue(panel.performKeyEquivalent(with: selectAll))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        TextEditingShortcuts.isSuspended = true
        XCTAssertFalse(TextEditingShortcuts.handle(selectAll, in: panel))
        XCTAssertEqual(editor.selectedRange().length, 0)
        TextEditingShortcuts.isSuspended = false
        let combinations: [NSEvent.ModifierFlags] = [[.command, .option], [.command, .control], [.command, .shift], []]
        for flags in combinations {
            XCTAssertFalse(TextEditingShortcuts.handle(try event("a", flags: flags, window: panel), in: panel))
        }
        panel.makeFirstResponder(nil)
        XCTAssertFalse(TextEditingShortcuts.handle(selectAll, in: panel))
    }

    func testUndoAndRedoReachTextEditorWithoutAnEditMenu() throws {
        let panel = panel()
        defer { panel.close() }
        let editor = editor(in: panel)
        editor.string = "original"
        editor.insertText("!", replacementRange: NSRange(location: 8, length: 0))
        editor.breakUndoCoalescing()
        XCTAssertEqual(editor.string, "original!")
        XCTAssertTrue(TextEditingShortcuts.handle(try event("z", flags: .command, window: panel), in: panel))
        XCTAssertEqual(editor.string, "original")
        XCTAssertTrue(TextEditingShortcuts.handle(try event("z", flags: [.command, .shift], window: panel), in: panel))
        XCTAssertEqual(editor.string, "original!")
        editor.undoManager?.removeAllActions()
        XCTAssertTrue(TextEditingShortcuts.handle(try event("z", flags: .command, window: panel), in: panel))
        XCTAssertEqual(editor.string, "original!")
    }
}
#endif

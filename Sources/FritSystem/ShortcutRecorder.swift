import AppKit
import FritCore
import SwiftUI

// MARK: - Coordinator protocol

/// The app-side coordinator that the shortcut recorder needs.
///
/// Implement this protocol on an `ObservableObject` that owns the app's
/// hot keys and pass it as `coordinator` to `ShortcutRecorder`.
@MainActor
public protocol ShortcutRecording: AnyObject {
    /// An opaque identifier for the currently-recording shortcut recorder,
    /// or `nil` when no recorder is active. The app must publish change
    /// notifications so that a second recorder opened while one is already
    /// recording can stop itself.
    var activeRecorderID: UUID? { get set }

    /// The major version of the running OS, used to validate modifier
    /// requirements.
    var osMajorVersion: Int { get }

    /// Temporarily unregister all of the app's own shortcuts so they can
    /// be re-recorded.
    func suspendHotkeys()

    /// Re-register all of the app's shortcuts after recording stops.
    func restoreHotkeys()

    /// Returns `true` when `combo` conflicts with another shortcut already
    /// registered by this app.
    func isHotkeyInConflict(_ combo: KeyCombo) -> Bool

    /// Returns `true` when `combo` was previously refused by macOS (another
    /// app owns it).
    func isHotkeyRefused(_ combo: KeyCombo) -> Bool

    /// Called when a new shortcut is recorded. The implementation should
    /// persist it and re-register.
    func didRecord(_ combo: KeyCombo?)
}

// MARK: - View

/// Records a global keyboard shortcut in a SwiftUI button.
///
/// While recording, the app's own shortcuts are suspended so that pressing
/// an already-registered shortcut can be re-captured. Recording stops when
/// the app resigns active status or another recorder starts.
///
/// Usage:
/// ```swift
/// ShortcutRecorder(
///     combo: $settings.shortcut,
///     minimum: .commandOptionOrControl,
///     purpose: "Toggle proxy",
///     coordinator: appModel
/// )
/// ```
public struct ShortcutRecorder<Coordinator: ShortcutRecording>: View {
    @Binding var combo: KeyCombo?

    /// The minimum modifier keys that must be held. Proxi uses
    /// `.commandOrControl`; Pop allows `.any`; Stox and Meno use
    /// `.commandOptionOrControl`.
    public var minimum: ModifierRequirement

    /// A short description of what the shortcut does, exposed to VoiceOver.
    public var purpose: String?

    /// The app-side coordinator.
    @ObservedObject var coordinator: Coordinator

    @State private var id = UUID()
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var problem: KeyCombo.Problem?

    public init(
        combo: Binding<KeyCombo?>,
        minimum: ModifierRequirement = .commandOptionOrControl,
        purpose: String? = nil,
        coordinator: Coordinator
    ) {
        self._combo = combo
        self.minimum = minimum
        self.purpose = purpose
        self.coordinator = coordinator
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(verbatim: label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 120)
                    .foregroundStyle(labelColor)
            }
            .buttonStyle(.borderedProminent)
            .tint(isRecording ? .accentColor : .secondary)
            .help(helpText)
            .accessibilityLabel(purpose.map { Text("Shortcut for \($0)") } ?? Text("Shortcut"))
            .accessibilityValue(Text(verbatim: label))

            if combo != nil, !isRecording {
                Button {
                    combo = nil
                    coordinator.didRecord(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Remove shortcut"))
                .accessibilityLabel(Text("Remove shortcut"))
            }
        }
        .onDisappear(perform: stop)
        .onChange(of: coordinator.activeRecorderID) {
            if isRecording, coordinator.activeRecorderID != id {
                stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stop()
        }
    }

    // MARK: - Label & feedback

    private var label: String {
        if isRecording {
            switch problem {
            case .needsModifier:
                return String(localized: "Add ⌘, ⌥ or ⌃", bundle: .module, comment: "Shortcut recorder prompt")
            case .needsCommandOrControl:
                return String(localized: "Add ⌘ or ⌃", bundle: .module, comment: "Shortcut recorder prompt")
            case nil:
                return String(localized: "Type a shortcut…", bundle: .module, comment: "Shortcut recorder prompt")
            }
        }
        if let combo {
            return KeyboardLayout.displayString(for: combo)
        }
        return String(localized: "Record Shortcut", bundle: .module, comment: "Shortcut recorder button")
    }

    private var labelColor: Color {
        if problem != nil { return .red }
        if isRefused || isUsedTwice { return .orange }
        return .primary
    }

    private var helpText: Text {
        if isRefused {
            return Text("macOS did not accept this shortcut. Another app may already use it.")
        }
        if isUsedTwice {
            return Text("This shortcut is assigned more than once. Only one copy will work.")
        }
        return Text(verbatim: "")
    }

    private var isUsedTwice: Bool {
        guard let combo, !isRecording else { return false }
        return coordinator.isHotkeyInConflict(combo)
    }

    private var isRefused: Bool {
        guard let combo, !isRecording else { return false }
        return coordinator.isHotkeyRefused(combo)
    }

    // MARK: - Recording lifecycle

    private func start() {
        coordinator.activeRecorderID = id
        isRecording = true
        problem = nil
        coordinator.suspendHotkeys()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
        self.monitor = monitor as Any?
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        self.monitor = nil
        guard isRecording else { return }
        isRecording = false
        problem = nil
        guard coordinator.activeRecorderID == id else { return }
        coordinator.activeRecorderID = nil
        coordinator.restoreHotkeys()
    }

    private func handle(_ event: NSEvent) {
        let modifiers = KeyboardLayout.modifiers(from: event.modifierFlags)
        if modifiers.isEmpty {
            switch event.keyCode {
            case 0x35: // Escape — cancel recording
                stop()
                return
            case 0x33, 0x75: // Delete, Forward Delete — clear shortcut
                combo = nil
                coordinator.didRecord(nil)
                stop()
                return
            default:
                break
            }
        }
        let candidate = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        if let problem = candidate.problem(osMajorVersion: coordinator.osMajorVersion, minimum: minimum) {
            self.problem = problem
            NSSound.beep()
            return
        }
        combo = candidate
        coordinator.didRecord(candidate)
        stop()
    }
}
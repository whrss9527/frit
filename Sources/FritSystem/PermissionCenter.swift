import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

/// Tracks and requests the privacy permissions an app depends on.
///
/// Meno base + Pop `revealApp`. Accessibility is the primary permission;
/// Screen Recording is optional. Polling is adaptive: 1 s while
/// Accessibility is missing so that the grant takes effect immediately,
/// 10 s once granted.
///
/// In a sandboxed app the system permission prompt does not appear
/// automatically; use `revealApp()` so the user can drag the app into
/// the Accessibility list.
@MainActor
public final class PermissionCenter: ObservableObject {
    @Published public private(set) var accessibility: Bool
    @Published public private(set) var screenRecording: Bool
    /// Set once Screen Recording was granted while the app was running;
    /// macOS applies it only after a relaunch.
    @Published public private(set) var screenRecordingNeedsRelaunch = false
    /// Whether Accessibility was granted at some point before. After an
    /// update, the System Settings entry may still be on but belong to
    /// the previous build.
    @Published public private(set) var accessibilityWasGranted: Bool

    private var pollTask: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?
    private let grantedAtLaunch: Bool
    private let isSandboxed: Bool
    private let accessibilityWasGrantedKey: String

    /// Called immediately after `accessibility` flips from `false` to `true`.
    public var onAccessibilityGranted: (() -> Void)?

    /// Whether Screen Recording captures work right now (granted and not
    /// pending a relaunch).
    public var canCapture: Bool {
        screenRecording && !screenRecordingNeedsRelaunch
    }

    /// Accessibility was granted before but the current build is no longer
    /// trusted — typically after an update.
    public var needsAccessibilityAgain: Bool {
        !accessibility && accessibilityWasGranted
    }

    /// - Parameters:
    ///   - accessibilityWasGrantedKey: `UserDefaults` key that persists
    ///     whether the permission was ever granted.
    ///   - isSandboxed: If `true`, the system permission prompt is skipped
    ///     and `revealApp()` is recommended instead.
    public init(
        accessibility: Bool? = nil,
        screenRecording: Bool? = nil,
        accessibilityWasGranted: Bool? = nil,
        accessibilityWasGrantedKey: String = "Frit.AccessibilityWasGranted",
        isSandboxed: Bool = false
    ) {
        self.accessibility = accessibility ?? AXIsProcessTrusted()
        let capture = screenRecording ?? CGPreflightScreenCaptureAccess()
        self.screenRecording = capture
        grantedAtLaunch = capture
        self.accessibilityWasGranted = accessibilityWasGranted
            ?? UserDefaults.standard.bool(forKey: accessibilityWasGrantedKey)
        self.isSandboxed = isSandboxed
        self.accessibilityWasGrantedKey = accessibilityWasGrantedKey
    }

    // MARK: - Monitoring

    /// Starts adaptive polling and an active-app observer. Safe to call
    /// multiple times.
    public func startMonitoring() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                let seconds: UInt64 = self.accessibility ? 10 : 1
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000 + 500_000_000)
            }
        }
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
    }

    /// Queries the current permission state. Called automatically by the
    /// polling loop; call directly after a user-facing permission action.
    public func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility {
            accessibility = trusted
            if trusted { onAccessibilityGranted?() }
        }
        if trusted, !accessibilityWasGranted {
            accessibilityWasGranted = true
            UserDefaults.standard.set(true, forKey: accessibilityWasGrantedKey)
        }
        let capture = CGPreflightScreenCaptureAccess()
        if capture != screenRecording {
            screenRecording = capture
        }
        let needsRelaunch = capture && !grantedAtLaunch
        if needsRelaunch != screenRecordingNeedsRelaunch {
            screenRecordingNeedsRelaunch = needsRelaunch
        }
    }

    // MARK: - Actions

    /// Shows the system Accessibility permission prompt.
    /// In a sandboxed app this prompt does not appear; direct the user to
    /// drag the app into the list instead.
    public func requestAccessibility() {
        guard !isSandboxed else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open(.accessibility)
        }
    }

    /// Shows the system Screen Recording permission prompt.
    public func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open(.screenRecording)
        }
    }

    /// Removes the app from the Accessibility list via `tccutil` and
    /// re-prompts, so macOS registers the current build.
    /// Returns whether the entry was removed.
    @discardableResult
    public func resetAccessibility() async -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let removed = await Self.run("/usr/bin/tccutil", arguments: ["reset", "Accessibility", bundleID])
        requestAccessibility()
        return removed
    }

    /// Opens the app's location in Finder so the user can drag it into the
    /// Accessibility list (useful for sandboxed / App Store builds).
    public func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: - Private

    private static func run(_ path: String, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func open(_ pane: Pane) {
        let anchor: String
        switch pane {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private enum Pane {
        case accessibility
        case screenRecording
    }
}
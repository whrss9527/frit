import AppKit
import Carbon.HIToolbox
import FritCore

/// Registers system-wide keyboard shortcuts through the Carbon hot key API,
/// which does not require Accessibility permission.
///
/// Meno base (`register` returns `Bool`) with Proxi's id-based overwrite:
/// calling `register` with the same `id` replaces the previous registration
/// for that id without leaking the old hot key.
@MainActor
public final class HotkeyCenter {
    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private let signature: OSType

    /// - Parameter signature: A unique four-character code identifying this
    ///   app's hot keys. Prevents collisions when several apps run side by
    ///   side. Use `FourCharCode` for readable literals.
    public init(signature: OSType) {
        self.signature = signature
    }

    // MARK: - Registration

    /// Registers a global shortcut. If `id` is provided and a shortcut is
    /// already registered under that id, it is replaced atomically.
    ///
    /// - Returns: `true` when the OS accepted the registration, `false` if
    ///   another app already owns this combination.
    @discardableResult
    public func register(_ combo: KeyCombo, id: UInt32? = nil, action: @escaping () -> Void) -> Bool {
        install()
        let id = id ?? nextAvailableID()
        // Replace existing registration under the same id.
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers.carbonFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == OSStatus(noErr), let ref else { return false }
        registrations[id] = ref
        actions[id] = action
        return true
    }

    /// Removes the hot key registered under `id`. Safe to call with an
    /// unknown id.
    public func unregister(id: UInt32) {
        guard let ref = registrations.removeValue(forKey: id) else { return }
        actions.removeValue(forKey: id)
        _ = UnregisterEventHotKey(ref)
    }

    /// Removes every registered hot key.
    public func unregisterAll() {
        for ref in registrations.values {
            _ = UnregisterEventHotKey(ref)
        }
        registrations.removeAll()
        actions.removeAll()
    }

    // MARK: - Private

    private func nextAvailableID() -> UInt32 {
        // Start at 1; find the lowest gap.
        var candidate: UInt32 = 1
        while registrations[candidate] != nil {
            candidate += 1
        }
        return candidate
    }

    private func install() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status != OSStatus(noErr) {
            // The handler is installed once; if it fails here the app
            // cannot register global shortcuts at all.
            assertionFailure("HotkeyCenter: InstallEventHandler failed with \(status)")
        }
    }

    fileprivate func handle(id: UInt32) {
        guard let action = actions[id] else { return }
        action()
    }
}

// MARK: - Carbon event callback

private let hotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == OSStatus(noErr) else { return status }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        center.handle(id: id)
    }
    return OSStatus(noErr)
}
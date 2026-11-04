import Foundation

/// 统一使用紧凑的四位；读取旧设置时兼容 Carbon 位。
public struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    public init(carbonFlags: UInt32) {
        var value: KeyModifiers = []
        if carbonFlags & (1 << 8) != 0 { value.insert(.command) }
        if carbonFlags & (1 << 9) != 0 { value.insert(.shift) }
        if carbonFlags & (1 << 11) != 0 { value.insert(.option) }
        if carbonFlags & (1 << 12) != 0 { value.insert(.control) }
        self = value
    }
    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= 1 << 8 }
        if contains(.shift) { flags |= 1 << 9 }
        if contains(.option) { flags |= 1 << 11 }
        if contains(.control) { flags |= 1 << 12 }
        return flags
    }
    public var symbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }

    private enum CodingKeys: String, CodingKey { case rawValue }
    public init(from decoder: Decoder) throws {
        let scalar = try decoder.singleValueContainer()
        let value: UInt32
        if let number = try? scalar.decode(UInt32.self) { value = number }
        else { value = try decoder.container(keyedBy: CodingKeys.self).decode(UInt32.self, forKey: .rawValue) }
        self = value >= 1 << 8 ? KeyModifiers(carbonFlags: value) : KeyModifiers(rawValue: value)
    }
    /// 保持 Meno 既有的对象格式，旧版 Meno 也能读取新设置。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

public enum ModifierRequirement: Sendable {
    /// Stox：允许任意修饰键；普通裸键仍然不能用于全局快捷键。
    case any
    /// Meno / Pop：至少 ⌘、⌥ 或 ⌃；功能键可以单独使用。
    case commandOptionOrControl
    /// Proxi：即使是功能键也要求 ⌘ 或 ⌃。
    case commandOrControl
}

/// 按硬件键码和修饰键识别；旧设置的 display 只作显示，不参与数据模型。
public struct KeyCombo: Hashable, Codable, Sendable {
    public var keyCode: UInt32
    public var modifiers: KeyModifiers
    public init(keyCode: UInt32, modifiers: KeyModifiers) { self.keyCode = keyCode; self.modifiers = modifiers }
    public enum Problem: Hashable, Sendable { case needsModifier, needsCommandOrControl }

    public func problem(osMajorVersion: Int, minimum: ModifierRequirement = .commandOptionOrControl) -> Problem? {
        let primary = modifiers.intersection([.command, .control])
        if minimum == .commandOrControl, primary.isEmpty { return .needsCommandOrControl }
        if osMajorVersion >= 15, primary.isEmpty, modifiers.contains(.option) { return .needsCommandOrControl }
        let meaningful = minimum == .any ? modifiers.intersection([.control, .option, .shift, .command])
            : modifiers.intersection([.control, .option, .command])
        if meaningful.isEmpty, !KeyCodeNames.isFunctionKey(keyCode) { return .needsModifier }
        return nil
    }
    public func displayString(keyName: String? = nil) -> String {
        modifiers.symbols + (keyName ?? KeyCodeNames.name(for: keyCode) ?? "#\(keyCode)")
    }
}

/// ANSI（美式）键盘的键名与布局无关的特殊键。
public enum KeyCodeNames {
    public static func name(for keyCode: UInt32) -> String? {
        names[keyCode]
    }

    public static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeys.contains(keyCode)
    }

    /// 功能键和特殊键不受当前键盘布局影响，始终使用这份名称表。
    public static func isLayoutIndependent(_ keyCode: UInt32) -> Bool {
        layoutIndependent.contains(keyCode)
    }

    private static let functionKeys: Set<UInt32> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    private static let layoutIndependent: Set<UInt32> = functionKeys.union([
        0x24, 0x30, 0x31, 0x33, 0x35, 0x75, 0x73, 0x77, 0x74, 0x79,
        0x7B, 0x7C, 0x7D, 0x7E, 0x4C, 0x47, 0x72,
    ])

    private static let names: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",",
        0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        0x41: "Keypad .", 0x43: "Keypad *", 0x45: "Keypad +", 0x4B: "Keypad /",
        0x4E: "Keypad -", 0x51: "Keypad =", 0x52: "Keypad 0", 0x53: "Keypad 1",
        0x54: "Keypad 2", 0x55: "Keypad 3", 0x56: "Keypad 4", 0x57: "Keypad 5",
        0x58: "Keypad 6", 0x59: "Keypad 7", 0x5B: "Keypad 8", 0x5C: "Keypad 9",
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟", 0x7B: "←", 0x7C: "→",
        0x7D: "↓", 0x7E: "↑", 0x4C: "⌤", 0x47: "⌧", 0x72: "Help",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18",
        0x50: "F19", 0x5A: "F20",
    ]
}


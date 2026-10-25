import Foundation

/// App 自己保留字段合并和未知数据规则；这里只约定文档外形与首次合并入口。
public protocol SyncContent: Codable, Equatable, Sendable {
    static var format: Int { get }
    static var contentKey: String { get }
    var isEmptyForSync: Bool { get }
    func merging(cloud: Self) -> Self
}

public extension SyncContent {
    static var contentKey: String { "content" }
}

public enum SyncDocumentError: Error, Equatable, Sendable {
    case newerFormat(Int)
    case invalidContentKey(String)
}

private let unknownSyncDevice = CodingUserInfoKey(rawValue: "FritCore.SyncDocument.unknownDevice")!

/// 来源：stox@5e54ee1 Sources/StoxCore/Sync.swift；config 键兼容 Proxi 的旧文档。
public struct SyncDocument<Content: SyncContent>: Codable, Equatable, Sendable {
    public var format: Int
    public var updatedAt: Date
    public var device: String
    public var content: Content
    /// 类型级只读配置，避免两个 Engine 或并发编解码修改同一个全局键。
    public static var contentKey: String { Content.contentKey }

    public init(format: Int? = nil, updatedAt: Date, device: String, content: Content) {
        self.format = format ?? Content.format
        self.updatedAt = updatedAt
        self.device = device
        self.content = content
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data, unknownDevice: String = "") throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[unknownSyncDevice] = unknownDevice
        return try decoder.decode(Self.self, from: data)
    }

    /// 按时间、设备名选择；同时间同设备保留先出现者，业务冲突由后续协调层处理。
    public static func newest(_ candidates: [Self]) -> Self? {
        candidates.reduce(nil) { selected, candidate in
            guard let selected else { return candidate }
            if candidate.updatedAt > selected.updatedAt
                || (candidate.updatedAt == selected.updatedAt && candidate.device > selected.device) {
                return candidate
            }
            return selected
        }
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func payloadKey() throws -> Key {
        let key = contentKey
        guard !key.isEmpty, !["format", "updatedAt", "device"].contains(key) else {
            throw SyncDocumentError.invalidContentKey(key)
        }
        return Key(key)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        // 没有版本头的旧文件是 format1，不随当前支持版本升级而改义。
        format = try container.decodeIfPresent(Int.self, forKey: Key("format")) ?? 1
        guard format <= Content.format else { throw SyncDocumentError.newerFormat(format) }
        updatedAt = try container.decodeIfPresent(Date.self, forKey: Key("updatedAt")) ?? .distantPast
        device = try container.decodeIfPresent(String.self, forKey: Key("device"))
            ?? (decoder.userInfo[unknownSyncDevice] as? String ?? "")
        content = try container.decode(Content.self, forKey: Self.payloadKey())
    }

    public func encode(to encoder: Encoder) throws {
        guard format <= Content.format else { throw SyncDocumentError.newerFormat(format) }
        let key = try Self.payloadKey()
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(format, forKey: Key("format"))
        try container.encode(updatedAt, forKey: Key("updatedAt"))
        try container.encode(device, forKey: Key("device"))
        try container.encode(content, forKey: key)
    }
}

import Foundation

/// 来源：stox@5e54ee1 Sources/StoxCore/Sync.swift；比较内容，不用写入时间冒充改动。
public enum SyncRules {
    public static func shouldApply<Content: SyncContent>(remote: Content, local: Content, lastSynced: Content?) -> Bool {
        remote != local && remote != lastSynced
    }

    public static func shouldPush<Content: SyncContent>(local: Content, lastSynced: Content?) -> Bool {
        local != lastSynced
    }

    public static func needsChoice<Content: SyncContent>(remote: Content?, local: Content) -> Bool {
        guard let remote else { return false }
        return remote != local && !remote.isEmptyForSync
    }
}

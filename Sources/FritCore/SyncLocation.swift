import Foundation

/// 来源：stox@5e54ee1 Sources/StoxCore/SyncLocation.swift；不查询账号、entitlement或文件系统。
public enum SyncLocation: Equatable, Sendable {
    case override(URL)
    case container(URL)
    case drive(URL)

    public var folderURL: URL {
        switch self {
        case .override(let url), .container(let url), .drive(let url): return url
        }
    }

    public var kind: String {
        switch self {
        case .override: return "override"
        case .container: return "container"
        case .drive: return "drive"
        }
    }

    public func fileURL(named fileName: String = "sync.json") -> URL? {
        guard Self.validRelativePath(fileName) else { return nil }
        return folderURL.appendingPathComponent(fileName)
    }

    /// 测试覆盖 > 已解析容器 > 云盘。调用方有容器权限但尚未取到时应传 driveRoot:nil。
    public static func resolve(override: String?, containerRoot: URL?, driveRoot: URL?,
                               driveFolder: String, containerSubfolder: String = "Documents") -> Self? {
        if let override, !override.isEmpty {
            return .override(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let containerRoot {
            guard containerRoot.isFileURL, validRelativePath(containerSubfolder) else { return nil }
            return .container(containerRoot.appendingPathComponent(containerSubfolder, isDirectory: true))
        }
        if let driveRoot {
            guard driveRoot.isFileURL, validRelativePath(driveFolder) else { return nil }
            return .drive(driveRoot.appendingPathComponent(driveFolder, isDirectory: true))
        }
        return nil
    }

    private static func validRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\0")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

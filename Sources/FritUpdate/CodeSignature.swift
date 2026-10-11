#if os(macOS)
import Foundation
import Security

public enum CodeSignature {
    public static var currentTeam: String? { team(in: ownStaticCode()) }
    public static var isAdHoc: Bool { certificates(in: ownStaticCode()).isEmpty }
    public static var signerName: String? {
        guard let leaf = certificates(in: ownStaticCode()).first else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }
    public static var currentRequirement: SecRequirement? {
        guard !isAdHoc, let code = ownStaticCode() else { return nil }
        return designatedRequirement(code)
    }

    public static func teamIdentifier(of url: URL) -> String? { team(in: staticCode(url)) }
    public static func designatedRequirement(of url: URL) -> SecRequirement? {
        guard let code = staticCode(url) else { return nil }
        return designatedRequirement(code)
    }

    public static func requirementText(teamIdentifier: String) -> String? {
        guard teamIdentifier.count == 10, teamIdentifier.allSatisfy({ "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".contains($0) }) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    public static func isSigned(_ url: URL, byTeam teamIdentifier: String) -> Bool {
        guard let text = requirementText(teamIdentifier: teamIdentifier) else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return satisfies(url, requirement: requirement)
    }

    public static func satisfies(_ url: URL, requirement: SecRequirement?) -> Bool {
        guard let code = staticCode(url) else { return false }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate))
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    static func accepts(_ url: URL, policy: SignerPolicy) -> Bool {
        switch policy {
        case .any: return satisfies(url, requirement: nil)
        case .team(let team): return isSigned(url, byTeam: team)
        case .sameTeamAsCurrent:
            if let team = currentTeam { return isSigned(url, byTeam: team) }
            return information(ownStaticCode()) != nil && isAdHoc && satisfies(url, requirement: nil)
        case .designatedRequirementOfCurrent:
            if let requirement = currentRequirement { return satisfies(url, requirement: requirement) }
            return information(ownStaticCode()) != nil && isAdHoc && satisfies(url, requirement: nil)
        }
    }

    private static func designatedRequirement(_ code: SecStaticCode) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func ownStaticCode() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var result: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &result) == errSecSuccess else { return nil }
        return result
    }

    private static func information(_ code: SecStaticCode?) -> [String: Any]? {
        guard let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }

    private static func team(in code: SecStaticCode?) -> String? {
        guard let team = information(code)?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }

    private static func certificates(in code: SecStaticCode?) -> [SecCertificate] {
        information(code)?[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
    }
}

public enum Translocation {
    private typealias IsTranslocatedURL = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8
    private typealias CreateOriginalPathForURL = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    /// handle 初始化后不变；系统的 dlsym 可以并发调用。
    private final class Symbols: @unchecked Sendable {
        let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
        deinit { if let handle { dlclose(handle) } }
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            guard let handle else { return nil }
            return dlsym(handle, name)
        }
    }
    private static let symbols = Symbols()

    public static func isTranslocated(_ url: URL) -> Bool {
        if url.path.contains("/AppTranslocation/") { return true }
        guard let pointer = symbols.symbol("SecTranslocateIsTranslocatedURL") else { return false }
        let function = unsafeBitCast(pointer, to: IsTranslocatedURL.self)
        var translocated = false
        _ = function(url as CFURL, &translocated, nil)
        return translocated
    }

    public static func originalURL(of url: URL) -> URL? {
        guard let pointer = symbols.symbol("SecTranslocateCreateOriginalPathForURL") else { return nil }
        let function = unsafeBitCast(pointer, to: CreateOriginalPathForURL.self)
        guard let original = function(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return (original as URL).standardizedFileURL
    }
}
#endif

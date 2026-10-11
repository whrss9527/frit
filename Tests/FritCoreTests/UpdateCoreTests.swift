import XCTest
@testable import FritCore

final class UpdateCoreTests: XCTestCase {
    private let hash = String(repeating: "a", count: 64)
    private let repository = "whrss9527/pop"

    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false,
                         names: [String] = ["Pop-VERSION.zip", "SHA256SUMS.txt"]) -> GitHubRelease {
        let version = AppVersion(tag)?.description ?? tag
        return GitHubRelease(tagName: tag, htmlURL: URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")!,
                             assets: names.map { name in
            let name = name.replacingOccurrences(of: "VERSION", with: version)
            return .init(name: name, downloadURL: URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(name)")!, size: 1234)
        }, isDraft: draft, isPrerelease: prerelease)
    }

    private func version(_ text: String) -> AppVersion { AppVersion(text)! }

    /// 迁自 Pop 的通道测试，补上乱序、无效版本和缺失 prerelease 标记。
    func testNewestRespectsPrereleaseSetting() {
        let list = [release("v0.2.0"), release("v0.4.0-beta.1", prerelease: true),
                    release("v0.3.0", prerelease: true), release("v0.1.0"), release("v9.0.0", draft: true),
                    release("latest"), release("v0.5.0-beta.1")]
        XCTAssertEqual(ReleaseFeed.newest(list, channel: .includePrereleases)?.version, version("0.5.0-beta.1"))
        XCTAssertEqual(ReleaseFeed.newest(list, channel: .stable)?.version, version("0.2.0"))
        XCTAssertNil(ReleaseFeed.newest([], channel: .includePrereleases))
        XCTAssertEqual(ReleaseFeed.newest([release("v1.0-beta.10"), release("v1.0-beta.2")], channel: .includePrereleases)?.version,
                       version("1.0-beta.10"))
    }

    func testParsesListAndSingleRelease() throws {
        let json = ####"{"tag_name":"v0.3.0","html_url":"https://github.com/whrss9527/pop/releases/tag/v0.3.0","published_at":"2026-09-28T15:38:00Z","body":"### 新增\n- 测试","assets":[{"name":"Pop-0.3.0.zip","size":1234,"browser_download_url":"https://example.com/Pop-0.3.0.zip"}]}"####
        let single = try XCTUnwrap(ReleaseFeed.parse(Data(json.utf8)))
        let list = try XCTUnwrap(ReleaseFeed.parse(Data("[\(json),{},null,\(json)]".utf8)))
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first, single.first)
        XCTAssertEqual(single.first?.assets.first?.size, 1234)
        XCTAssertNotNil(single.first?.publishedAt)
        XCTAssertEqual(single.first?.body, "### 新增\n- 测试")
        for input in ["not json", "{}", "123", "null"] { XCTAssertNil(ReleaseFeed.parse(Data(input.utf8)), input) }
        XCTAssertEqual(ReleaseFeed.parse(Data("[]".utf8)), [])
        XCTAssertEqual(ReleaseFeed.parse(Data(json.replacingOccurrences(of: "\"tag_name\"", with: "\"draft\":true,\"tag_name\"").utf8)), [])
    }

    func testMalformedAssetDoesNotHideValidAttachments() throws {
        let json = #"{"tag_name":"v1","html_url":"https://github.com/x","assets":[null,{"name":"broken"},{"name":"good","browser_download_url":"https://github.com/x"}]}"#
        XCTAssertEqual(try XCTUnwrap(ReleaseFeed.parse(Data(json.utf8))).first?.assets.map(\.name), ["good"])
    }

    /// Stox v0.1.0 的真实响应节选：只有 GitHub 摘要，也可以校验安装包。
    func testStoxReleaseDigestAndFields() throws {
        let json = ####"{"tag_name":"v0.1.0","draft":false,"prerelease":false,"html_url":"https://github.com/whrss9527/stox/releases/tag/v0.1.0","published_at":"2026-09-28T08:00:05Z","body":"## 安装\n\n1. 下载 Stox.zip","assets":[{"name":"Stox.zip","size":901945,"browser_download_url":"https://github.com/whrss9527/stox/releases/download/v0.1.0/Stox.zip","digest":"sha256:8d8c88b640373163c97c742058047867a3c516c9854c92fc4905aae614c330d2"}]}"####
        let item = try XCTUnwrap(ReleaseFeed.parse(Data(json.utf8))?.first)
        let candidate = UpdateCandidate(release: item, naming: .fixed("Stox.zip"), architecture: .arm64, publishedBy: "whrss9527/stox")
        XCTAssertEqual(item.version, version("0.1.0"))
        XCTAssertEqual(item.publishedAt, ISO8601DateFormatter().date(from: "2026-09-28T08:00:05Z"))
        XCTAssertEqual(candidate.archive?.size, 901_945)
        XCTAssertEqual(candidate.archive?.sha256, "8d8c88b640373163c97c742058047867a3c516c9854c92fc4905aae614c330d2")
        XCTAssertNil(candidate.checksums)
        XCTAssertTrue(candidate.canInstall)
    }

    func testPrefersArchiveWithVersionInName() {
        let item = release("v0.3.0", names: ["Pop-old.zip", "Pop-VERSION.zip", "SHA256SUMS.txt", "notes.txt"])
        XCTAssertEqual(ArchiveNaming.versioned(prefix: "Pop-").asset(in: item, architecture: .arm64)?.name, "Pop-0.3.0.zip")
        XCTAssertEqual(ArchiveNaming.versioned(prefix: "Pop-").asset(in: release("v0.3.0", names: ["Pop-old.zip"]), architecture: .arm64)?.name,
                       "Pop-old.zip")
        XCTAssertEqual(ArchiveNaming.versioned(prefix: "Pop", suffix: ".zip").asset(in: release("v0.3.0", names: ["poplegacy.zip"]), architecture: .arm64)?.name,
                       "poplegacy.zip")
    }

    func testAllFourArchiveNamingStrategies() {
        let stox = release("v1", names: ["notes.txt", "Stox.zip"])
        let meno = release("v1", names: ["Meno.zip"])
        XCTAssertEqual(ArchiveNaming.fixed("Stox.zip").asset(in: stox, architecture: .x86_64)?.name, "Stox.zip")
        XCTAssertEqual(ArchiveNaming.fixed("Meno.zip").asset(in: meno, architecture: .arm64)?.name, "Meno.zip")
        let custom = ArchiveNaming.custom { assets, _, _ in assets.first { $0.name == "notes.txt" } }
        XCTAssertEqual(custom.asset(in: stox, architecture: .arm64)?.name, "notes.txt")
        let alien = GitHubRelease.Asset(name: "alien", downloadURL: URL(string: "https://evil.example/x")!)
        XCTAssertNil(ArchiveNaming.custom { _, _, _ in alien }.asset(in: stox, architecture: .arm64))
    }

    /// 迁自 Proxi：精简包优先，不存在该架构时回退通用包。
    func testThinArchiveSelection() {
        let item = release("v0.5.0", names: ["Proxi-macos.zip", "Proxi-macos-arm64.zip", "SHA256SUMS.txt"])
        let naming = ArchiveNaming.perArchitecture(universal: "Proxi-macos.zip", thin: { "Proxi-macos-\($0.rawValue).zip" })
        XCTAssertEqual(naming.asset(in: item, architecture: .arm64)?.name, "Proxi-macos-arm64.zip")
        XCTAssertEqual(naming.asset(in: item, architecture: .x86_64)?.name, "Proxi-macos.zip")
        XCTAssertNil(naming.asset(in: release("v1", names: []), architecture: .arm64))
    }

    func testCandidateRequiresArchiveAndChecksumSource() {
        let item = release("v0.3.0")
        XCTAssertTrue(UpdateCandidate(release: item, naming: .versioned(prefix: "Pop-"), architecture: .arm64, publishedBy: repository).canInstall)
        let bare = release("v0.3.0", names: ["Pop-VERSION.zip"])
        XCTAssertFalse(UpdateCandidate(release: bare, naming: .versioned(prefix: "Pop-"), architecture: .arm64, publishedBy: repository).canInstall)
        let archive = GitHubRelease.Asset(name: "Stox.zip", downloadURL: URL(string: "https://github.com/x")!, digest: "sha256:" + hash)
        XCTAssertTrue(UpdateCandidate(release: item, archive: archive, checksums: nil).canInstall)
        XCTAssertFalse(UpdateCandidate(release: item, archive: nil, checksums: item.assets.last).canInstall)
    }

    func testForeignSameNameCannotShadowOwnedAsset() {
        let good = release("v0.3.0")
        let bad = GitHubRelease.Asset(name: "Pop-0.3.0.zip", downloadURL: URL(string: "https://evil.example/Pop-0.3.0.zip")!, digest: "sha256:" + hash)
        let item = GitHubRelease(tagName: good.tagName, htmlURL: good.htmlURL, assets: [bad] + good.assets)
        let candidate = UpdateCandidate(release: item, naming: .versioned(prefix: "Pop-"), architecture: .arm64, publishedBy: repository)
        XCTAssertEqual(candidate.archive, good.assets.first)
        for address in ["https://github.com/whrss9527/pop/releases/download/v0.2.0/Pop.zip",
                        "https://github.com/whrss9527/pop/releases/download/v0.3.0/../Pop.zip",
                        "https://github.com/whrss9527/pop/releases/download/v0.3.0/%2e%2e/Pop.zip",
                        "https://github.com:444/whrss9527/pop/releases/download/v0.3.0/Pop.zip"] {
            let item = GitHubRelease(tagName: "v0.3.0", htmlURL: good.htmlURL, assets: [.init(name: "Pop.zip", downloadURL: URL(string: address)!)])
            XCTAssertNil(item.asset(named: "Pop.zip", publishedBy: repository), address)
        }
    }

    /// Stox、Pop、Proxi 的 shasum 样本，加上 Meno 的歧义拒绝行为。
    func testChecksumsParsing() {
        let other = String(repeating: "B", count: 64)
        let parsed = Checksums.parse("\(hash)  Pop-0.3.0.zip\n\(other) *Pop 0.3.0.zip\nbad line\n1234  short.zip\n")
        XCTAssertEqual(parsed, ["Pop-0.3.0.zip": hash, "Pop 0.3.0.zip": other.lowercased()])
        XCTAssertEqual(Checksums.parse("说明行\n0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0  Proxi-macos.zip\nDEADBEEF 太短的\n5891B5B522D5DF086D0FF0B110FBD9D21BB4FC7163AF34D08286A2E846F6BE03 *hello.txt"), [
            "Proxi-macos.zip": "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
            "hello.txt": "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03",
        ])
        XCTAssertNil(Checksums.parse("\(hash)  Meno.zip\n\(other)  Meno.zip\n\(hash)  Meno.zip")["Meno.zip"])
        XCTAssertEqual(Checksums.parse("\(hash)\t*Meno.zip\r\n\(hash)  Meno.zip")["Meno.zip"], hash)
    }

    func testReleaseRangeExcludesDraftsAndPrereleases() {
        let all = [release("v0.35.0"), release("v0.38.0-beta", prerelease: true), release("v0.37.0"),
                   release("v0.36.1", draft: true), release("v0.36.0"), release("v0.38.0")]
        XCTAssertEqual(ReleaseFeed.releases(all, after: version("0.35.0"), upTo: version("0.38.0")).map { $0.version!.description },
                       ["0.38.0", "0.37.0", "0.36.0"])
        XCTAssertEqual(ReleaseFeed.releases(all, after: version("0.36.0"), upTo: version("0.37.0")).map { $0.version!.description }, ["0.37.0"])
        XCTAssertEqual(ReleaseFeed.releases(all, after: version("0.38.0"), upTo: version("0.38.0")), [])
    }

    /// 四个 App 的旧安装位置测试共用参数化名称，Meno 的拒绝策略单独保留。
    func testInstallPlanAcrossApps() {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let personal = URL(fileURLWithPath: "/Users/me/Applications", isDirectory: true)
        for name in ["Stox", "Pop", "Proxi", "Meno"] {
            let installed = system.appendingPathComponent(name + ".app", isDirectory: true)
            let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/\(name).app")
            let downloads = URL(fileURLWithPath: "/Users/me/Downloads/\(name).app")
            func plan(_ bundle: URL, translocated: Bool = false, original: URL? = nil, readOnly: Bool = false,
                      relocates: Bool = true, folders: [URL] = [system, personal], writable: (URL) -> Bool = { _ in true }) -> InstallPlan? {
                InstallLocation.plan(bundle: bundle, appName: name, translocated: translocated, original: original,
                                     readOnly: readOnly, relocates: relocates, folders: folders, canWrite: writable)
            }
            XCTAssertEqual(plan(installed), InstallPlan(target: installed, trashAfter: nil, relocating: false))
            XCTAssertEqual(plan(translocated, translocated: true, original: installed, readOnly: true),
                           InstallPlan(target: installed, trashAfter: nil, relocating: false))
            XCTAssertEqual(plan(translocated, translocated: true, original: downloads, readOnly: true),
                           InstallPlan(target: installed, trashAfter: downloads, relocating: true))
            XCTAssertEqual(plan(translocated, translocated: true, original: downloads, readOnly: true, writable: { $0 == personal }),
                           InstallPlan(target: personal.appendingPathComponent(name + ".app"), trashAfter: downloads, relocating: true))
            XCTAssertNil(plan(translocated, translocated: true, original: installed, relocates: false))
            XCTAssertNil(plan(installed, readOnly: true, relocates: false))
            XCTAssertNil(plan(translocated, translocated: true, folders: []))
            XCTAssertNil(plan(URL(fileURLWithPath: "/tmp/\(name)")))
        }
    }
}

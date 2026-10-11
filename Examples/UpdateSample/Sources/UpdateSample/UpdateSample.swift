import FritCore
import FritUpdate
import SwiftUI

@main
struct UpdateSample: App {
    var body: some Scene {
        WindowGroup("Frit 更新组件") { PreviewGallery() }
            .defaultSize(width: 620, height: 760)
    }
}

@MainActor
private struct PreviewGallery: View {
    @State private var language = "zh-Hans"
    @State private var selected = "available"
    private let item: UpdateCandidate
    private let states: [(String, String, Updater.Phase)]

    init() {
        let release = GitHubRelease(tagName: "v2.0.0", htmlURL: URL(string: "https://github.com/whrss9527/frit/releases")!,
                                    body: "### 更新内容\n- 一键更新。\n- 保留设置与数据。")
        let asset = GitHubRelease.Asset(name: "Sample.zip", downloadURL: URL(string: "https://github.com/whrss9527/frit/releases/download/v2.0.0/Sample.zip")!,
                                       size: 5_432_100, digest: "sha256:" + String(repeating: "a", count: 64))
        let candidate = UpdateCandidate(release: release, archive: asset)
        item = candidate
        states = [("idle", "未检查", .idle), ("checking", "检查中", .checking), ("upToDate", "已是最新", .upToDate),
            ("skipped", "已跳过", .skipped(candidate)), ("available", "有新版本", .available(candidate)),
            ("unknown", "下载，大小未知", .downloading(candidate, nil)), ("downloading", "下载 42%", .downloading(candidate, 0.42)),
            ("verifying", "校验", .verifying(candidate)), ("installing", "安装", .installing(candidate)),
            ("relaunching", "重启", .relaunching(candidate)), ("failed", "校验失败", .failed(candidate, .checksumMismatch)),
            ("blocked", "App 管理拦截", .failed(candidate, .appManagement))]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("语言", selection: $language) { Text("中文").tag("zh-Hans"); Text("English").tag("en") }
                .pickerStyle(.segmented)
                .onChange(of: language) { value in FritLocalization.languageOverride = value }
            Picker("状态", selection: $selected) {
                ForEach(states, id: \.0) { Text($0.1).tag($0.0) }
            }
            ScrollView {
                let updater = preview()
                VStack(spacing: 24) {
                    UpdateBanner(updater: updater, openDetails: {})
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    UpdateSection(updater: updater, pageURLOpener: { _ in })
                    Divider()
                    Text("搬家说明")
                    UpdateSection(updater: preview(relocating: true), pageURLOpener: { _ in })
                }
            }
        }
        .padding(24)
        .onAppear { FritLocalization.languageOverride = language }
    }
    private func preview(relocating: Bool = false) -> Updater {
        var config = UpdateConfiguration(repository: "whrss9527/frit", appName: "Sample")
        config.defaults = UserDefaults(suiteName: "Frit.UpdateSample")!
        config.bundleURL = relocating ? URL(fileURLWithPath: "/tmp/AppTranslocation/Sample.app")
            : URL(fileURLWithPath: "/Applications/Sample.app")
        return Updater.preview(configuration: config, phase: relocating ? .available(item)
            : states.first { $0.0 == selected }!.2, lastChecked: Date().addingTimeInterval(-3600))
    }
}

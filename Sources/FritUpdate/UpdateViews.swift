#if os(macOS)
import AppKit
import SwiftUI
import FritCore

/// 面板里的更新条：有新版本时出现，一键更新，显示进度和结果。
@MainActor
public struct UpdateBanner: View {
    @ObservedObject private var updater: Updater
    @ObservedObject private var language = UpdateLanguage.shared
    private let openDetails: () -> Void
    public init(updater: Updater, openDetails: @escaping () -> Void) {
        self.updater = updater
        self.openDetails = openDetails
    }

    public var body: some View {
        if let release = updater.candidate {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(release))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    switch updater.phase {
                    case .downloading(_, let fraction):
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    case .failed(_, let message):
                        Text(message.localizedDescription)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    default:
                        Text(subtitle(release))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { openDetails() }
                .help(updateText("查看更新内容"))
                Spacer(minLength: 4)
                trailing
            }
            .padding(10)

        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch updater.phase {
        case .available:
            Button(updateText("更新")) { updater.install() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .downloading(_, let fraction):
            HStack(spacing: 6) {
                if let fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    updater.cancel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(updateText("取消更新"))
            }
        case .verifying, .installing, .relaunching:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Button(updateText("重试")) { updater.install() }
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var symbol: String {
        switch updater.phase {
        case .failed: return "xmark.octagon.fill"
        case .relaunching: return "checkmark.circle.fill"
        default: return "sparkles"
        }
    }

    private var iconColor: Color {
        if case .failed = updater.phase { return .orange }
        return .accentColor
    }

    private func title(_ release: UpdateCandidate) -> String {
        switch updater.phase {
        case .downloading: return updateText("正在下载 %@", release.versionText) + (updater.route.map { updateText(" · 经%@", $0) } ?? "")
        case .verifying: return updateText("正在校验 %@", release.versionText)
        case .installing: return updateText("正在安装 %@", release.versionText)
        case .relaunching: return updateText("已更新到 %@，正在重新启动", release.versionText)
        case .failed: return updateText("更新到 %@ 失败", release.versionText)
        default: return updateText("有新版本 %@", release.versionText)
        }
    }

    private func subtitle(_ release: UpdateCandidate) -> String {
        switch updater.phase {
        case .verifying, .installing: return updateText("马上就好，请不要退出")
        case .relaunching: return updateText("程序会自动重新打开")
        default:
            if let size = release.archive?.size {
                return updateText("下载 %@ 后自动安装并重新启动", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            return updateText("点“更新”自动下载安装并重新启动")
        }
    }
}

/// “关于与更新”页里的更新区域：检查、版本说明、一键更新、进度和错误。
@MainActor
public struct UpdateSection: View {
    @ObservedObject private var updater: Updater
    @ObservedObject private var language = UpdateLanguage.shared
    private let pageURLOpener: (URL) -> Void
    public init(updater: Updater, pageURLOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.updater = updater
        self.pageURLOpener = pageURLOpener
    }

    public var body: some View {
        VStack(spacing: 12) {
            switch updater.phase {
            case .idle, .upToDate:
                HStack(spacing: 10) {
                    if case .upToDate = updater.phase {
                        Label(updateText("已经是最新版本"), systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(lastCheckedText)
                            .foregroundStyle(.secondary)
                    }
                    checkButton
                }
                .font(.system(size: 12))
            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(updateText("正在检查更新…"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            case .skipped(let release):
                HStack(spacing: 10) {
                    Text(updateText("已跳过 %@", release.versionText))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button(updateText("仍然查看")) { updater.showSkippedVersion() }
                    checkButton
                }
            case .available(let release):
                availableView(release)
            case .downloading(let release, let fraction):
                progressView(title: updateText("正在下载 %@…", release.versionText) + (updater.route.map { updateText("（经%@）", $0) } ?? ""), fraction: fraction, cancellable: true)
            case .verifying(let release):
                progressView(title: updateText("正在校验 %@…", release.versionText), fraction: nil, cancellable: updater.canCancel)
            case .installing(let release):
                progressView(title: updateText("正在安装 %@…", release.versionText), fraction: nil, cancellable: false)
            case .relaunching(let release):
                progressView(title: updateText("已更新到 %@，正在重新启动…", release.versionText), fraction: 1, cancellable: false)
            case .failed(let release, let message):
                failedView(release, message.localizedDescription)
            }
            if let error = updater.checkError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var checkButton: some View {
        Button(updateText("检查更新")) {
            Task { await updater.check(manual: true) }
        }
    }

    private var lastCheckedText: String {
        guard let date = updater.lastChecked else { return updateText("还没有检查过更新") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = FritLocalization.locale
        formatter.unitsStyle = .short
        return updateText("上次检查：%@", formatter.localizedString(for: date, relativeTo: Date()))
    }

    private func availableView(_ release: UpdateCandidate) -> some View {
        VStack(spacing: 10) {
            Label(updateText("有新版本 %@", release.versionText), systemImage: "sparkles")
                .font(.system(size: 14, weight: .semibold))
            if let date = release.release.publishedAt {
                Text(updateText("发布于 %@", dateFormatter.string(from: date)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 隔了几个版本时列出中间每个版本的更新内容。
            let notes = notesText(release)
            if !notes.isEmpty {
                UpdateReleaseNotes(text: notes)
                    .lineLimit(updater.notesSinceCurrent == nil ? 12 : 30)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            let problem = updater.installProblem ?? (release.canInstall ? nil : UpdateError.noArchive.localizedDescription)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button(updateText("到发布页下载")) { pageURLOpener(release.release.htmlURL) }
                    Button(updateText("跳过这个版本")) { updater.skipAvailableVersion() }
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        updater.install()
                    } label: {
                        Label(updateText("立即更新"), systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    Button(updateText("跳过这个版本")) { updater.skipAvailableVersion() }
                }
                Text(installHint(release))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let note = updater.relocationNote {
                    Label(note, systemImage: "arrow.right.doc.on.clipboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                pageLink(release)
            }
        }
    }

    private func pageLink(_ release: UpdateCandidate) -> some View {
        Button(updateText("在浏览器里查看发布页")) { pageURLOpener(release.release.htmlURL) }
            .buttonStyle(.link)
            .font(.caption)
    }

    private func installHint(_ release: UpdateCandidate) -> String {
        var text = updateText("点一下就行：下载")
        if let size = release.archive?.size {
            text += " \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
        }
        return text + updateText("，校验后替换程序并自动重新启动，设置和数据都会保留。")
    }

    private func progressView(title: String, fraction: Double?, cancellable: Bool) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                if let fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if cancellable {
                    Button(updateText("取消")) { updater.cancel() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func failedView(_ release: UpdateCandidate, _ message: String) -> some View {
        VStack(spacing: 10) {
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if updater.lastFailure == .appManagement {
                    Button(updateText("打开“App 管理”设置")) {
                        pageURLOpener(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
                    }
                }
                if release.canInstall, updater.installProblem == nil {
                    Button(updateText("重试")) { updater.install() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(updateText("到发布页下载")) { pageURLOpener(release.release.htmlURL) }
                }
                checkButton
            }
            if release.canInstall, updater.installProblem == nil {
                pageLink(release)
            }
        }
    }

    private func notesText(_ candidate: UpdateCandidate) -> String {
        let notes = updater.localizedNotes
        guard let notes, notes.versions.count > 1 else {
            var style = updater.configuration.notes
            if let language = FritLocalization.languageOverride {
                style.language = language.lowercased().hasPrefix("zh") ? .chinese : .english
            }
            return ReleaseNotes.highlights(candidate.release.body ?? "", style: style)
        }
        return notes.versions.prefix(5).map { version in
            let body = version.blocks.map { block -> String in
                switch block {
                case .heading(let text): return "**" + text + "**"
                case .item(let text): return "- " + text
                case .paragraph(let text): return text
                }
            }.joined(separator: "\n")
            return "**\(version.version)**\n" + body
        }.joined(separator: "\n\n")
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = FritLocalization.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }
}

/// 发布说明：GitHub 的 Markdown 简单渲染，列表项换成圆点。
struct UpdateReleaseNotes: View {
    var text: String

    var body: some View {
        Text(Self.attributed(text))
            .font(.system(size: 12))
            .textSelection(.enabled)
    }

    static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop { $0 == " " }
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    return "• " + trimmed.dropFirst(2)
                }
                if trimmed.hasPrefix("#") {
                    return String(trimmed.drop { $0 == "#" || $0 == " " })
                }
                return String(line)
            }
            .joined(separator: "\n")
    }

    static func attributed(_ text: String) -> AttributedString {
        let cleaned = cleaned(text)
        if let attributed = try? AttributedString(
            markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(cleaned)
    }
}
private extension UpdateCandidate {
    var versionText: String { release.version?.description ?? release.tagName }
}
#endif

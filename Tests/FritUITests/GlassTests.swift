#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import FritUI

@MainActor
final class GlassTests: XCTestCase {
    func testPublicComponentsRenderInNamedAppKitAppearances() async throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                var actions = 0
                let content = GlassGroup {
                    VStack(spacing: 12) {
                        Text("Meno").padding().fritGlass(in: Capsule(), tint: .blue, interactive: true)
                        Text("清透").padding().fritGlass(in: RoundedRectangle(cornerRadius: 12), clear: true)
                        Text("Stox").padding().fritGlassCard(prominent: true)
                        Text("Pop").padding().fritGlassSurface(RoundedRectangle(cornerRadius: 16), tint: .purple)
                        Button("玻璃") { actions += 1 }.buttonStyle(FritGlassButtonStyle())
                        Button("突出") { actions += 1 }.buttonStyle(FritGlassButtonStyle(prominent: true))
                        Button("行") { actions += 1 }.buttonStyle(HoverRowStyle())
                        Button { actions += 1 } label: { Label("图标", systemImage: "gear") }
                            .buttonStyle(IconButtonStyle())
                    }.padding(24)
                }
                .environment(\.colorScheme, scheme)
                .frame(width: 400, height: 600)
                let host = FirstMouseHostingView(rootView: content)
                let appearance: NSAppearance.Name
                switch (scheme, contrast) {
                case (.dark, .increased): appearance = .accessibilityHighContrastDarkAqua
                case (.dark, _): appearance = .darkAqua
                case (_, .increased): appearance = .accessibilityHighContrastAqua
                default: appearance = .aqua
                }
                host.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
                host.layoutSubtreeIfNeeded()
                XCTAssertFalse(host.subviews.isEmpty)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1000)
                XCTAssertEqual(actions, 0)
                if let directory = ProcessInfo.processInfo.environment["FRIT_UI_EVIDENCE"] {
                    guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
                          ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted" else {
                        return XCTFail("实际窗口截取只在临时托管Mac启用，不请求个人会话录屏权限")
                    }
                    let root = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let path = root.appendingPathComponent("glass-\(scheme)-\(contrast).png")
                    // Liquid Glass 由窗口合成器绘制，离屏cacheDisplay可能只得到空白。
                    let window = FloatingPanel(level: .normal)
                    window.contentView = host
                    window.setFrame(NSRect(x: 100, y: 100, width: 400, height: 600), display: true)
                    window.orderFrontRegardless()
                    defer { window.close() }
                    try await Task.sleep(nanoseconds: 300_000_000)
                    window.displayIfNeeded()
                    try await capture(window: window, to: path)
                    let context: [String: Any] = [
                        "appearance": appearance.rawValue,
                        "systemIncreaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                    ]
                    try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
                        .write(to: path.deletingPathExtension().appendingPathExtension("json"))
                    let rendered = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: path)))
                    var colors = Set<Int>()
                    for y in stride(from: 0, to: rendered.pixelsHigh, by: 8) {
                        for x in stride(from: 0, to: rendered.pixelsWide, by: 8) {
                            if let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                                colors.insert((Int(color.redComponent * 255) << 16)
                                    | (Int(color.greenComponent * 255) << 8) | Int(color.blueComponent * 255))
                            }
                        }
                    }
                    XCTAssertGreaterThan(colors.count, 8, "原生窗口快照为空白，不能只按PNG大小判通过")
                }
            }
        }
    }

    private func capture(window: NSWindow, to path: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while process.isRunning && clock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !process.isRunning, process.terminationStatus == 0 else {
            throw NSError(domain: "FritUI.WindowCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "实际窗口截图失败或未在五秒内返回"])
        }
    }

    func testVisualEffectConfigurationUpdatesAndClearsRoundedMask() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: VisualEffectBackground(material: .hudWindow,
            blending: .withinWindow, cornerRadius: 16))
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 80)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSVisualEffectView? {
            if let view = view as? NSVisualEffectView { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let effect = find(host) else { return XCTFail("背景没有创建实际 NSVisualEffectView") }
        XCTAssertEqual(effect.material, .hudWindow)
        XCTAssertEqual(effect.blendingMode, .withinWindow)
        XCTAssertNotNil(effect.maskImage)
        host.rootView = VisualEffectBackground(material: .sidebar, cornerRadius: 0)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(effect.material, .sidebar)
        XCTAssertNil(effect.maskImage)
    }
}
#endif

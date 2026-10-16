#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import FritUI

@MainActor
final class GlassTests: XCTestCase {
    func testPublicComponentsRenderInBothAppearancesAndContrastModes() throws {
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
                    let root = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try png.write(to: root.appendingPathComponent("glass-\(scheme)-\(contrast).png"))
                }
            }
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

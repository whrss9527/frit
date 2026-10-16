#if os(macOS)
// 来源：pop@137efa3 Pop/UI/Glass.swift；不包含App诊断开关或选择动画。
import AppKit
import SwiftUI

/// 浮窗的玻璃质感。
/// macOS 26 上用系统的 Liquid Glass（需要用 Xcode 26 编译）；更早的系统用窗口后面的模糊，
/// 再加顶部一层高光和一圈亮边，看起来像一块玻璃。
struct GlassSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            blurred(content)
        }
        #else
        blurred(content)
        #endif
    }

    private func blurred(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    VisualEffectBackground(material: .hudWindow)
                    LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                    if let tint {
                        tint.opacity(0.14)
                    }
                }
                .clipShape(shape)
            }
            .overlay {
                // 玻璃的亮边：左上亮、右下暗
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0.08)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                                   lineWidth: 1)
            }
            .overlay {
                shape.stroke(Color.black.opacity(0.14), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.24), radius: 16, y: 6)
    }
}

public extension View {
    /// 给视图加一块玻璃底，形状由 shape 决定。
    func fritGlassSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint))
    }
}

#endif

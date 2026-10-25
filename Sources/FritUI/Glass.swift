#if os(macOS)
// 来源：meno@935888e Sources/Meno/UI/Glass/Glass.swift；卡片来自 stox@53deb79 Sources/Stox/Glass.swift。
import AppKit
import SwiftUI

// MARK: - 玻璃表面

public extension View {
    /// 新系统使用 Liquid Glass；旧系统保留 Meno 的磨砂、高光和高对比度边框。
    @ViewBuilder
    func fritGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        clear: Bool = false
    ) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(liquidGlass(tint: tint, interactive: interactive, clear: clear), in: shape)
        } else {
            self.modifier(FrostedGlass(shape: shape, tint: tint, clear: clear))
        }
        #else
        self.modifier(FrostedGlass(shape: shape, tint: tint, clear: clear))
        #endif
    }

    /// Stox/Proxi 的卡片：旧系统 prominent 使用较厚材质，不附加 Meno 阴影。
    @ViewBuilder
    func fritGlassCard(cornerRadius: CGFloat = 14, prominent: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(prominent ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
        #else
        self.background(prominent ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        #endif
    }

    /// 新系统使用原生玻璃按钮；旧系统使用磨砂胶囊。
    @ViewBuilder
    func fritGlassButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(FrostedButtonStyle(prominent: prominent))
        }
        #else
        self.buttonStyle(FrostedButtonStyle(prominent: prominent))
        #endif
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private func liquidGlass(tint: Color?, interactive: Bool, clear: Bool) -> Glass {
    var glass: Glass = clear ? .clear : .regular
    if let tint {
        glass = glass.tint(tint)
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}
#endif

/// 将相邻玻璃形状组合；旧系统直接显示内容。
public struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    private var content: () -> Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

/// Meno 的旧系统材质、柔和高光和细边。
struct FrostedGlass<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var clear: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        let increased = contrast == .increased
        content
            .background {
                ZStack {
                    shape.fill(increased ? Material.regularMaterial : clear ? Material.ultraThinMaterial : Material.thinMaterial)
                    if let tint {
                        shape.fill(tint.opacity(0.18))
                    }
                    shape.fill(
                        LinearGradient(
                            colors: [Color.white.opacity(dark ? 0.10 : 0.32), Color.white.opacity(0)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                }
            }
            .overlay {
                if increased {
                    // 提高对比度时保留清晰边缘。
                    shape.stroke(Color.primary.opacity(0.55), lineWidth: 1)
                } else {
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(dark ? 0.38 : 0.8),
                                Color.white.opacity(0.06),
                                Color.white.opacity(dark ? 0.16 : 0.4),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
            }
            .shadow(color: Color.black.opacity(dark ? 0.32 : 0.12), radius: 14, x: 0, y: 8)
    }
}

struct FrostedButtonStyle: ButtonStyle {
    var prominent = false

    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let rim = contrast == .increased ? Color.primary.opacity(0.55) : Color.white.opacity(prominent ? 0.25 : 0.45)
        return configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Material.thinMaterial))
            }
            .overlay {
                Capsule().stroke(rim, lineWidth: 0.8)
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 窗口背景

/// 可指定材质、混合方式和圆角的 AppKit 窗口背景。
public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blending: NSVisualEffectView.BlendingMode
    public var cornerRadius: CGFloat

    public init(material: NSVisualEffectView.Material = .underWindowBackground,
                blending: NSVisualEffectView.BlendingMode = .behindWindow, cornerRadius: CGFloat = 0) {
        self.material = material
        self.blending = blending
        self.cornerRadius = cornerRadius
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.maskImage = cornerRadius > 0 ? Self.mask(radius: cornerRadius) : nil
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

#endif

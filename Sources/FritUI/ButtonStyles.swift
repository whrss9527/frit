#if os(macOS)
// 来源：stox@53deb79 Sources/Stox/Glass.swift；玻璃按钮的磨砂样式来自 meno@935888e。
import SwiftUI

/// 新系统使用原生玻璃按钮，旧系统保留 Meno 的磨砂胶囊与按压反馈。
public struct FritGlassButtonStyle: PrimitiveButtonStyle {
    public var prominent: Bool
    public init(prominent: Bool = false) { self.prominent = prominent }
    public func makeBody(configuration: Configuration) -> some View {
        Button(configuration).fritGlassButtonStyle(prominent: prominent)
    }
}

/// 列表行的按钮样式：悬停时浅浅地亮起，按下时稍暗。
public struct HoverRowStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HoverRowBody(configuration: configuration)
    }

    private struct HoverRowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// 圆形的图标按钮。
public struct IconButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.1 : 0.05))))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
#endif

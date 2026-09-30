// swift-tools-version: 5.9
// Frit：Pop、Meno、Stox、Proxi 共用的 Swift 库。
// 模块按功能平铺、统一用 Frit 前缀；平台差异在模块内部用 #if os(macOS) 处理。
import PackageDescription

let package = Package(
    name: "Frit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "FritCore", targets: ["FritCore"]),
    ],
    targets: [
        // 只依赖 Foundation 的纯逻辑，Linux 上也能编译和测试。
        .target(name: "FritCore"),
        .testTarget(name: "FritCoreTests", dependencies: ["FritCore"]),
    ]
)

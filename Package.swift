// swift-tools-version: 5.9
// Frit：Pop、Meno、Stox、Proxi 共用的 Swift 库。
// 模块按功能平铺、统一用 Frit 前缀；平台差异在模块内部用 #if os(macOS) 处理。
import PackageDescription

let package = Package(
    name: "Frit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "FritCore", targets: ["FritCore"]),
        .library(name: "FritUI", targets: ["FritUI"]),
        .library(name: "FritSystem", targets: ["FritSystem"]),
        .library(name: "FritSync", targets: ["FritSync"]),
        .library(name: "FritUpdate", targets: ["FritUpdate"]),
    ],
    targets: [
        // 只依赖 Foundation 的纯逻辑，Linux 上也能编译和测试。
        .target(name: "FritCore"),
        .target(name: "FritUI"),
        .target(name: "FritSystem", dependencies: ["FritCore"]),
        .target(name: "FritSync", dependencies: ["FritCore"]),
        // 文案源由生成器处理；Xcode 后端不能同时编译 catalog 和生成的 strings。
        .target(name: "FritUpdate", dependencies: ["FritCore", "FritSystem"], exclude: ["Resources/Localizable.xcstrings"], resources: [
            .process("Resources/en.lproj"), .process("Resources/zh-Hans.lproj"), .process("Resources/zh-Hant.lproj"),
        ]),
        .testTarget(name: "FritUITests", dependencies: ["FritUI"]),
        .testTarget(name: "FritCoreTests", dependencies: ["FritCore"]),
        .testTarget(name: "FritSystemTests", dependencies: ["FritSystem"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FritSyncTests", dependencies: ["FritSync", "FritCore"]),
        .testTarget(name: "FritUpdateTests", dependencies: ["FritUpdate"]),
    ]
)

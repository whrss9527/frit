// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdateE2ESample", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "Sample", dependencies: [
        .product(name: "FritCore", package: "frit"), .product(name: "FritSystem", package: "frit"),
        .product(name: "FritUpdate", package: "frit"),
    ])]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdateSample",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "UpdateSample", dependencies: [
        .product(name: "FritUpdate", package: "frit"), .product(name: "FritCore", package: "frit"),
    ])]
)

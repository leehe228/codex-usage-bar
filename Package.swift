// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CodexUsageBar", platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexUsageBar", targets: ["CodexUsageBar"])],
    targets: [
        .target(name: "CodexUsageCore"),
        .executableTarget(name: "CodexUsageBar", dependencies: ["CodexUsageCore"]),
        .testTarget(name: "CodexUsageCoreTests", dependencies: ["CodexUsageCore"])
    ]
)

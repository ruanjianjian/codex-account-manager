// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CodexAccounts",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexAccounts", targets: ["AccountManager"])],
    targets: [
        .target(name: "AccountCore"),
        .executableTarget(name: "AccountManager", dependencies: ["AccountCore"]),
        .testTarget(name: "AccountCoreTests", dependencies: ["AccountCore"])
    ],
    swiftLanguageModes: [.v5]
)

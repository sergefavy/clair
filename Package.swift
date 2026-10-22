// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Clair", platforms: [.macOS(.v14)],
    products: [.executable(name: "Clair", targets: ["Clair"])],
    targets: [
        .target(name: "ClairCore", path: "Sources/Core"),
        .executableTarget(name: "Clair", dependencies: ["ClairCore"], path: "Sources/App"),
        .executableTarget(name: "ClairChecks", dependencies: ["ClairCore"], path: "Tests")
    ]
)

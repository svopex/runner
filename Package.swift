// swift-tools-version:5.10
// Balíček nativní aplikace Runner pro macOS (SwiftUI, ikona v horní liště + okno).
import PackageDescription

let package = Package(
    name: "Runner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Runner",
            path: "Sources/Runner"
        ),
        .testTarget(
            name: "RunnerTests",
            dependencies: ["Runner"],
            path: "Tests/RunnerTests"
        ),
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CaffeinateApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CaffeinateApp",
            path: "Sources/CaffeinateApp"
        ),
        .executableTarget(
            name: "CaffeinateWidget",
            path: "Sources/CaffeinateWidget"
        ),
        .testTarget(
            name: "CaffeinateAppTests",
            dependencies: ["CaffeinateApp"],
            path: "Tests/CaffeinateAppTests"
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThirdHand",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ThirdHand",
            path: "Sources/ThirdHand"
        ),
        .testTarget(name: "ThirdHandTests", dependencies: ["ThirdHand"])
    ]
)

// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchID",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchID", path: "Sources/NotchID")
    ]
)

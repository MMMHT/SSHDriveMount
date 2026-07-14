// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TailMountMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TailMountMac", targets: ["TailMountMac"])
    ],
    targets: [
        .executableTarget(
            name: "TailMountMac",
            path: "Sources/TailMountMac"
        )
    ]
)

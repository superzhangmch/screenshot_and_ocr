// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnapOCR",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SnapOCR",
            path: "Sources/SnapOCR"
        )
    ]
)

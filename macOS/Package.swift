// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiezoScope",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PiezoScope", targets: ["PiezoScope"])],
    targets: [
        .target(name: "PiezoCore"),
        .target(name: "PiezoAudioBridge", publicHeadersPath: "include"),
        .executableTarget(name: "PiezoScope", dependencies: ["PiezoCore", "PiezoAudioBridge"]),
        .testTarget(name: "PiezoCoreTests", dependencies: ["PiezoCore"]),
    ],
    swiftLanguageModes: [.v5]
)

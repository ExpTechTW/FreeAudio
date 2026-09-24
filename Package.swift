// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FreeAudio",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "FreeAudio", targets: ["FreeAudio"])],
    targets: [
        .executableTarget(name: "FreeAudio", resources: [.process("Resources")]),
        .testTarget(name: "FreeAudioTests", dependencies: ["FreeAudio"]),
    ]
)

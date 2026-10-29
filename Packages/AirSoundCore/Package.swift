// swift-tools-version: 5.10
// Wire protocol, framing, and shared audio plumbing for Air Sound (macOS sender ↔ iPhone receiver).
import PackageDescription

let package = Package(
    name: "AirSoundCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AirSoundCore", targets: ["AirSoundCore"])],
    targets: [
        .target(name: "AirSoundCore"),
        .testTarget(name: "AirSoundCoreTests", dependencies: ["AirSoundCore"]),
    ]
)

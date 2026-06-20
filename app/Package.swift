// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NewMusicResearch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NewMusicResearch",
            path: "Sources"
        )
    ]
)

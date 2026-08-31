// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SleepCat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SleepCat",
            path: "Sources/SleepCat"
        )
    ]
)

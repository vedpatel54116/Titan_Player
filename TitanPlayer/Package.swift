// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TitanPlayer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "TitanPlayer",
            dependencies: ["FFmpegBuild"],
            path: "TitanPlayer"
        ),
        .testTarget(
            name: "TitanPlayerTests",
            dependencies: ["TitanPlayer"],
            path: "Tests"
        )
    ]
)

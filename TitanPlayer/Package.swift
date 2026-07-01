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
            dependencies: [
                "FFmpegBuild",
                .product(name: "Libavcodec", package: "FFmpegBuild"),
                .product(name: "Libavformat", package: "FFmpegBuild"),
                .product(name: "Libavutil", package: "FFmpegBuild"),
                .product(name: "Libswscale", package: "FFmpegBuild"),
            ],
            path: "TitanPlayer",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/Shaders")
            ]
        ),
        .testTarget(
            name: "TitanPlayerTests",
            dependencies: ["TitanPlayer"],
            path: "Tests",
            resources: [
                .copy("Fixtures/test.mp4")
            ]
        )
    ]
)

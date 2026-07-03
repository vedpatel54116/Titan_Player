// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TitanPlayer",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Fork maintained by superuser404notfound (Vincent Herbst).
        // For production use, mirror to an org-controlled repository.
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", from: "1.0.3"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0")
    ],
    targets: [
        .systemLibrary(
            name: "CLibAss",
            pkgConfig: "libass",
            providers: [
                .brew(["libass"])
            ]
        ),
        .executableTarget(
            name: "TitanPlayer",
            dependencies: [
                "FFmpegBuild",
                "CLibAss",
                .product(name: "Libavcodec", package: "FFmpegBuild"),
                .product(name: "Libavformat", package: "FFmpegBuild"),
                .product(name: "Libavutil", package: "FFmpegBuild"),
                .product(name: "Libswscale", package: "FFmpegBuild"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
			// TODO: Enable -strict-concurrency=complete once the Sendable
			// audit is complete (requires @preconcurrency imports, actor
			// isolation for all @Published properties, and Sendable wrappers
			// for FFmpeg C types).
			// swiftSettings: [.enableExperimentalFeature("StrictConcurrency")],
			path: "TitanPlayer",
			exclude: [
				"Info.plist",
				"TitanPlayer.entitlements",
				"TitanPlayer.Direct.entitlements",
				"Resources/Icon.icns",
				"Resources/Icon-Placeholder",
			],
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

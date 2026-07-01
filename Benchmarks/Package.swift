// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Benchmarks",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Benchmarks", targets: ["Benchmarks"]),
    ],
    targets: [
        .executableTarget(
            name: "Benchmarks",
            path: "Sources/Benchmarks",
            resources: [
                .copy("Baselines"),
            ]
        ),
        .testTarget(
            name: "BenchmarksTests",
            dependencies: ["Benchmarks"],
            path: "Tests"
        ),
    ]
)

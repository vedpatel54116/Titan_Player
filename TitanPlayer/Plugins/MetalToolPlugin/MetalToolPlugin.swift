import PackagePlugin
import Foundation

@main
struct MetalToolPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // Only run for targets that ship Metal shaders.
        let shadersDir = target.directory.appending(["Resources", "Shaders"])
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: shadersDir.string),
              let contents = try? fileManager.contentsOfDirectory(atPath: shadersDir.string) else {
            // No shaders to compile for this target; nothing to do.
            return []
        }

        let metalFiles = contents
            .filter { $0.hasSuffix(".metal") }
            .sorted()
            .map { shadersDir.appending([$0]) }

        guard !metalFiles.isEmpty else { return [] }

        // `xcrun` is a system tool, not a plugin-provided tool, so it cannot be
        // resolved via `context.tool(named:)`. Reference it by absolute path.
        let xcrun = Path("/usr/bin/xcrun")
        let outputDir = context.pluginWorkDirectory
        try fileManager.createDirectory(atPath: outputDir.string, withIntermediateDirectories: true)

        var commands: [Command] = []
        var airPaths: [Path] = []

        for metal in metalFiles {
            let air = outputDir.appending([metal.lastComponent + ".air"])
            airPaths.append(air)
            commands.append(
                .buildCommand(
                    displayName: "Compiling Metal shader \(metal.lastComponent)",
                    executable: xcrun,
                    arguments: [
                        "metal", "-c",
                        "-I", shadersDir.string,
                        "-o", air.string,
                        metal.string,
                    ],
                    inputFiles: [metal],
                    outputFiles: [air]
                )
            )
        }

        let metallib = outputDir.appending(["default.metallib"])
        commands.append(
            .buildCommand(
                displayName: "Linking default.metallib",
                executable: xcrun,
                arguments: {
                    var args = ["metallib"]
                    args.append(contentsOf: airPaths.map(\.string))
                    args += ["-o", metallib.string]
                    return args
                }(),
                inputFiles: airPaths,
                outputFiles: [metallib]
            )
        )

        return commands
    }
}

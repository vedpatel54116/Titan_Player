//
//  MetalShaders.swift
//  TitanPlayer
//
//  Metal shader library management with runtime compilation
//  fallback and shader variant pre-compilation.
//

import Metal
import os.log

final class MetalShaderLibrary {
    private let device: MTLDevice
    private var library: MTLLibrary
    private let logger = Logger(subsystem: "com.titanplayer.app", category: "MetalShaders")

    /// Pre-compiled function cache for shader variants.
    private var functionCache: [String: MTLFunction] = [:]

    init(device: MTLDevice) throws {
        self.device = device

        // Try default.metallib first (pre-compiled at build time)
        if let defaultLibrary = try? device.makeDefaultLibrary() {
            self.library = defaultLibrary
            logger.info("MetalShaderLibrary: Loaded default.metallib")
        } else {
            // Fallback: compile from source at runtime
            logger.warning("MetalShaderLibrary: No default.metallib, compiling from source")
            self.library = try Self.compileSourceLibrary(device: device)
        }

        // Pre-compile shader variants
        precompileVariants()
    }

    /// Look up a function by name (with caching).
    func makeFunction(named name: String) -> MTLFunction? {
        if let cached = functionCache[name] {
            return cached
        }

        guard let function = library.makeFunction(name: name) else {
            logger.error("MetalShaderLibrary: Function not found: \(name)")
            return nil
        }

        functionCache[name] = function
        return function
    }

    /// Pre-compile all shader variants to avoid runtime compilation stalls.
    private func precompileVariants() {
        let variantNames = [
            "video_vertex_shader",
            "video_fragment_shader",
            "ycbcr_to_rgb",
            "hdr_tone_mapping",
            "subtitle_vertex_shader",
            "subtitle_fragment_shader",
        ]

        for name in variantNames {
            if let function = library.makeFunction(name: name) {
                functionCache[name] = function
                logger.info("MetalShaderLibrary: Pre-compiled \(name)")
            } else {
                logger.warning("MetalShaderLibrary: Variant not found: \(name)")
            }
        }
    }

    /// Compile shaders from .metal source files at runtime.
    private static func compileSourceLibrary(device: MTLDevice) throws -> MTLLibrary {
        let sourceFiles = ["Common.metal", "HDR.metal", "Video.metal", "Subtitle.metal"]
        var allSource = ""

        for file in sourceFiles {
            guard let url = Bundle.main.url(forResource: file, withExtension: nil),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            allSource += source + "\n"
        }

        guard !allSource.isEmpty else {
            throw MetalShaderError.noSourceFiles
        }

        do {
            return try device.makeLibrary(source: allSource, options: nil)
        } catch {
            throw MetalShaderError.compilationFailed(error.localizedDescription)
        }
    }
}

enum MetalShaderError: LocalizedError {
    case noSourceFiles
    case compilationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSourceFiles:
            return "No Metal source files found in bundle"
        case .compilationFailed(let reason):
            return "Shader compilation failed: \(reason)"
        }
    }
}

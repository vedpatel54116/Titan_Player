#!/usr/bin/env swift
// scripts/render-placeholder-icon.swift
// Generates a clean baseline placeholder AppIcon for TitanPlayer.
//
// Output:
//   <out-dir>/icon_<size>.png  (AppIcon.appiconset slots)
//   <out-dir>/../Icon-Placeholder/master.png  (1024×1024 master)
//
// Pure-Swift on macOS. Uses Core Graphics only. No third-party deps.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@discardableResult
func writePNG(_ url: URL, _ image: CGImage) -> Bool {
    let type = UTType.png.identifier as CFString
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

func renderIcon(size: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size)

    // Rounded-rect squircle mask (macOS-style icon shape).
    let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                      cornerWidth: s * 0.225, cornerHeight: s * 0.225,
                      transform: nil)

    // Deep blue → near-black background gradient.
    let gradient = CGGradient(colorsSpace: cs,
                              colors: [
                                CGColor(red: 0.10, green: 0.20, blue: 0.55, alpha: 1),
                                CGColor(red: 0.04, green: 0.08, blue: 0.22, alpha: 1)
                              ] as CFArray,
                              locations: [0, 1])!
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient,
                           start: .zero,
                           end: CGPoint(x: 0, y: s),
                           options: [])

    // White play triangle, centered.
    let triW = s * 0.36
    let cx = s / 2
    let cy = s / 2
    let triPath = CGMutablePath()
    triPath.move(to: CGPoint(x: cx - triW * 0.5, y: cy - triW * 0.6))
    triPath.addLine(to: CGPoint(x: cx + triW * 0.5, y: cy))
    triPath.addLine(to: CGPoint(x: cx - triW * 0.5, y: cy + triW * 0.6))
    triPath.closeSubpath()

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.94))
    ctx.addPath(triPath)
    ctx.fillPath()

    return ctx.makeImage()!
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: render-placeholder-icon.swift <out-dir> <sizes...>")
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Argument format expected:
//   <out-dir> <px-size>  <px-size>  ...
// where px-size is one of: 16, 32, 64, 128, 256, 512, 1024.
// Each size is rendered and written with a slot-matching filename.
//
// Slot mapping (matches Apple's macOS asset catalog convention):
//   16  → icon_16x16.png          (16x16, scale 1x — 16 px)
//   32  → icon_16x16@2x.png + icon_32x32.png    (16@2x + 32, both 32 px)
//   64  → icon_32x32@2x.png       (32@2x — 64 px)
//   128 → icon_128x128.png        (128 — 128 px)
//   256 → icon_128x128@2x.png + icon_256x256.png  (128@2x + 256, both 256 px)
//   512 → icon_256x256@2x.png + icon_512x512.png  (256@2x + 512, both 512 px)
//   1024 → icon_512x512@2x.png    (512@2x — 1024 px)
//
// Multiple slots per size lets the same-source image satisfy either
// "logical 16 on Retina" (16@2x) or "logical 32 on non-Retina" (32@1x).

var sizes: [(Int, String)] = []
var i = 2
while i < args.count {
    let s = Int(args[i]) ?? 0
    let names: [String]
    switch s {
    case 16:   names = ["icon_16x16.png"]
    case 32:   names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64:   names = ["icon_32x32@2x.png"]
    case 128:  names = ["icon_128x128.png"]
    case 256:  names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512:  names = ["icon_256x256@2x.png", "icon_512x512.png"]
    case 1024: names = ["icon_512x512@2x.png"]
    default:
        print("skip unrecognized size \(s)")
        i += 1
        continue
    }
    for n in names {
        sizes.append((s, n))
    }
    i += 1
}

// Produce the 1024×1024 master first so the asset catalog slot for it is correct.
// outDir is expected to be `.../Assets.xcassets/AppIcon.appiconset`; we walk up
// twice to land at `.../Resources/Icon-Placeholder/`.
let masterURL = outDir
    .deletingLastPathComponent()                 // AppIcon.appiconset/  → Assets.xcassets/
    .deletingLastPathComponent()                 // Assets.xcassets/     → Resources/
    .appendingPathComponent("Icon-Placeholder")   // Resources/Icon-Placeholder/
    .appendingPathComponent("master.png")
try? FileManager.default.createDirectory(at: masterURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
let master = renderIcon(size: 1024)
if writePNG(masterURL, master) {
    print("wrote \(masterURL.path)")
}

for (s, name) in sizes {
    let img = renderIcon(size: s)
    let url = outDir.appendingPathComponent(name)
    if writePNG(url, img) {
        print("wrote \(url.path)")
    } else {
        fputs("FAILED \(url.path)\n", stderr)
        exit(1)
    }
}

import AppKit
import Foundation

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: generate-app-icon.swift <master.png> <AppIcon.icns>\n", stderr)
    exit(1)
}

let masterPath = CommandLine.arguments[1]
let icnsPath = CommandLine.arguments[2]

guard let src = NSImage(contentsOfFile: masterPath) else {
    fputs("Failed to load master image: \(masterPath)\n", stderr)
    exit(1)
}

let specs: [(pixels: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

let fm = FileManager.default
let icnsURL = URL(fileURLWithPath: icnsPath)
let iconsetURL = icnsURL.deletingLastPathComponent()
    .appendingPathComponent(icnsURL.deletingPathExtension().lastPathComponent + ".iconset")
if fm.fileExists(atPath: iconsetURL.path) {
    try fm.removeItem(at: iconsetURL)
}
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func renderPNG(pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("bitmap create failed\n", stderr)
        exit(1)
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    src.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("png encode failed\n", stderr)
        exit(1)
    }
    return data
}

for spec in specs {
    let data = renderPNG(pixels: spec.pixels)
    let outURL = iconsetURL.appendingPathComponent(spec.name)
    try data.write(to: outURL)
    // Strip xattrs that can make iconutil reject the set
    let procX = Process()
    procX.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
    procX.arguments = ["-cr", outURL.path]
    try? procX.run(); procX.waitUntilExit()
    fputs("wrote \(spec.name) (\(data.count) bytes)\n", stderr)
}

let listed = try fm.contentsOfDirectory(atPath: iconsetURL.path).sorted()
fputs("iconset files (\(listed.count)): \(listed.joined(separator: ", "))\n", stderr)

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsPath]
try proc.run()
proc.waitUntilExit()

if proc.terminationStatus == 0 {
    try? fm.removeItem(at: iconsetURL)
    fputs("Created \(icnsPath)\n", stderr)
} else {
    fputs("iconutil failed (\(proc.terminationStatus)); left \(iconsetURL.path) for inspection\n", stderr)
    exit(proc.terminationStatus)
}

#!/usr/bin/env swift
import AppKit
import Foundation

let rootDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let iconBundle = "\(rootDir)/assets/yacineTV.icon"
let assetsDir = "\(rootDir)/assets"
let iconsetDir = "\(assetsDir)/AppIcon.iconset"
let icnsOut = "\(assetsDir)/AppIcon.icns"
let ictoolPath = "/Applications/Icon Composer.app/Contents/Executables/ictool"

struct IconSlot {
    let filename: String
    let pointSize: Int
    let scale: Int
    var pixelSize: Int { pointSize * scale }
}

let slots: [IconSlot] = [
    IconSlot(filename: "icon_16x16.png", pointSize: 16, scale: 1),
    IconSlot(filename: "icon_16x16@2x.png", pointSize: 16, scale: 2),
    IconSlot(filename: "icon_32x32.png", pointSize: 32, scale: 1),
    IconSlot(filename: "icon_32x32@2x.png", pointSize: 32, scale: 2),
    IconSlot(filename: "icon_128x128.png", pointSize: 128, scale: 1),
    IconSlot(filename: "icon_128x128@2x.png", pointSize: 128, scale: 2),
    IconSlot(filename: "icon_256x256.png", pointSize: 256, scale: 1),
    IconSlot(filename: "icon_256x256@2x.png", pointSize: 256, scale: 2),
    IconSlot(filename: "icon_512x512.png", pointSize: 512, scale: 1),
    IconSlot(filename: "icon_512x512@2x.png", pointSize: 512, scale: 2),
]

@discardableResult
func runProcess(_ launchPath: String, _ args: [String]) throws -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    try proc.run()
    proc.waitUntilExit()
    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard proc.terminationStatus == 0 else {
        throw NSError(
            domain: "IconRender",
            code: Int(proc.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(launchPath) failed: \(stderr) \(stdout)"]
        )
    }
    return stdout
}

func renderRawIcon(rendition: String, pointSize: Int, scale: Int, toURL: URL) throws {
    _ = try runProcess(ictoolPath, [
        iconBundle,
        "--export-image",
        "--output-file", toURL.path,
        "--platform", "macOS",
        "--rendition", rendition,
        "--width", String(pointSize),
        "--height", String(pointSize),
        "--scale", String(scale),
        "--design-generation", "27",
    ])
}

/// Frames an edge-to-edge Liquid Glass `ictool` export into Apple's macOS Dock template
/// (~80.47% inner squircle ratio with classic soft drop shadow) matching standard Tahoe `.icns`.
func composeMacOSDockIcon(from rawURL: URL, canvasPx: Int, toURL: URL) throws {
    let data = try Data(contentsOf: rawURL)
    guard let srcRep = NSBitmapImageRep(data: data), let cgSrc = srcRep.cgImage else {
        throw NSError(domain: "IconRender", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to load \(rawURL.path)"])
    }

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvasPx,
        pixelsHigh: canvasPx,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        throw NSError(domain: "IconRender", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
    }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let canvas = CGFloat(canvasPx)
    let innerSize = round(canvas * (824.0 / 1024.0))
    let originX = (canvas - innerSize) * 0.5
    // Bottom-up CoreGraphics coordinates: slight +0.4% upward shift matches Apple's optical Dock center
    let originY = (canvas - innerSize) * 0.5 + canvas * 0.004
    let drawRect = CGRect(x: originX, y: originY, width: innerSize, height: innerSize)

    ctx.saveGState()
    if canvasPx >= 32 {
        ctx.setShadow(
            offset: CGSize(width: 0, height: -canvas * 0.014),
            blur: max(1.0, canvas * 0.026),
            color: CGColor(gray: 0.0, alpha: 0.28)
        )
    }
    ctx.draw(cgSrc, in: drawRect)
    ctx.restoreGState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRender", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try pngData.write(to: toURL, options: .atomic)
}

func main() throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: iconBundle) else {
        throw NSError(domain: "IconRender", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(iconBundle)"])
    }
    guard fm.fileExists(atPath: ictoolPath) else {
        throw NSError(domain: "IconRender", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(ictoolPath)"])
    }

    if fm.fileExists(atPath: iconsetDir) {
        try fm.removeItem(atPath: iconsetDir)
    }
    try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

    let tmpDir = fm.temporaryDirectory.appendingPathComponent("yacine_ictool_\(UUID().uuidString)")
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    // 1. Render all 10 macOS iconset slots using optical sizing from ictool -> AppIcon.icns
    for slot in slots {
        let rawURL = tmpDir.appendingPathComponent("raw_\(slot.filename)")
        let outURL = URL(fileURLWithPath: "\(iconsetDir)/\(slot.filename)")
        try renderRawIcon(rendition: "Default", pointSize: slot.pointSize, scale: slot.scale, toURL: rawURL)
        try composeMacOSDockIcon(from: rawURL, canvasPx: slot.pixelSize, toURL: outURL)
    }

    _ = try runProcess("/usr/bin/iconutil", ["-c", "icns", iconsetDir, "-o", icnsOut])

    // 2. Render adaptive runtime Dock variants (512x512) & UI sidebar brand marks (128x128)
    let dockDefaultURL = URL(fileURLWithPath: "\(iconsetDir)/icon_256x256@2x.png")
    let outDockDefault = URL(fileURLWithPath: "\(assetsDir)/AppIcon-Default.png")
    if fm.fileExists(atPath: outDockDefault.path) { try fm.removeItem(at: outDockDefault) }
    try fm.copyItem(at: dockDefaultURL, to: outDockDefault)

    let rawDockDark = tmpDir.appendingPathComponent("raw_dock_dark.png")
    try renderRawIcon(rendition: "Dark", pointSize: 256, scale: 2, toURL: rawDockDark)
    try composeMacOSDockIcon(from: rawDockDark, canvasPx: 512, toURL: URL(fileURLWithPath: "\(assetsDir)/AppIcon-Dark.png"))

    try renderRawIcon(rendition: "Default", pointSize: 64, scale: 2, toURL: URL(fileURLWithPath: "\(assetsDir)/AppBrand-Default.png"))
    try renderRawIcon(rendition: "Dark", pointSize: 64, scale: 2, toURL: URL(fileURLWithPath: "\(assetsDir)/AppBrand-Dark.png"))

    print("Generated AppIcon.icns, adaptive Dock variants, and UI brand marks from yacineTV.icon")
}

do {
    try main()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

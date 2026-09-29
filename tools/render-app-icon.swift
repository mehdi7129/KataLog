#!/usr/bin/env swift
import AppKit
import Foundation

// Reuse the exact native symbol displayed in KataLog's sidebar.
// Run from the repository root: swift tools/render-app-icon.swift
let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("assets/icon")
let iconset = destination.appendingPathComponent("KataLog.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    let tile = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 194, yRadius: 194)
    NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    tile.fill()
    let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 500, weight: .medium))!
    let ratio = symbol.size.width / symbol.size.height
    let height: CGFloat = 560
    let target = NSRect(x: (1024 - height * ratio) / 2, y: (1024 - height) / 2, width: height * ratio, height: height)
    context.cgContext.saveGState()
    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
    context.cgContext.setBlendMode(.sourceIn)
    NSBezierPath(rect: target).fill()
    context.cgContext.endTransparencyLayer()
    context.cgContext.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for density in [1, 2] {
        let suffix = density == 2 ? "@2x" : ""
        try render(size: base * density).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
try render(size: 1024).write(to: destination.appendingPathComponent("KataLog-icon-v2.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", destination.appendingPathComponent("KataLog.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Icône créée : \(destination.appendingPathComponent("KataLog.icns").path)")

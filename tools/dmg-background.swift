#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(2) }
let width = 660, height = 420
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
// NSGraphicsContext already maps the bitmap's logical size to its 2x pixels.
// Scaling again would crop the heading and displace the installer artwork.
NSColor(calibratedWhite: 0.967, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, white: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(calibratedWhite: white, alpha: 1)
    ]
    let measure = (value as NSString).size(withAttributes: attributes)
    (value as NSString).draw(at: NSPoint(x: (CGFloat(width) - measure.width) / 2, y: y), withAttributes: attributes)
}
text("Installer KataLog", y: 348, size: 28, weight: .semibold, white: 0.09)
text("Glissez KataLog dans Applications", y: 315, size: 16, weight: .regular, white: 0.38)
NSColor(calibratedWhite: 1, alpha: 1).setFill()
let card = NSBezierPath(roundedRect: NSRect(x: 58, y: 111, width: 544, height: 175), xRadius: 22, yRadius: 22)
card.fill()
NSColor(calibratedWhite: 0.88, alpha: 1).setStroke()
card.lineWidth = 1
card.stroke()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 302, y: 210)); arrow.line(to: NSPoint(x: 356, y: 210))
arrow.move(to: NSPoint(x: 345, y: 221)); arrow.line(to: NSPoint(x: 356, y: 210)); arrow.line(to: NSPoint(x: 345, y: 199))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
NSColor(calibratedRed: 0.22, green: 0.43, blue: 0.34, alpha: 1).setStroke()
arrow.stroke()
text("Éjectez ce disque, puis ouvrez KataLog.", y: 64, size: 13, weight: .regular, white: 0.37)
text("Apple Silicon · macOS 15 ou plus", y: 39, size: 11, weight: .regular, white: 0.48)
NSGraphicsContext.restoreGraphicsState()
let data = bitmap.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

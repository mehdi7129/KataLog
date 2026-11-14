// Standalone platform diagnostic. No KataLog source, private renderer flags,
// alternate backend, or fallback after a failed render.
import AppKit
import Charts
import Foundation
import Metal
import SwiftUI

@main
struct NativeGraphicsProbe {
    static func emit(_ data: [String: Any]) {
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
           let line = String(data: bytes, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }

    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, ["gpu", "text", "canvas", "chart"].contains(arguments[1]) else {
            fputs("Usage: native-graphics-probe gpu|text|canvas|chart OUTPUT_DIRECTORY\n", stderr)
            exit(2)
        }
        let mode = arguments[1]
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        emit(["mode": mode, "phase": "started"])
        if mode == "gpu" {
            let devices: [[String: Any]] = MTLCopyAllDevices().map { device in
                ["name": device.name, "architecture": device.architecture.name,
                 "registryID": String(device.registryID), "lowPower": device.isLowPower,
                 "headless": device.isHeadless, "hasUnifiedMemory": device.hasUnifiedMemory,
                 "supportsMac2": device.supportsFamily(.mac2), "supportsMetal3": device.supportsFamily(.metal3)]
            }
            let result: [String: Any] = ["mode": mode, "phase": "completed", "devices": devices,
                "defaultDevicePresent": MTLCreateSystemDefaultDevice() != nil,
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("gpu.json"), options: .atomic)
            emit(result)
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let content: AnyView
        switch mode {
        case "text":
            content = AnyView(Text("KataLog renderer probe").font(.system(size: 24)).foregroundStyle(.black))
        case "canvas":
            content = AnyView(Canvas { context, size in
                context.fill(Path(ellipseIn: CGRect(x: 20, y: 20, width: size.width - 40,
                                                    height: size.height - 40)), with: .color(.green))
            })
        case "chart":
            content = AnyView(Chart {
                LineMark(x: .value("Time", 0), y: .value("Value", 1))
                LineMark(x: .value("Time", 1), y: .value("Value", 3))
                LineMark(x: .value("Time", 2), y: .value("Value", 2))
            }.padding(20))
        default:
            fatalError("Validated mode")
        }
        let host = NSHostingView(rootView: content.frame(width: 320, height: 240)
            .background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        emit(["mode": mode, "phase": "window-created"])
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "NativeGraphicsProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No bitmap for native view"])
        }
        emit(["mode": mode, "phase": "before-cache-display"])
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 256 else {
            throw NSError(domain: "NativeGraphicsProbe", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Missing or empty native bitmap"])
        }
        // Check actual pixel diversity, not just a valid PNG container.
        var colors = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        guard colors.count > 1 else {
            throw NSError(domain: "NativeGraphicsProbe", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Native render is a uniform bitmap"])
        }
        try png.write(to: output.appendingPathComponent(mode + ".png"), options: .atomic)
        window.close()
        emit(["mode": mode, "phase": "completed", "pngBytes": png.count,
              "distinctSampledColors": colors.count, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh])
    }
}

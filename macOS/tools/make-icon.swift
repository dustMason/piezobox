import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Icon context failed") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let s = CGFloat(pixels)
        NSColor(calibratedRed: 0.04, green: 0.19, blue: 0.19, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88),
                     xRadius: s * 0.20, yRadius: s * 0.20).fill()
        let lengths: [CGFloat] = [0.10, 0.26, 0.58, 0.38, 0.15, 0.31, 0.09]
        NSColor(calibratedRed: 0.45, green: 0.96, blue: 0.78, alpha: 1).setStroke()
        for (index, length) in lengths.enumerated() {
            let x = s * (0.24 + CGFloat(index) * 0.087)
            let line = NSBezierPath()
            line.lineWidth = max(1, s * 0.043)
            line.lineCapStyle = .round
            line.move(to: NSPoint(x: x, y: s * (0.5 - length / 2)))
            line.line(to: NSPoint(x: x, y: s * (0.5 + length / 2)))
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon rendering failed") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

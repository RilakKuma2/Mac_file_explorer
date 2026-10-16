#!/usr/bin/env swift

import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make-rounded-app-icon.swift <source.png> <output.png>\n", stderr)
    exit(2)
}

let sourcePath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
guard let source = NSImage(contentsOfFile: sourcePath) else {
    fputs("could not load source image: \(sourcePath)\n", stderr)
    exit(1)
}

let canvasSize = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("could not create output bitmap\n", stderr)
    exit(1)
}

bitmap.size = canvasSize
guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("could not create graphics context\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
graphics.imageInterpolation = .high
graphics.cgContext.clear(CGRect(origin: .zero, size: canvasSize))

// Apple's pre-Tahoe macOS production grid uses an approximately 824 × 824
// rounded-square artwork area on the 1024 × 1024 icon canvas. Keeping this
// transparent margin makes the result match the optical size of system icons.
let iconRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let mask = NSBezierPath(roundedRect: iconRect, xRadius: 185, yRadius: 185)
mask.addClip()
source.draw(
    in: iconRect,
    from: NSRect(origin: .zero, size: source.size),
    operation: .copy,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)
graphics.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not encode output PNG\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
} catch {
    fputs("could not write output: \(error.localizedDescription)\n", stderr)
    exit(1)
}

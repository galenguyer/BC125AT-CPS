import AppKit

// GitHub social preview: 1280×640, the app icon beside the name and a tagline.
// Usage: swift scripts/make-social-preview.swift <icon_1024.png> <output.png>
let width = 1280, height = 640
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

// A darker navy than the icon's gradient, so the icon stands out against it.
NSGradient(colors: [NSColor(srgbRed: 0.02, green: 0.05, blue: 0.12, alpha: 1), NSColor(srgbRed: 0.05, green: 0.14, blue: 0.30, alpha: 1)])!
    .draw(in: CGRect(x: 0, y: 0, width: width, height: height), angle: 90)

// The icon's 1024 canvas has a 100 pt margin around the squircle, so drawing it at 560
// puts the visible body at about 450, centered vertically.
let icon = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 36
shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
shadow.set()
icon.draw(in: CGRect(x: 30, y: 40, width: 560, height: 560))
NSShadow().set()

let title = NSAttributedString(string: "BC125AT CPS", attributes: [
    .font: NSFont.systemFont(ofSize: 92, weight: .bold),
    .foregroundColor: NSColor.white,
])
let tagline = NSAttributedString(string: "Program your Uniden BC125AT\nscanner from your Mac", attributes: [
    .font: NSFont.systemFont(ofSize: 40, weight: .medium),
    .foregroundColor: NSColor(white: 1, alpha: 0.78),
    .paragraphStyle: { let style = NSMutableParagraphStyle(); style.lineSpacing = 6; return style }(),
])
let textLeft: CGFloat = 610
title.draw(at: CGPoint(x: textLeft, y: 340))
tagline.draw(in: CGRect(x: textLeft, y: 200, width: CGFloat(width) - textLeft - 40, height: 120))

// A little Clawd in the bottom-right corner, from Claude Code's banner. Each pixel is one
// quadrant of a block character, so pixels are twice as tall as they are wide; the gaps
// in the top row are its eyes.
let clawd = [
    "   ############   ",
    "   ## ###### ##   ",
    " ################ ",
    "   ############   ",
    "    # #    # #    ",
]
let pixel: CGFloat = 6
let clawdOrigin = CGPoint(x: 1196 - CGFloat(clawd[0].count) * pixel, y: 90)
NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
for (row, line) in clawd.enumerated() {
    for (column, character) in line.enumerated() where character == "#" {
        CGRect(x: clawdOrigin.x + CGFloat(column) * pixel,
               y: clawdOrigin.y + CGFloat(clawd.count - 1 - row) * pixel * 2,
               width: pixel, height: pixel * 2).fill()
    }
}

NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))

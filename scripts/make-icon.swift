import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824×824 body, 100 pt margin, continuous-corner radius ≈ 185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
squircle.addClip()
NSGradient(colors: [NSColor(srgbRed: 0.04, green: 0.12, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.12, green: 0.38, blue: 0.72, alpha: 1)])!
    .draw(in: body, angle: 90)

// Radio waves from the antenna tip.
let tip = CGPoint(x: 432, y: 800)
for (i, radius) in [62.0, 114.0, 166.0].enumerated() {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: tip, radius: radius, startAngle: -35, endAngle: 35)
    arc.lineWidth = 26
    arc.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.9 - Double(i) * 0.25).setStroke()
    arc.stroke()
}

// Antenna.
let antenna = NSBezierPath()
antenna.move(to: CGPoint(x: 432, y: 640))
antenna.line(to: tip)
antenna.lineWidth = 34
antenna.lineCapStyle = .round
NSColor(white: 0.12, alpha: 1).setStroke()
antenna.stroke()

// Scanner body with a soft shadow.
let scanner = CGRect(x: 352, y: 175, width: 320, height: 490)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor(white: 0.13, alpha: 1).setFill()
NSBezierPath(roundedRect: scanner, xRadius: 56, yRadius: 56).fill()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])!
    .draw(in: NSBezierPath(roundedRect: scanner.insetBy(dx: 6, dy: 6), xRadius: 50, yRadius: 50), angle: 90)

// Amber LCD showing a frequency.
let lcd = CGRect(x: 384, y: 480, width: 256, height: 140)
NSColor(srgbRed: 0.98, green: 0.66, blue: 0.16, alpha: 1).setFill()
NSBezierPath(roundedRect: lcd, xRadius: 18, yRadius: 18).fill()
let text = NSAttributedString(string: "162.550", attributes: [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 50, weight: .heavy),
    .foregroundColor: NSColor(srgbRed: 0.25, green: 0.13, blue: 0.0, alpha: 0.9),
])
let textSize = text.size()
text.draw(at: CGPoint(x: lcd.midX - textSize.width / 2, y: lcd.midY - textSize.height / 2))

// Keypad.
NSColor(white: 0.32, alpha: 1).setFill()
for row in 0..<3 {
    for column in 0..<3 {
        let key = CGRect(x: 400 + CGFloat(column) * 80, y: 225 + CGFloat(row) * 75, width: 64, height: 50)
        NSBezierPath(roundedRect: key, xRadius: 14, yRadius: 14).fill()
    }
}
ctx.restoreGState()
image.unlockFocus()

let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

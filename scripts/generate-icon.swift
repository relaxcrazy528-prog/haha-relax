import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { rect in
            let s = rect.width / 1024
            let face = NSBezierPath(roundedRect: rect.insetBy(dx: 32*s, dy: 32*s), xRadius: 210*s, yRadius: 210*s)
            let gradient = NSGradient(starting: NSColor(srgbRed: 1, green: 0.24, blue: 0.28, alpha: 1), ending: NSColor(srgbRed: 0.86, green: 0.07, blue: 0.13, alpha: 1))!
            gradient.draw(in: face, angle: -90)
            NSColor.white.setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 512*s, y: 475*s), radius: 225*s, startAngle: 135, endAngle: 405)
            arc.lineWidth = 70*s
            arc.lineCapStyle = .round
            arc.stroke()
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: 512*s, y: 760*s))
            stem.line(to: NSPoint(x: 512*s, y: 490*s))
            stem.lineWidth = 70*s
            stem.lineCapStyle = .round
            stem.stroke()
            return true
        }
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot draw icon") }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: destination.appendingPathComponent(name))
    }
}

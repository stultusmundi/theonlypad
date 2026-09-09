// Original geometric application artwork, MIT. No third-party assets.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = AffineTransform(scale: factor)
        (transform as NSAffineTransform).concat()
        let body = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 190, yRadius: 190)
        NSGradient(starting: NSColor(calibratedRed: 0.21, green: 0.27, blue: 0.48, alpha: 1),
                   ending: NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.24, alpha: 1))!.draw(in: body, angle: 90)
        let page = NSBezierPath(roundedRect: NSRect(x: 236, y: 192, width: 552, height: 640), xRadius: 36, yRadius: 36)
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        page.fill()
        NSColor(calibratedRed: 0.65, green: 0.70, blue: 0.80, alpha: 1).setFill()
        for (index, width) in [326, 238, 326, 188].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 326, y: 672 - index * 100, width: width, height: 24), xRadius: 12, yRadius: 12).fill()
        }
        NSColor(calibratedRed: 0.94, green: 0.43, blue: 0.26, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 552, y: 344, width: 28, height: 88), xRadius: 10, yRadius: 10).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
    }
}

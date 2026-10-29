// Draws the app icon ("stepping stones": Codex's >_ jumps from a sunk, used-up account to the next one)
// and packs every size into an .icns. Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let navy = CGColor(srgbRed: 0.043, green: 0.165, blue: 0.271, alpha: 1)
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Artwork is designed on a 180-unit square (the icon body); the body sits in Apple's 824/1024 grid.
func draw(_ c: CGContext, size: CGFloat) {
    let s = size / 1024, k = 824.0 / 180 * s
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 100 * s + (x - 40) * k, y: 100 * s + (y - 30) * k) }
    func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGRect {
        CGRect(x: p(cx, cy).x - rx * k, y: p(cx, cy).y - ry * k, width: 2 * rx * k, height: 2 * ry * k)
    }
    c.translateBy(x: 0, y: size); c.scaleBy(x: 1, y: -1)   // y grows downward, like the SVG it came from

    let body = CGPath(roundedRect: CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                      cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: rgb(0x000000, 0.35))
    c.addPath(body); c.setFillColor(navy); c.fillPath()
    c.restoreGState()
    c.addPath(body); c.clip()

    // The used-up account: a pink stone sinking, with ripples.
    c.setLineWidth(1.5 * k)
    c.setStrokeColor(rgb(0xffffff, 0.12)); c.strokeEllipse(in: ellipse(80, 170, 30, 8))
    c.setStrokeColor(rgb(0xffffff, 0.25)); c.strokeEllipse(in: ellipse(80, 170, 20, 5.5))
    c.setFillColor(rgb(0xff2ebd, 0.4)); c.fillEllipse(in: ellipse(80, 171, 12, 3.5))
    // The account that takes over, and the next one.
    c.setFillColor(rgb(0x8c9600)); c.fillEllipse(in: ellipse(132, 168, 21, 7))
    c.setFillColor(rgb(0xedff0d)); c.fillEllipse(in: ellipse(132, 163, 21, 7))
    c.setFillColor(rgb(0x1f8a00)); c.fillEllipse(in: ellipse(183, 157, 17, 6))
    c.setFillColor(rgb(0x3dff0d)); c.fillEllipse(in: ellipse(183, 153, 17, 6))
    // The jump.
    if size >= 64 {
        c.saveGState()
        c.setStrokeColor(rgb(0xffffff, 0.75)); c.setLineWidth(3 * k); c.setLineCap(.round)
        c.setLineDash(phase: 0, lengths: [0.5 * k, 8 * k])
        c.move(to: p(80, 162)); c.addQuadCurve(to: p(128, 150), control: p(98, 64)); c.strokePath()
        c.restoreGState()
    }
    // Codex's >_ mid-air.
    c.saveGState()
    c.translateBy(x: p(106, 84).x, y: p(106, 84).y); c.rotate(by: 14 * .pi / 180); c.translateBy(x: -p(106, 84).x, y: -p(106, 84).y)
    c.addPath(CGPath(roundedRect: CGRect(origin: p(86, 64), size: CGSize(width: 40 * k, height: 40 * k)),
                     cornerWidth: 10 * k, cornerHeight: 10 * k, transform: nil))
    c.setFillColor(rgb(0xffffff)); c.fillPath()
    c.setStrokeColor(navy); c.setLineWidth(4.5 * k); c.setLineCap(.square); c.setLineJoin(.miter)
    c.move(to: p(96, 76)); c.addLine(to: p(104, 84)); c.addLine(to: p(96, 92)); c.strokePath()
    c.setFillColor(navy); c.fill(CGRect(origin: p(108, 89), size: CGSize(width: 11 * k, height: 4 * k)))
    c.restoreGState()
}

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext, size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run(); iconutil.waitUntilExit()
if let preview = ProcessInfo.processInfo.environment["ICON_PREVIEW"] { try png(1024).write(to: URL(fileURLWithPath: preview)) }
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)

// Draws the app icon (Tibot's mascot, 「终端团子」, standing on the stone of the account in use, the next
// stone waiting) and packs every size into an .icns. Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
func gradient(_ c: CGContext, _ top: CGColor, _ bottom: CGColor, from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: from, end: to, options: [])
}

/// Artwork is designed on a 180-unit square (the icon body); the body sits in Apple's 824/1024 grid.
func draw(_ c: CGContext, size: CGFloat) {
    let s = size / 1024, k = 824.0 / 180 * s, detailed = size >= 64
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 100 * s + x * k, y: 100 * s + y * k) }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(origin: p(x, y), size: CGSize(width: w * k, height: h * k)) }
    func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGRect { rect(cx - rx, cy - ry, 2 * rx, 2 * ry) }
    c.translateBy(x: 0, y: size); c.scaleBy(x: 1, y: -1)   // y grows downward

    let body = CGPath(roundedRect: CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                      cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: rgb(0x000000, 0.3))
    c.addPath(body); c.setFillColor(rgb(0xe3f8eb)); c.fillPath()
    c.restoreGState()
    c.addPath(body); c.clip()
    gradient(c, rgb(0xf2fdf6), rgb(0xc9f0d8), from: p(0, 0), to: p(0, 180))

    // The next stone, waiting on the right.
    c.setFillColor(rgb(0x1f9a43, 0.4)); c.fillEllipse(in: ellipse(153, 140, 12, 4))
    c.setFillColor(rgb(0x30d158, 0.5)); c.fillEllipse(in: ellipse(153, 137.8, 12, 4))
    // The stone in use.
    c.setFillColor(rgb(0x1f9a43)); c.fillEllipse(in: ellipse(82, 150, 46, 11))
    c.setFillColor(rgb(0x30d158)); c.fillEllipse(in: ellipse(82, 145, 46, 11))
    c.setFillColor(rgb(0x000000, 0.18)); c.fillEllipse(in: ellipse(82, 143, 33, 4.5))

    // The mascot: a soft dark tile, 92 units, on the stone.
    let d: CGFloat = 96, x0: CGFloat = 82 - d / 2, y0: CGFloat = 143 - d
    func m(_ fx: CGFloat, _ fy: CGFloat) -> (CGFloat, CGFloat) { (x0 + fx * d, y0 + fy * d) }
    let tile = CGPath(roundedRect: rect(x0, y0, d, d), cornerWidth: 0.3 * d * k, cornerHeight: 0.3 * d * k, transform: nil)
    c.saveGState()
    c.addPath(tile); c.clip()
    gradient(c, rgb(0x2e2e31), rgb(0x141416), from: p(0, y0), to: p(0, y0 + d))
    if detailed { c.setFillColor(rgb(0xffffff, 0.045)); c.fillEllipse(in: ellipse(x0 + 0.5 * d, y0 + 0.02 * d, 0.46 * d, 0.14 * d)) }
    c.restoreGState()
    for side: CGFloat in [-1, 1] {
        let (cx, ey) = m(0.5 + side * 0.2, 0.42), er = 0.105 * d
        c.setFillColor(rgb(0xffffff)); c.fillEllipse(in: ellipse(cx, ey, er, er * 1.15))
        let pr = er * 0.55
        c.setFillColor(rgb(0x1a1a1c)); c.fillEllipse(in: ellipse(cx + 0.02 * d, ey + 0.012 * d, pr, pr))
        if detailed { c.setFillColor(rgb(0xffffff)); c.fillEllipse(in: ellipse(cx + 0.036 * d, ey - 0.02 * d, pr * 0.36, pr * 0.36)) }
        let (bx, by) = m(0.5 + side * 0.33, 0.64)
        c.setFillColor(rgb(0xff8fa3, 0.8)); c.fillEllipse(in: ellipse(bx, by, 0.085 * d, 0.048 * d))
    }
    let (mx, my) = m(0.41, 0.68)
    c.addPath(CGPath(roundedRect: rect(mx, my, 0.18 * d, 0.05 * d), cornerWidth: 0.025 * d * k, cornerHeight: 0.025 * d * k, transform: nil))
    c.setFillColor(rgb(0x30d158)); c.fillPath()
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

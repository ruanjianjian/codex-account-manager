// Draws the app icon (Tibot's mascot peeking over the stone of the account in use) and packs every size into an
// .icns. Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Artwork is designed on a 160-unit square (the icon body); the body sits in Apple's 824/1024 grid.
func draw(_ c: CGContext, size: CGFloat) {
    let s = size / 1024, k = 824.0 / 160 * s
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: 100 * s + x * k, y: 100 * s + y * k, width: w * k, height: h * k)
    }
    func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: UInt32) {
        c.setFillColor(rgb(color)); c.fillEllipse(in: rect(cx - rx, cy - ry, 2 * rx, 2 * ry))
    }
    c.translateBy(x: 0, y: size); c.scaleBy(x: 1, y: -1)   // y grows downward

    let body = CGPath(roundedRect: CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                      cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: rgb(0x000000, 0.3))
    c.addPath(body); c.setFillColor(rgb(0xededed)); c.fillPath()
    c.restoreGState()
    c.addPath(body); c.clip()

    // The mascot, a soft black tile, looking right at the next account.
    c.addPath(CGPath(roundedRect: rect(40, 40, 80, 80), cornerWidth: 26 * k, cornerHeight: 26 * k, transform: nil))
    c.setFillColor(rgb(0x111111)); c.fillPath()
    for x: CGFloat in [66, 94] { oval(x, 68, 8.5, 8.5, 0xffffff); oval(x + 4, 69, 3.6, 3.6, 0x111111) }
    // The stone it hides behind, and its hands on top.
    oval(80, 116, 60, 28, 0x8e8e93); oval(80, 103, 52, 14, 0xaeaeb2)
    oval(52, 92, 8, 6, 0x111111); oval(108, 92, 8, 6, 0x111111)
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

import AppKit

/// The menu-bar mark: the app icon's >_ tile between stepping stones, as template images so macOS
/// tints them for light, dark and highlighted menu bars. While requests are routed the tile hops.
enum StatusIcon {
    static let image = make(tile: CGPoint(x: 9.5, y: 5.8), angle: 14, trail: true)

    /// One hop from the used-up stone to the next, then a short rest on landing.
    static let hop: [NSImage] = {
        let steps = 10
        let flight = (0..<steps).map { i -> NSImage in
            let t = CGFloat(i) / CGFloat(steps - 1)
            let x = 4.4 + (10.4 - 4.4) * t
            let y = 9.2 - 4 * 5.4 * t * (1 - t)          // a parabola peaking 5.4pt above the stones
            return make(tile: CGPoint(x: x, y: y), angle: -16 + 30 * t, trail: false)
        }
        return flight + Array(repeating: flight[steps - 1], count: 3)
    }()

    private static func make(tile: CGPoint, angle: CGFloat, trail: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.setFillColor(NSColor.black.cgColor)
            // Stones: the used-up one faint, the one landed on solid, the next one smaller.
            c.setAlpha(0.35); c.fillEllipse(in: CGRect(x: 0.5, y: 14.6, width: 4.5, height: 1.6))
            c.setAlpha(1); c.fillEllipse(in: CGRect(x: 7.2, y: 13.6, width: 6.6, height: 2.6))
            c.fillEllipse(in: CGRect(x: 14.2, y: 11.8, width: 3.6, height: 1.8))
            if trail {
                for dot in [CGPoint(x: 2.6, y: 12.6), CGPoint(x: 3.0, y: 10.2), CGPoint(x: 3.9, y: 8.0)] {
                    c.fillEllipse(in: CGRect(x: dot.x - 0.55, y: dot.y - 0.55, width: 1.1, height: 1.1))
                }
            }
            // The >_ tile, with the prompt cut out.
            c.translateBy(x: tile.x, y: tile.y); c.rotate(by: angle * .pi / 180)
            c.addPath(CGPath(roundedRect: CGRect(x: -4.3, y: -4.3, width: 8.6, height: 8.6), cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
            c.fillPath()
            c.setBlendMode(.clear); c.setLineWidth(1.3); c.setLineCap(.square)
            c.move(to: CGPoint(x: -2.2, y: -2.0)); c.addLine(to: CGPoint(x: -0.3, y: 0)); c.addLine(to: CGPoint(x: -2.2, y: 2.0)); c.strokePath()
            c.fill(CGRect(x: 0.6, y: 1.5, width: 2.2, height: 1.1))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex Accounts"
        return image
    }
}

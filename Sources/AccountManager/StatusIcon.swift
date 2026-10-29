import AppKit

/// The menu-bar mark: the app icon's >_ tile mid-jump between stepping stones, as a template image
/// so macOS tints it for light, dark and highlighted menu bars.
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.setFillColor(NSColor.black.cgColor)
            // Stones: the used-up one faint, the one landed on solid, the next one smaller.
            c.setAlpha(0.35); c.fillEllipse(in: CGRect(x: 0.5, y: 14.6, width: 4.5, height: 1.6))
            c.setAlpha(1); c.fillEllipse(in: CGRect(x: 7.2, y: 13.6, width: 6.6, height: 2.6))
            c.fillEllipse(in: CGRect(x: 14.2, y: 11.8, width: 3.6, height: 1.8))
            // The jump.
            for dot in [CGPoint(x: 2.6, y: 12.6), CGPoint(x: 3.0, y: 10.2), CGPoint(x: 3.9, y: 8.0)] {
                c.fillEllipse(in: CGRect(x: dot.x - 0.55, y: dot.y - 0.55, width: 1.1, height: 1.1))
            }
            // The >_ tile, with the prompt cut out.
            c.translateBy(x: 9.5, y: 5.8); c.rotate(by: 14 * .pi / 180)
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
    }()
}

import AppKit

/// The menu-bar mark: the app icon's >_ tile between stepping stones, as template images so macOS
/// tints them for light, dark and highlighted menu bars. While requests are routed the tile keeps
/// crossing: it leaves a stone that sinks (an account used up), lands on the next, and the stones
/// move along so a new one surfaces on the right.
enum StatusIcon {
    private struct Stone { var x, y, w, h, alpha: CGFloat }

    static let image = make(stones: [Stone(x: 2.75, y: 15.4, w: 4.5, h: 1.6, alpha: 0.35),
                                     Stone(x: 10.5, y: 14.9, w: 6.6, h: 2.6, alpha: 1),
                                     Stone(x: 16, y: 12.7, w: 3.6, h: 1.8, alpha: 1)],
                            tile: CGPoint(x: 9.5, y: 5.8), angle: 14, trail: true)

    // Stone slots, left to right, and where a new stone surfaces from.
    private static let left = Stone(x: 4.4, y: 15.3, w: 5.4, h: 2.2, alpha: 1)
    private static let middle = Stone(x: 10.6, y: 14.9, w: 6.6, h: 2.6, alpha: 1)
    private static let right = Stone(x: 16, y: 12.7, w: 3.6, h: 1.8, alpha: 1)
    private static let surfacing = Stone(x: 19, y: 11.6, w: 2, h: 1, alpha: 0)
    private static func resting(on stone: Stone) -> CGPoint { CGPoint(x: stone.x, y: stone.y - stone.h / 2 - 4.3) }

    /// One crossing: hop, land, the stones move along, rest. The last frame matches the first.
    static let hop: [NSImage] = {
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        func mix(_ a: Stone, _ b: Stone, _ t: CGFloat) -> Stone {
            Stone(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t), w: mix(a.w, b.w, t), h: mix(a.h, b.h, t), alpha: mix(a.alpha, b.alpha, t))
        }
        let sunk = Stone(x: left.x, y: left.y + 0.6, w: left.w * 0.8, h: left.h * 0.8, alpha: 0.3)
        let from = resting(on: left), to = resting(on: middle)
        let hopping = (0..<10).map { i -> NSImage in
            let t = CGFloat(i) / 9
            let tile = CGPoint(x: mix(from.x, to.x, t), y: mix(from.y, to.y, t) - 4 * 5 * t * (1 - t))
            return make(stones: [mix(left, sunk, t), middle, right], tile: tile, angle: 18 * sin(.pi * t), trail: false)
        }
        let gone = Stone(x: sunk.x - 4, y: sunk.y + 0.4, w: sunk.w * 0.6, h: sunk.h * 0.6, alpha: 0)
        let moving = (1...6).map { i -> NSImage in
            let u = CGFloat(i) / 6, eased = u * u * (3 - 2 * u)
            return make(stones: [mix(sunk, gone, eased), mix(middle, left, eased), mix(right, middle, eased), mix(surfacing, right, eased)],
                        tile: CGPoint(x: mix(to.x, from.x, eased), y: mix(to.y, from.y, eased)), angle: 0, trail: false)
        }
        return hopping + [hopping[9], hopping[9]] + moving + [moving[5], moving[5]]
    }()

    private static func make(stones: [Stone], tile: CGPoint, angle: CGFloat, trail: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.setFillColor(NSColor.black.cgColor)
            for stone in stones where stone.alpha > 0.01 {
                c.setAlpha(stone.alpha)
                c.fillEllipse(in: CGRect(x: stone.x - stone.w / 2, y: stone.y - stone.h / 2, width: stone.w, height: stone.h))
            }
            c.setAlpha(1)
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

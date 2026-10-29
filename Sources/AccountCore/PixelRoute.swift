import Foundation

/// Integer cell geometry for the pixel routing animation. Drawing lives in the app.
public enum PixelRoute {
    public struct Cell: Equatable, Hashable, Sendable {
        public let x: Int
        public let y: Int
        public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    }

    /// Orthogonal polyline through the corners, one cell per step, no repeated cells.
    public static func path(_ corners: [Cell]) -> [Cell] {
        guard var current = corners.first else { return [] }
        var cells = [current]
        for corner in corners.dropFirst() {
            while current != corner {
                if current.x != corner.x { current = Cell(current.x + (corner.x > current.x ? 1 : -1), current.y) }
                else { current = Cell(current.x, current.y + (corner.y > current.y ? 1 : -1)) }
                cells.append(current)
            }
        }
        return cells
    }

    /// Stable across launches (unlike String.hashValue), so concurrent rockets keep their spacing.
    public static func offset(for request: String) -> Double {
        Double(request.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 997 }) / 997
    }

    /// Head index of a rocket that flies the whole route once every `period` seconds.
    public static func head(time: Double, offset: Double, count: Int, period: Double = 1.6) -> Int {
        guard count > 1, period > 0 else { return 0 }
        var phase = (time / period + offset).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        return min(count - 1, Int(phase * Double(count - 1)))
    }

    /// Ring radius in cells and opacity of an explosion `age` seconds old; nil once it is over.
    public static func burst(age: Double, duration: Double = 0.5, reach: Double = 5) -> (radius: Double, alpha: Double)? {
        guard age >= 0, age < duration else { return nil }
        let progress = age / duration
        return (1 + progress * reach, 1 - progress)
    }
}

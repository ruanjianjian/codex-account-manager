import Foundation
import CoreGraphics

/// All geometry uses AppKit global screen coordinates, including negative origins.
public enum WidgetPlacement {
    /// Keep the preferred size separate from the per-display constraint so a
    /// temporary smaller monitor never overwrites the user's chosen dimensions.
    public static func fittedSize(_ preferred: CGSize, visibleFrame: CGRect?) -> CGSize {
        let available = visibleFrame?.size ?? CGSize(width: 4096, height: 4096)
        let width = preferred.width.isFinite ? preferred.width : 448
        let height = preferred.height.isFinite ? preferred.height : 892
        return CGSize(width: min(max(400, width), max(1, available.width - 16)),
                      height: min(max(480, height), max(1, available.height - 16)))
    }

    public static func screenIndex(containing point: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    /// The embedded component sits beside macOS's own desktop widgets (two small
    /// widgets wide from the left edge), tops aligned with them.
    public static func embeddedOrigin(panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let left = visibleFrame.minX + 8
        let x = max(left, min(visibleFrame.minX + 378, visibleFrame.maxX - panelSize.width - 8))
        let y = max(visibleFrame.minY + 8, visibleFrame.maxY - panelSize.height - 10)
        return CGPoint(x: x, y: y)
    }

    /// Settings and other windows open beside the dashboard, tops aligned: on its left when
    /// there is room, otherwise on its right, otherwise centred on the screen.
    public static func besideOrigin(windowSize: CGSize, anchor: CGRect?, visibleFrame: CGRect) -> CGPoint {
        let gap: CGFloat = 10
        let centred = CGPoint(x: visibleFrame.midX - windowSize.width / 2, y: visibleFrame.midY - windowSize.height / 2)
        guard let anchor, visibleFrame.intersects(anchor) else { return centred }
        let y = max(visibleFrame.minY, min(anchor.maxY - windowSize.height, visibleFrame.maxY - windowSize.height))
        if anchor.minX - gap - windowSize.width >= visibleFrame.minX { return CGPoint(x: anchor.minX - gap - windowSize.width, y: y) }
        if anchor.maxX + gap + windowSize.width <= visibleFrame.maxX { return CGPoint(x: anchor.maxX + gap, y: y) }
        return centred
    }

    public static func origin(near point: CGPoint, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let inset: CGFloat = 8
        let left = visibleFrame.minX + inset
        let bottom = visibleFrame.minY + inset
        let right = max(left, visibleFrame.maxX - panelSize.width - inset)
        let top = max(bottom, visibleFrame.maxY - panelSize.height - inset)
        return CGPoint(x: max(left, min(point.x - panelSize.width / 2, right)), y: top)
    }
}

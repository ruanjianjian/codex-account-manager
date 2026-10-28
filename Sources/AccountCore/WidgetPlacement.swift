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

    public static func origin(near point: CGPoint, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let inset: CGFloat = 8
        let left = visibleFrame.minX + inset
        let bottom = visibleFrame.minY + inset
        let right = max(left, visibleFrame.maxX - panelSize.width - inset)
        let top = max(bottom, visibleFrame.maxY - panelSize.height - inset)
        return CGPoint(x: max(left, min(point.x - panelSize.width / 2, right)), y: top)
    }
}

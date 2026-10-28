import Foundation
import CoreGraphics

/// Time-based hover transitions, independent of AppKit enter/exit delivery.
public struct PanelHover {
    public enum Action: Equatable { case show, hide }
    private var enteredAt: TimeInterval?
    private var leftAt: TimeInterval?
    private var suppressedUntilExit = false
    public init() {}

    /// A click/shortcut dismissal must not immediately reopen under the pointer.
    public mutating func suppressUntilExit() {
        suppressedUntilExit = true; enteredAt = nil; leftAt = nil
    }
    public mutating func sample(now: TimeInterval, overTrigger: Bool, overPanel: Bool,
                                visible: Bool, needsShow: Bool, pinned: Bool,
                                interacting: Bool) -> Action? {
        if !overTrigger { enteredAt = nil; suppressedUntilExit = false }
        if interacting { enteredAt = nil; leftAt = nil; return nil }
        if overTrigger {
            leftAt = nil
            guard needsShow, !suppressedUntilExit else { return nil }
            if enteredAt == nil { enteredAt = now }
            if now - (enteredAt ?? now) >= 0.18 {
                suppressedUntilExit = true; enteredAt = nil; return .show
            }
        } else if overPanel || pinned || !visible {
            leftAt = nil
        } else {
            if leftAt == nil { leftAt = now }
            if now - (leftAt ?? now) >= 0.35 { leftAt = nil; return .hide }
        }
        return nil
    }

    public static func appKitRect(fromQuartz rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
}

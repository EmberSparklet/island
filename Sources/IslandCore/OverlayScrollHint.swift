import Foundation

/// Whether the overlay should show its "more below" hint. Pure geometry, so
/// the AppKit side only feeds it the clip view's numbers.
public enum OverlayScrollHint {
    /// `offsetY` is measured from the top of the content (flipped document
    /// view); the hint shows while anything is still below the visible part.
    public static func shouldShow(offsetY: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat)
        -> Bool
    {
        contentHeight > visibleHeight + 1 && offsetY + visibleHeight < contentHeight - 1
    }
}

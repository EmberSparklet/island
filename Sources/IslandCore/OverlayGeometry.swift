import CoreGraphics

/// Window geometry for the overlay panel.
///
/// The window is exactly the capsule. Its background is an
/// `NSVisualEffectView` clipped to the capsule shape (see
/// `CapsuleShapeView.maskImage`), which paints nothing outside that shape and
/// draws no shadow of its own — so there is no margin to reserve and no
/// transparent area for clicks to fall through.
///
/// The Liquid Glass material this replaced did draw a soft shadow of its own, so
/// it needed extra window around the capsule plus click-through in that margin.
/// See issue `glass-shadow-clipped-panel-edge`.
public enum OverlayGeometry {
    /// Window origin that keeps the capsule's top edge at `capsuleTop` and the
    /// capsule centred on `centerX`.
    public static func windowOrigin(
        capsuleTop: CGFloat, centerX: CGFloat, content: CGSize
    ) -> CGPoint {
        CGPoint(x: centerX - content.width / 2, y: capsuleTop - content.height)
    }
}

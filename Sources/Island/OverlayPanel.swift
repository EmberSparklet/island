import AppKit
import IslandCore

/// The floating window itself: borderless, never main, visible on every Space,
/// and floating above normal windows and the Dock.
///
/// It only becomes key while `acceptsKeyboard` is on — when the user summons it
/// and wants to type. Being a non-activating panel, it takes the keyboard
/// without activating island, so the app underneath stays frontmost. When it
/// pops up by itself, `acceptsKeyboard` is off and it never steals focus.
///
/// The window is exactly the capsule: the frosted background is clipped to the
/// capsule shape and paints nothing outside it, so there is no margin to leave
/// room for and no transparent area to click through.
final class OverlayPanel: NSPanel {
    var acceptsKeyboard = false
    /// Called when the panel loses key status, e.g. the user clicked elsewhere.
    var onResignKey: (() -> Void)?

    /// Capsule size, which is also the window size.
    private(set) var capsuleSize = CGSize(width: 420, height: 96)
    private let container = NSView()
    private let overlayView: NSView

    init(contentView overlayView: NSView) {
        self.overlayView = overlayView
        super.init(
            contentRect: NSRect(origin: .zero, size: capsuleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        // No window shadow: for a transparent borderless window the system draws
        // it from the frame rectangle, so its hard contact line traces square
        // corners that stick out of the capsule's rounded ones. The frosted
        // edges and the outline carry the panel on their own.
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        becomesKeyOnlyIfNeeded = false
        self.contentView = container
        container.addSubview(overlayView)
        layoutContent()
    }

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Grows/shrinks with the number of tasks shown, keeping the capsule's top
    /// edge put.
    func setContentSize(width: CGFloat, height: CGFloat) {
        capsuleSize = CGSize(width: width, height: height)
        var frame = self.frame
        frame.size = capsuleSize
        setFrame(frame, display: true)
        layoutContent()
        positionNearTopOfScreen()
    }

    /// Centered horizontally with the capsule flush to the bottom of the menu
    /// bar, so the capsule hangs from the top of the screen — the "island"
    /// spot.
    func positionNearTopOfScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(
            OverlayGeometry.windowOrigin(
                capsuleTop: visible.maxY, centerX: visible.midX, content: capsuleSize))
    }

    private func layoutContent() {
        container.frame = NSRect(origin: .zero, size: capsuleSize)
        overlayView.frame = container.bounds
    }
}

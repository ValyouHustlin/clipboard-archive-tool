import AppKit

/// Layer-backed view whose background color re-resolves inside
/// `updateLayer()`, where AppKit has already made the view's effective
/// appearance current (Slice 9 appearance QA).
///
/// The bug this replaces: assigning a dynamic `NSColor`'s `cgColor` to a
/// layer once at build time freezes whichever appearance was current at
/// that moment — on a dark-mode system the Settings footer stayed dark in
/// light mode (and vice versa). Any chrome band or separator built from a
/// dynamic color must go through this view, not a one-shot `cgColor`.
final class AdaptiveBackgroundView: NSView {
    private let colorProvider: () -> NSColor

    var cornerRadius: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }

    init(colorProvider: @escaping () -> NSColor) {
        self.colorProvider = colorProvider
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        layer?.backgroundColor = colorProvider().cgColor
        layer?.cornerRadius = cornerRadius
    }
}

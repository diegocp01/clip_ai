import AppKit

/// Keep the controls fully legible above the translucent shell and preserve
/// their stable parent throughout the compact-to-expanded transition.
final class ComposerSurface: NSView {
    private let content: NSView
    private let shell = PetroleumCradle(frame: .zero)
    private var expanded = false
    private(set) var currentRadius = ComposerGeometry.cornerRadius
    private let oil = CALayer()
    private let clearing = CAGradientLayer()

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        oil.backgroundColor = NSColor.black.cgColor
        oil.masksToBounds = true
        clearing.startPoint = CGPoint(x: 0.5, y: 0)
        clearing.endPoint = CGPoint(x: 0.5, y: 1)
        oil.mask = clearing
        content.autoresizingMask = [.width, .height]
        shell.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Start from the notch's pure black, then clear it from bottom to top.
    /// The translucent shell underneath stays mounted in both directions.
    func beginMorph() {
        showComposer(true)
        layer?.addSublayer(oil)
    }

    func setMorph(reveal: CGFloat, radius: CGFloat, notched: Bool) {
        let p = min(max(reveal, 0), 1)
        currentRadius = radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        oil.frame = bounds
        clearing.frame = CGRect(origin: .zero, size: bounds.size)
        oil.cornerRadius = radius
        // Square shoulders at the physical screen edge become rounded bubble corners.
        oil.maskedCorners = notched && p < 0.08 ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        clearing.colors = [NSColor.white.withAlphaComponent(1 - smoothstep(0.12, 0.72, p)).cgColor,
                           NSColor.white.withAlphaComponent(1 - smoothstep(0.32, 1, p)).cgColor]
        shell.alphaValue = smoothstep(0.2, 0.8, p)
        content.alphaValue = smoothstep(0.82, 1, p)
        CATransaction.commit()
    }

    func endMorph() {
        oil.removeFromSuperlayer()
        oil.contents = nil
        shell.alphaValue = 1
        content.alphaValue = 1

    }

    override func layout() {
        super.layout()
        shell.needsDisplay = true
    }

    func showComposer(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        if value {
            shell.frame = bounds
            addSubview(shell, positioned: .below, relativeTo: content)
        } else {
            shell.removeFromSuperview()
        }
        content.frame = bounds
    }
}

/// One fill makes every point of the expanded backdrop exactly 50% opaque.
/// Text and controls remain separate, at full opacity.
private final class PetroleumCradle: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        ComposerGeometry.shellPath(in: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

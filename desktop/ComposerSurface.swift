import AppKit

/// The controls keep one stable parent while the native glass backdrop comes and
/// goes. Reparenting them through NSGlassEffectView can leave its compositor mask
/// attached after collapse, blanking the compact island.
final class ComposerSurface: NSView {
    private let content: NSView
    private let material: NSView
    private let shell = PetroleumCradle(frame: .zero)
    private var expanded = false
    private(set) var currentRadius = ComposerGeometry.cornerRadius
    private let oil = CALayer()
    private let clearing = CAGradientLayer()

    init(content: NSView) {
        self.content = content
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = nil
            glass.cornerRadius = ComposerGeometry.cornerRadius
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            material = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = ComposerGeometry.cornerRadius
            blur.layer?.masksToBounds = true
            material = blur
        }
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
    /// The native refractive material underneath stays mounted in both directions.
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
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else { material.layer?.cornerRadius = radius }
        shell.alphaValue = smoothstep(0.2, 0.8, p)
        material.alphaValue = smoothstep(0.35, 0.9, p)
        content.alphaValue = smoothstep(0.82, 1, p)
        CATransaction.commit()
    }

    func endMorph() {
        oil.removeFromSuperlayer()
        oil.contents = nil
        shell.alphaValue = 1
        material.alphaValue = 1
        content.alphaValue = 1
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            glass.cornerRadius = ComposerGeometry.cornerRadius
        } else { material.layer?.cornerRadius = ComposerGeometry.cornerRadius }
    }

    override func layout() {
        super.layout()
        // The glass is the central water pocket, not the entire black shell.
        material.frame = ComposerGeometry.prompt
        shell.needsDisplay = true
    }

    func showComposer(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        if value {
            shell.frame = bounds
            addSubview(shell, positioned: .below, relativeTo: content)
            material.frame = ComposerGeometry.prompt
            addSubview(material, positioned: .above, relativeTo: shell)
        } else {
            material.removeFromSuperview()
            shell.removeFromSuperview()
        }
        content.frame = bounds
    }
}

/// The notch remains the parent material: an opaque black rim cups the water
/// pocket and its radial controls. Fine concentric seams echo the reference
/// without introducing decorative labels or extra actions.
private final class PetroleumCradle: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let outline = ComposerGeometry.shellPath(in: bounds.insetBy(dx: 0.5, dy: 0.5))
        outline.addClip()
        NSGradient(colors: [NSColor(white: 0.055, alpha: 1), .black])?.draw(in: bounds, angle: 90)
        // Broad, very low contrast sheen; the outer rim stays petroleum black.
        let inner = NSBezierPath(ovalIn: NSRect(x: bounds.width * 0.16, y: bounds.height * 0.28,
                                               width: bounds.width * 0.68, height: bounds.height * 1.02))
        NSGradient(colors: [NSColor(white: 0.10, alpha: 1), NSColor(white: 0.025, alpha: 1)])?.draw(in: inner, angle: 90)
        NSColor.white.withAlphaComponent(0.09).setStroke()
        inner.lineWidth = 0.5
        inner.stroke()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        outline.lineWidth = 0.7
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Keep the prompt's native field editor and clipboard behavior, without the
/// heavy bezel/focus halo that previously filled the center of the composer.
final class ComposerPrompt: NSTextField {
    weak var focusSurface: NSView?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusSurface?.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.45).cgColor }
        return accepted
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        focusSurface?.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }
}

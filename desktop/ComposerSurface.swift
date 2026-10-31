import AppKit

/// The expanded native composer owns its controls inside the system material.
/// Collapsing removes the material entirely, preserving the black notch renderer.
final class ComposerSurface: NSView {
    private let content: NSView
    private let material: NSView
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
        oil.contentsGravity = .resize
        oil.masksToBounds = true
        clearing.startPoint = CGPoint(x: 0.5, y: 0)
        clearing.endPoint = CGPoint(x: 0.5, y: 1)
        oil.mask = clearing
        content.autoresizingMask = [.width, .height]
        material.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reuse the notch's petroleum shader, then clear it from bottom to top.
    /// The native refractive material underneath stays mounted in both directions.
    func beginMorph(area: NSRect, time: CGFloat) {
        showComposer(true)
        oil.contents = Petroleum.image(area: area, hole: nil, time: time)
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
        content.alphaValue = smoothstep(0.82, 1, p)
        CATransaction.commit()
    }

    func endMorph() {
        oil.removeFromSuperlayer()
        oil.contents = nil
        content.alphaValue = 1
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            glass.cornerRadius = ComposerGeometry.cornerRadius
        } else { material.layer?.cornerRadius = ComposerGeometry.cornerRadius }
    }

    func showComposer(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        content.removeFromSuperview()
        if value {
            material.frame = bounds
            addSubview(material)
            if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
                glass.contentView = content
            } else {
                material.addSubview(content)
            }
        } else {
            if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView { glass.contentView = nil }
            material.removeFromSuperview()
            addSubview(content)
        }
        content.frame = bounds
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

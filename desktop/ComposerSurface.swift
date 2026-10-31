import AppKit

/// The expanded native composer owns its controls inside the system material.
/// Collapsing removes the material entirely, preserving the black notch renderer.
final class ComposerSurface: NSView {
    private let content: NSView
    private let material: NSView
    private var expanded = false

    init(content: NSView) {
        self.content = content
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.tintColor = NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.25, alpha: 0.18)
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
        content.autoresizingMask = [.width, .height]
        material.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        if accepted { focusSurface?.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor }
        return accepted
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        focusSurface?.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
    }
}

import AppKit

/// Keep the controls fully legible above the translucent shell and preserve
/// their stable parent throughout the compact-to-expanded transition.
final class ComposerSurface: NSView {
    private let content: NSView
    private let shell = PetroleumCradle(frame: .zero)
    private let wedges = ComposerWedges(frame: NSRect(origin: .zero, size: ComposerGeometry.size))
    private let hoverTitle = NSTextField(labelWithString: "")
    private let hoverDetail = NSTextField(labelWithString: "")
    private var hoveredOption: Int?
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
        hoverTitle.frame = ComposerGeometry.hoverTitle
        hoverTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        hoverTitle.textColor = NSColor(calibratedRed: 0.62, green: 1, blue: 0.76, alpha: 1)
        hoverDetail.frame = ComposerGeometry.hoverDetail
        hoverDetail.font = .systemFont(ofSize: 10.5)
        hoverDetail.textColor = NSColor.white.withAlphaComponent(0.85)
        for label in [hoverTitle, hoverDetail] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.alphaValue = 0
            content.addSubview(label)
        }
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Start from the notch's pure black, then clear it from bottom to top.
    /// The translucent shell underneath stays mounted in both directions.
    func beginMorph() {
        updateHover(at: nil, details: [])
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
        wedges.alphaValue = smoothstep(0.82, 1, p)
        content.alphaValue = smoothstep(0.82, 1, p)
        CATransaction.commit()
    }

    func endMorph() {
        oil.removeFromSuperlayer()
        oil.contents = nil
        shell.alphaValue = 1
        wedges.alphaValue = 1
        content.alphaValue = 1
    }

    override func layout() {
        super.layout()
        shell.needsLayout = true
    }

    func showComposer(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        if value {
            shell.frame = bounds
            addSubview(shell, positioned: .below, relativeTo: content)
            addSubview(wedges, positioned: .above, relativeTo: shell)
        } else {
            updateHover(at: nil, details: [])
            wedges.removeFromSuperview()
            shell.removeFromSuperview()
        }
        content.frame = bounds
    }
    func updateHover(at point: NSPoint?, details: [String]) {
        let index = expanded ? point.flatMap { ComposerGeometry.option(at: $0) } : nil
        let detail = index.flatMap { details.indices.contains($0) ? details[$0] : nil } ?? ""
        guard index != hoveredOption || detail != hoverDetail.stringValue else { return }
        hoveredOption = index
        hoverTitle.stringValue = index.map { ComposerGeometry.optionNames[$0] } ?? ""
        hoverDetail.stringValue = detail
        wedges.select(index)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            hoverTitle.animator().alphaValue = index == nil ? 0 : 1
            hoverDetail.animator().alphaValue = index == nil ? 0 : 1
        }
    }

}

/// A sandblasted material across the whole shell; the input itself has no box.
/// Keep the native backdrop at full strength: translucency comes from the
/// material itself, rather than leaking an unblurred desktop through view alpha.
private final class PetroleumCradle: NSVisualEffectView {
    private let finishMask = CAShapeLayer()
    private var maskedSize = NSSize.zero
    private let finish = FrostedFinish(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        finish.wantsLayer = true
        finish.layer?.mask = finishMask
        finish.autoresizingMask = [.width, .height]
        finish.frame = bounds
        addSubview(finish)
        alphaValue = 1
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = ComposerGeometry.shellPath(in: bounds.insetBy(dx: 0.5, dy: 0.5))
        finishMask.frame = bounds
        finishMask.path = path.cgPath
        // AppKit must mask the backdrop material itself, not just its CALayer.
        // Reuse the raster mask until the morph changes the view size.
        if maskedSize != bounds.size, bounds.width > 1, bounds.height > 1 {
            maskedSize = bounds.size
            maskImage = NSImage(size: bounds.size, flipped: false) { _ in
                NSColor.white.setFill()
                path.fill()
                return true
            }
        }
        CATransaction.commit()
    }
}

/// A fixed, fine grain avoids animated noise and hard glass highlights.
private final class FrostedFinish: NSView {
    private static let grain = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { _ in
        var seed: UInt64 = 73
        for _ in 0..<4200 {
            seed = seed &* 6364136223846793005 &+ 1
            let x = CGFloat((seed >> 16) % 192) / 2
            seed = seed &* 6364136223846793005 &+ 1
            let y = CGFloat((seed >> 16) % 192) / 2
            NSColor(white: (seed >> 8) & 1 == 0 ? 1 : 0, alpha: 0.065).setFill()
            NSRect(x: x, y: y, width: 0.5, height: 0.5).fill()
        }
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.16).setFill()
        bounds.fill()
        NSColor(patternImage: Self.grain).setFill()
        bounds.fill()
    }
}

/// Decorative layers do not intercept button clicks or text selection.
private final class ComposerWedges: NSView {
    private var highlights: [CAShapeLayer] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let clip = CAShapeLayer()
        clip.frame = bounds
        clip.path = ComposerGeometry.optionRing().cgPath
        clip.fillRule = .evenOdd
        layer?.mask = clip
        let green = NSColor(calibratedRed: 0.29, green: 0.93, blue: 0.47, alpha: 1)
        for index in ComposerGeometry.optionFrames.indices {
            let path = ComposerGeometry.optionSector(index).cgPath
            let separator = CAShapeLayer()
            separator.frame = bounds
            separator.path = path
            separator.fillColor = NSColor.clear.cgColor
            separator.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
            separator.lineWidth = 0.5
            layer?.addSublayer(separator)
            let glow = CAShapeLayer()
            glow.frame = bounds
            glow.path = path
            glow.fillColor = green.withAlphaComponent(0.12).cgColor
            glow.strokeColor = green.withAlphaComponent(0.5).cgColor
            glow.lineWidth = 1
            glow.shadowColor = green.cgColor
            glow.shadowOpacity = 0.45
            glow.shadowRadius = 10
            glow.shadowOffset = .zero
            glow.opacity = 0
            layer?.addSublayer(glow)
            highlights.append(glow)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func select(_ selected: Int?) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for (index, glow) in highlights.enumerated() { glow.opacity = index == selected ? 1 : 0 }
        CATransaction.commit()
    }
}

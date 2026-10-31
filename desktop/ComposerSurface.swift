import AppKit

/// Keep the controls fully legible above the translucent shell and preserve
/// their stable parent throughout the compact-to-expanded transition.
final class ComposerSurface: NSView {
    private let content: NSView
    private let shell = PetroleumCradle(frame: .zero)
    private let wedges = ComposerWedges(frame: NSRect(origin: .zero, size: ComposerGeometry.size))
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
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Start from the notch's pure black, then clear it from bottom to top.
    /// The translucent shell underneath stays mounted in both directions.
    func beginMorph() {
        updateHover(at: nil)
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
        shell.setFinishReveal(smoothstep(0.2, 0.8, p))
        wedges.alphaValue = smoothstep(0.82, 1, p)
        content.alphaValue = smoothstep(0.82, 1, p)
        CATransaction.commit()
    }

    func endMorph() {
        oil.removeFromSuperlayer()
        oil.contents = nil
        shell.setFinishReveal(1)
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
            updateHover(at: nil)
            wedges.removeFromSuperview()
            shell.removeFromSuperview()
        }
        content.frame = bounds
    }
    func setNotchWidth(_ width: CGFloat?) { shell.setNotchWidth(width) }

    func updateHover(at point: NSPoint?) {
        let index = expanded ? point.flatMap { ComposerGeometry.option(at: $0) } : nil
        guard index != hoveredOption else { return }
        hoveredOption = index
        wedges.select(index)
    }

}

/// A sandblasted material across the whole shell; the input itself has no box.
/// Keep the native effect at full opacity: translucency comes from its material,
/// not from blending sharp desktop pixels back over the blurred result.
/// Only the separate tint/grain finish fades during the morph.
private final class PetroleumCradle: NSVisualEffectView {
    private let finishMask = CAShapeLayer()
    private let blendMask = CAShapeLayer()
    private let notchBlend = NotchBlend(frame: .zero)
    private var maskedSize = NSSize.zero
    private let finish = FrostedFinish(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        finish.wantsLayer = true
        finish.layer?.mask = finishMask
        finish.autoresizingMask = [.width, .height]
        finish.frame = bounds
        addSubview(finish)
        notchBlend.wantsLayer = true
        notchBlend.layer?.mask = blendMask
        notchBlend.autoresizingMask = [.width, .height]
        notchBlend.frame = bounds
        addSubview(notchBlend)
        alphaValue = 1
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setNotchWidth(_ width: CGFloat?) { notchBlend.notchWidth = width }
    func setFinishReveal(_ value: CGFloat) {
        // Never fade this NSVisualEffectView or an ancestor to tune transparency.
        // A lower alpha mixes the original, unblurred desktop back into the shell.
        finish.alphaValue = 0.8 * min(max(value, 0), 1)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = ComposerGeometry.shellPath(in: bounds.insetBy(dx: 0.5, dy: 0.5))
        finishMask.frame = bounds
        finishMask.path = path.cgPath
        blendMask.frame = bounds
        blendMask.path = ComposerGeometry.shellPath(in: bounds).cgPath
        notchBlend.needsDisplay = true
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

/// Opaque at the camera seam, then clear outward/downward so the native frost
/// remains visible. Separate from the finish opacity to meet the real black notch.
private final class NotchBlend: NSView {
    var notchWidth: CGFloat? { didSet { if notchWidth != oldValue { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let width = notchWidth, width > 0, bounds.width > 1,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = max(bounds.width * 0.46, width / 2 + 12)
        let depth = min(bounds.height * 0.45, 90)
        let core = min((width / 2 + 1) / radius, 0.8)
        let colors = [CGFloat(1), 1, 0.65, 0.2, 0].map { NSColor.black.withAlphaComponent($0).cgColor }
        let locations: [CGFloat] = [0, core, core + (1 - core) * 0.32, core + (1 - core) * 0.7, 1]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations) else { return }
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.maxY)
        context.scaleBy(x: radius, y: max(depth, 1))
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        context.restoreGState()
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
        NSColor.black.withAlphaComponent(0.08).setFill()
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

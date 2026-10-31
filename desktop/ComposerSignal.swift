import AppKit

/// Pointer attention is independent of the chosen shape. Raw pointer coordinates
/// never leave this local animation state.
struct ComposerAttention {
    static let modes = ["follow", "wander", "drift_left", "drift_right"]
    var mode = "follow" { didSet { if mode != oldValue { time = 0 } } }
    private(set) var time: CGFloat = 0
    private var x = Spring(stiffness: 32, damping: 11)
    private var y = Spring(stiffness: 32, damping: 11)
    private(set) var following = false
    var horizontal: CGFloat { x.value }
    var vertical: CGFloat { y.value }
    static func pointer(_ point: NSPoint, in bounds: NSRect) -> NSPoint? {
        guard bounds.width > 0, bounds.height > 0, ComposerGeometry.shellPath(in: bounds).contains(point) else { return nil }
        return NSPoint(x: min(1, max(-1, (point.x - bounds.midX) / (bounds.width / 2))),
                       y: min(1, max(-1, (point.y - bounds.midY) / (bounds.height / 2))))
    }
    mutating func step(_ dt: CGFloat, pointer: NSPoint?) {
        time += dt
        following = mode == "follow" && pointer != nil
        if following, let pointer {
            x.target = pointer.x; y.target = pointer.y
        } else {
            switch mode {
            case "drift_left": x.target = -sin(time * 0.55) * 0.85
            case "drift_right": x.target = sin(time * 0.55) * 0.85
            default: x.target = sin(time * 0.47) * 0.65 + sin(time * 1.13) * 0.2
            }
            y.target = sin(time * 0.7) * 0.4
        }
        x.step(dt); y.step(dt)
    }
}

/// The same spring-driven signal as the compact notch, in a slim strip above the caption.
/// Decisions selects a name; all geometry, blinking, motion and pointer response stay local.
final class ComposerSignal: NSView {
    static let stripFrame = NSRect(x: 130, y: 190, width: 220, height: 10)
    var signal = SignalBar()
    private var attention = ComposerAttention()
    private let bars = [CAGradientLayer(), CAGradientLayer()]
    private let wave = CAShapeLayer()
    private var waveMix = Spring(stiffness: 40, damping: 12)
    private var timer: Timer?
    private var lastFrame = CACurrentMediaTime()
    private var active = false
    private var motionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer(); wantsLayer = true
        let green = NSColor(calibratedRed: 0.24, green: 0.95, blue: 0.52, alpha: 1)
        for bar in bars {
            bar.startPoint = CGPoint(x: 0, y: 0.5); bar.endPoint = CGPoint(x: 1, y: 0.5)
            bar.colors = [green.withAlphaComponent(0), green.withAlphaComponent(0.6), NSColor(calibratedRed: 0.8, green: 1, blue: 0.86, alpha: 1), green.withAlphaComponent(0.6), green.withAlphaComponent(0)].map(\.cgColor)
            bar.locations = [0, 0.3, 0.5, 0.7, 1]
            bar.shadowColor = green.cgColor; bar.shadowOffset = .zero
            bar.shadowRadius = 3; bar.shadowOpacity = 0.6
            layer?.addSublayer(bar)
        }
        wave.strokeColor = green.withAlphaComponent(0.85).cgColor
        wave.fillColor = nil; wave.lineWidth = 1.5; wave.lineCap = .round
        wave.shadowColor = green.cgColor; wave.shadowOffset = .zero
        wave.shadowRadius = 3; wave.shadowOpacity = 0.6
        layer?.addSublayer(wave)
        setAccessibilityElement(false)
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.setActive(self.active)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        timer?.invalidate()
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func choose(_ pattern: String, motion: String = "follow") {
        guard ["line", "eyes", "wave"].contains(pattern), ComposerAttention.modes.contains(motion) else { return }
        attention.mode = motion
        signal.pattern = pattern
        waveMix.target = pattern == "wave" ? 1 : 0
    }
    func setActive(_ value: Bool) {
        active = value
        timer?.invalidate(); timer = nil
        guard value else { return }
        render(staticLine: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        lastFrame = CACurrentMediaTime()
        let clock = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
        timer = clock; RunLoop.main.add(clock, forMode: .common)
    }
    private func step() {
        let now = CACurrentMediaTime(), dt = CGFloat(min(now - lastFrame, 1.0 / 20))
        lastFrame = now
        let parent = superview
        let position = parent?.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let pointer = position.flatMap { point in parent.flatMap { ComposerAttention.pointer(point, in: $0.bounds) } }
        attention.step(dt, pointer: pointer)
        signal.step(dt, pointer: attention.horizontal, swayScale: attention.following ? 0.15 : 0.4)
        waveMix.step(dt)
        render(staticLine: false)
    }
    private func render(staticLine: Bool) {
        let dx: CGFloat = staticLine ? 0 : attention.horizontal * 10
        let dy: CGFloat = staticLine ? 0 : attention.vertical * 0.7
        let line = CGRect(x: bounds.midX - 65 + dx, y: bounds.midY - 1.25 + dy, width: 130, height: 2.5)
        let pair = staticLine ? (left: line, right: line) : signal.bars(line: line, room: 24)
        let blend = staticLine ? 0 : min(max(waveMix.value, 0), 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (bar, rect) in zip(bars, [pair.left, pair.right]) {
            bar.frame = rect; bar.cornerRadius = rect.height / 2; bar.opacity = Float(1 - blend)
        }
        let path = CGMutablePath()
        for i in 0...80 {
            let t = CGFloat(i) / 80
            let p = CGPoint(x: line.minX + line.width * t, y: line.midY + sin(t * .pi) * sin(t * .pi * 4 - signal.time * 1.8) * 2.2)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        wave.path = path; wave.opacity = Float(blend)
        CATransaction.commit()
    }
}

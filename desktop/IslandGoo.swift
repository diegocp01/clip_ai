import AppKit

func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func mix(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
    NSRect(x: mix(a.minX, b.minX, t), y: mix(a.minY, b.minY, t), width: mix(a.width, b.width, t), height: mix(a.height, b.height, t))
}
func smoothstep(_ from: CGFloat, _ to: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - from) / (to - from), 0), 1)
    return t * t * (3 - 2 * t)
}

/// A damped spring stepped once per display frame.
struct Spring {
    var value: CGFloat = 0
    var target: CGFloat = 0
    var velocity: CGFloat = 0
    var stiffness: CGFloat
    var damping: CGFloat
    var isSettled: Bool { abs(value - target) < 0.002 && abs(velocity) < 0.02 }
    mutating func step(_ dt: CGFloat) {
        velocity += (stiffness * (target - value) - damping * velocity) * dt
        value += velocity * dt
        if isSettled { jump(to: target) }
    }
    mutating func jump(to position: CGFloat) { value = position; velocity = 0 }
}

/// The awake line's behavior: it wanders side to side, then splits into two eyes that
/// look toward the pointer and blink, then flows back together.
struct SignalBar {
    static let sweepTime: CGFloat = 3.6
    static let eyesTime: CGFloat = 3.2
    private(set) var time: CGFloat = 0
    private var sway = Spring(stiffness: 40, damping: 9)
    private var split = Spring(stiffness: 60, damping: 10)
    private var look = Spring(stiffness: 70, damping: 11)
    private var phase: CGFloat { time.truncatingRemainder(dividingBy: SignalBar.sweepTime + SignalBar.eyesTime) }
    var isEyes: Bool { phase > SignalBar.sweepTime }
    /// Two quick closes while the eyes are open: 1 is shut.
    var blink: CGFloat {
        let first = (phase - SignalBar.sweepTime - 1.3) / 0.07, second = (phase - SignalBar.sweepTime - 2.4) / 0.07
        return min(exp(-first * first) + exp(-second * second), 1)
    }
    /// `pointer` runs from -1 at the island's left edge to 1 at its right.
    mutating func step(_ dt: CGFloat, pointer: CGFloat) {
        time += dt
        split.target = isEyes ? 1 : 0
        sway.target = isEyes ? 0 : sin(time * 2 * .pi / 2.4)
        look.target = min(max(pointer, -1), 1)
        split.step(dt); sway.step(dt); look.step(dt)
    }
    /// Where the two bars sit. They overlap as one line until it splits. `room` is the free space beside the line.
    func bars(line: CGRect, room: CGFloat) -> (left: CGRect, right: CGRect) {
        let s = min(max(split.value, 0), 1.15)
        let center = line.midX + sway.value * (1 - min(s, 1)) * room * 0.7 + look.value * room * mix(0.2, 0.45, min(s, 1))
        let width = mix(line.width, line.width * 0.26, s) * (1 - 0.2 * blink), height = mix(line.height, line.height * 1.6, s) * (1 - 0.7 * blink)
        let gap = line.width * 0.24 * s
        let y = line.midY - height / 2
        return (CGRect(x: center - gap - width / 2, y: y, width: width, height: height),
                CGRect(x: center + gap - width / 2, y: y, width: width, height: height))
    }
}

/// Holds on to the pointer after it leaves the island, until it goes too far, takes too long or clicks elsewhere.
struct GooTether {
    static let reach: CGFloat = 46
    static let patience: CGFloat = 1
    var attached = false
    private var elapsed: CGFloat = 0
    /// Returns true on the update where the tether separates.
    mutating func update(inside: Bool, distance: CGFloat, pressed: Bool, dt: CGFloat) -> Bool {
        if inside { attached = true; elapsed = 0; return false }
        guard attached else { return false }
        elapsed += dt
        guard distance > GooTether.reach || elapsed > GooTether.patience || pressed else { return false }
        attached = false
        return true
    }
}

/// The island's left, bottom and right edges as one line, so a blob's base can wrap around a corner.
struct IslandOutline {
    let rect: CGRect
    var length: CGFloat { rect.height * 2 + rect.width }
    func point(at position: CGFloat) -> CGPoint {
        let s = min(max(position, 0), length)
        if s < rect.height { return CGPoint(x: rect.minX, y: rect.maxY - s) }
        if s < rect.height + rect.width { return CGPoint(x: rect.minX + s - rect.height, y: rect.minY) }
        return CGPoint(x: rect.maxX, y: rect.minY + s - rect.height - rect.width)
    }
    /// The direction of increasing position.
    func tangent(at position: CGFloat) -> CGPoint {
        if position < rect.height { return CGPoint(x: 0, y: -1) }
        if position < rect.height + rect.width { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: 0, y: 1)
    }
    func nearest(to p: CGPoint) -> CGFloat {
        let y = min(max(p.y, rect.minY), rect.maxY)
        let candidates: [(position: CGFloat, distance: CGFloat)] = [
            (rect.maxY - y, hypot(p.x - rect.minX, p.y - y)),
            (rect.height + min(max(p.x, rect.minX), rect.maxX) - rect.minX, hypot(p.x - min(max(p.x, rect.minX), rect.maxX), p.y - rect.minY)),
            (rect.height + rect.width + y - rect.minY, hypot(p.x - rect.maxX, p.y - y)),
        ]
        return candidates.min { $0.distance < $1.distance }!.position
    }
    func distance(to p: CGPoint) -> CGFloat {
        hypot(max(rect.minX - p.x, 0, p.x - rect.maxX), max(rect.minY - p.y, 0, p.y - rect.maxY))
    }
}

enum GooShape {
    /// Concave corners that melt the island's top edge into the menu bar.
    static func shoulders(rect: CGRect, radius: CGFloat = 8) -> CGPath {
        let path = CGMutablePath()
        for (edge, outward) in [(rect.maxX, radius), (rect.minX, -radius)] {
            path.move(to: CGPoint(x: edge, y: rect.maxY))
            path.addLine(to: CGPoint(x: edge + outward, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: edge, y: rect.maxY - radius), control: CGPoint(x: edge, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

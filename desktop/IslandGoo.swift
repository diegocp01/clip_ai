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

/// Holds on to the pointer after it leaves the island, until it goes too far, takes too long or clicks elsewhere.
struct GooTether {
    static let reach: CGFloat = 110
    static let patience: CGFloat = 2.2
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

/// A small drop left behind for a moment when the tether separates.
struct GooDroplet {
    var center: CGPoint
    var radius: CGFloat
    var velocity: CGPoint
}

enum GooShape {
    /// Where the blob's rounded end sits for a tip, and how it points.
    static func bulb(outline: IslandOutline, tip: CGPoint) -> (center: CGPoint, radius: CGFloat, direction: CGPoint, length: CGFloat)? {
        guard !outline.rect.contains(tip) else { return nil }
        let anchor = outline.point(at: outline.nearest(to: tip))
        let length = hypot(tip.x - anchor.x, tip.y - anchor.y)
        guard length > 1 else { return nil }
        let direction = CGPoint(x: (tip.x - anchor.x) / length, y: (tip.y - anchor.y) / length)
        let radius = min(mix(22, 14, smoothstep(10, 70, length)), length * 0.6)
        return (CGPoint(x: tip.x - direction.x * radius, y: tip.y - direction.y * radius), radius, direction, length)
    }
    /// A liquid neck from the island's edge out to the tip. Its base closes through
    /// the island's interior, which the opaque island window covers.
    static func blob(outline: IslandOutline, tip: CGPoint) -> CGPath? {
        guard let bulb = bulb(outline: outline, tip: tip) else { return nil }
        let position = outline.nearest(to: tip)
        let baseHalf = mix(46, 30, smoothstep(10, 70, bulb.length))
        let a = outline.point(at: position - baseHalf), b = outline.point(at: position + baseHalf)
        let ta = outline.tangent(at: position - baseHalf), tb = outline.tangent(at: position + baseHalf)
        let d = bulb.direction, side = CGPoint(x: -d.y, y: d.x), r = bulb.radius, fillet = baseHalf * 0.75
        let neck = max(bulb.length - r, 0) * 0.55
        let pa = CGPoint(x: bulb.center.x - side.x * r, y: bulb.center.y - side.y * r)
        let pb = CGPoint(x: bulb.center.x + side.x * r, y: bulb.center.y + side.y * r)
        let path = CGMutablePath()
        path.move(to: a)
        path.addCurve(to: pa, control1: CGPoint(x: a.x + ta.x * fillet, y: a.y + ta.y * fillet),
                      control2: CGPoint(x: pa.x - d.x * neck, y: pa.y - d.y * neck))
        path.addArc(center: bulb.center, radius: r, startAngle: atan2(-side.y, -side.x), endAngle: atan2(side.y, side.x), clockwise: false)
        path.addCurve(to: b, control1: CGPoint(x: pb.x - d.x * neck, y: pb.y - d.y * neck),
                      control2: CGPoint(x: b.x - tb.x * fillet, y: b.y - tb.y * fillet))
        path.addLine(to: CGPoint(x: outline.rect.midX, y: outline.rect.midY))
        path.closeSubpath()
        return path
    }
    /// Whether a point is on the blob, with some room around it because the pointer pulls ahead of the tip.
    static func touches(outline: IslandOutline, tip: CGPoint, point: CGPoint) -> Bool {
        guard !outline.rect.contains(point), let blob = blob(outline: outline, tip: tip) else { return false }
        return blob.contains(point) || blob.copy(strokingWithWidth: 24, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(point)
    }
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

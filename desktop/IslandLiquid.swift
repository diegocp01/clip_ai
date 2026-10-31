import AppKit

/// A stretch of liquid: a line whose thickness can change along it.
struct LiquidCapsule {
    var a: CGPoint
    var b: CGPoint
    var ra: CGFloat
    var rb: CGFloat
    func distance(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let bax = b.x - a.x, bay = b.y - a.y, pax = x - a.x, pay = y - a.y
        let lengthSquared = bax * bax + bay * bay
        let t = lengthSquared > 0.0001 ? min(max((pax * bax + pay * bay) / lengthSquared, 0), 1) : 0
        let dx = pax - bax * t, dy = pay - bay * t
        return (dx * dx + dy * dy).squareRoot() - (ra + (rb - ra) * t)
    }
}

/// Blends two shapes so they flow into each other, the way surface tension joins liquids.
@inline(__always) private func blend(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat {
    let h = max(k - abs(a - b), 0) / k
    return min(a, b) - h * h * k / 4
}

/// Signed distance to the island, whose top runs off the screen.
@inline(__always) private func islandDistance(_ x: CGFloat, _ y: CGFloat, _ rect: CGRect, _ radius: CGFloat) -> CGFloat {
    let halfWidth = rect.width / 2, halfHeight = rect.height / 2 + 40
    let qx = abs(x - rect.midX) - (halfWidth - radius), qy = abs(y - (rect.midY + 40)) - (halfHeight - radius)
    let ox = max(qx, 0), oy = max(qy, 0)
    return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - radius
}

/// A short viscous pull on the island's edge: nodes joined by tension, slowed by internal
/// friction and pulled by gravity. It grabs a little at a leaving pointer, then flows back.
struct LiquidSim {
    static let nodeCount = 7
    /// How far the liquid can reach from the island.
    static let maxReach: CGFloat = 26
    private static let gravity: CGFloat = -220
    private(set) var nodes = [CGPoint](repeating: .zero, count: nodeCount)
    private var velocities = [CGPoint](repeating: .zero, count: nodeCount)
    private var wobble: CGFloat = 0
    private var wobbleVelocity: CGFloat = 0
    private var axis = CGPoint(x: 0, y: -1)

    var head: CGPoint { nodes[LiquidSim.nodeCount - 1] }
    var length: CGFloat { (1..<LiquidSim.nodeCount).reduce(0) { $0 + hypot(nodes[$1].x - nodes[$1 - 1].x, nodes[$1].y - nodes[$1 - 1].y) } }
    var isSettled: Bool { length < 0.5 }
    /// The liquid's thickness at its middle, which thins as it stretches.
    var neckRadius: CGFloat { min(mix(11, 5, smoothstep(4, LiquidSim.maxReach + 2, length)), length * 0.6) }
    private var headRadius: CGFloat { min(mix(12, 8, smoothstep(4, LiquidSim.maxReach + 2, length)), length * 0.7) }
    private var baseRadius: CGFloat { min(mix(16, 9, smoothstep(4, LiquidSim.maxReach + 2, length)), length * 0.9) }

    mutating func attach(at point: CGPoint) {
        guard length < 1 else { return }
        nodes = [CGPoint](repeating: point, count: LiquidSim.nodeCount)
        velocities = [CGPoint](repeating: .zero, count: LiquidSim.nodeCount)
        wobble = 0; wobbleVelocity = 0
    }
    mutating func reset() {
        nodes = [CGPoint](repeating: .zero, count: LiquidSim.nodeCount)
        velocities = [CGPoint](repeating: .zero, count: LiquidSim.nodeCount)
        wobble = 0; wobbleVelocity = 0
    }
    /// With a pointer it reaches toward it. Without one it flows back into the island.
    mutating func step(_ dt: CGFloat, outline: IslandOutline, pointer: CGPoint?) {
        let steps = max(Int((dt * 240).rounded(.up)), 1), h = dt / CGFloat(steps)
        for _ in 0..<steps { advance(h, outline: outline, pointer: pointer) }
    }

    private mutating func advance(_ h: CGFloat, outline: IslandOutline, pointer: CGPoint?) {
        let last = LiquidSim.nodeCount - 1
        let anchor = outline.point(at: outline.nearest(to: nodes[last]))
        // Gravity only matters once there is something for it to pull on.
        let weight = LiquidSim.gravity * min(length / 40, 1)
        var acceleration = CGPoint(x: (nodes[last - 1].x - nodes[last].x) * 45, y: (nodes[last - 1].y - nodes[last].y) * 45 + weight * 0.35)
        let target: CGPoint, stiffness: CGFloat, drag: CGFloat
        if let pointer {
            // Slow and heavy like oil, and only a short reach: the pointer soon pulls away from it.
            let start = outline.point(at: outline.nearest(to: pointer))
            let gap = outline.rect.contains(pointer) ? 0 : hypot(pointer.x - start.x, pointer.y - start.y)
            let reach = min(0.6, LiquidSim.maxReach / max(gap, 1))
            target = CGPoint(x: start.x + (pointer.x - start.x) * reach, y: start.y + (pointer.y - start.y) * reach)
            (stiffness, drag) = (80, 9.5)
        } else {
            target = anchor
            (stiffness, drag) = (180, 17)
        }
        acceleration.x += (target.x - nodes[last].x) * stiffness - velocities[last].x * drag
        acceleration.y += (target.y - nodes[last].y) * stiffness - velocities[last].y * drag
        // The rounded end jiggles a little when it's jerked around.
        let jerk = min(hypot(acceleration.x, acceleration.y), 4000)
        wobbleVelocity += (-520 * wobble - 8 * wobbleVelocity + jerk * 0.3) * h
        wobble = min(max(wobble + wobbleVelocity * h, -3), 3)
        let speed = hypot(velocities[last].x, velocities[last].y)
        if speed > 30 { axis = CGPoint(x: velocities[last].x / speed, y: velocities[last].y / speed) }
        velocities[last].x += acceleration.x * h
        velocities[last].y += acceleration.y * h
        // The base slides slowly along the edge, as if the liquid were sticking to it.
        velocities[0].x += ((anchor.x - nodes[0].x) * 55 - velocities[0].x * 13) * h
        velocities[0].y += ((anchor.y - nodes[0].y) * 55 - velocities[0].y * 13) * h
        for i in 1..<last {
            let tensionX = nodes[i - 1].x + nodes[i + 1].x - 2 * nodes[i].x, tensionY = nodes[i - 1].y + nodes[i + 1].y - 2 * nodes[i].y
            let frictionX = velocities[i - 1].x + velocities[i + 1].x - 2 * velocities[i].x, frictionY = velocities[i - 1].y + velocities[i + 1].y - 2 * velocities[i].y
            velocities[i].x += (420 * tensionX + 30 * frictionX - 9 * velocities[i].x) * h
            velocities[i].y += (420 * tensionY + 30 * frictionY - 9 * velocities[i].y + weight * 0.6) * h
        }
        for i in 0...last {
            nodes[i].x += velocities[i].x * h
            nodes[i].y += velocities[i].y * h
        }
        nodes[0] = outline.point(at: outline.nearest(to: nodes[0]))
    }

    /// The strand and its rounded end. Sharing one hard edge keeps joints from bulging.
    private var strand: [LiquidCapsule] {
        guard length >= 1 else { return [] }
        let last = LiquidSim.nodeCount - 1, neck = neckRadius, base = baseRadius, end = headRadius
        func radius(_ u: CGFloat) -> CGFloat { neck + (base - neck) * (1 - smoothstep(0, 0.4, u)) + (end - neck) * smoothstep(0.55, 1, u) }
        // A smooth curve through the nodes, so the surface has no corners at them.
        func curve(_ u: CGFloat) -> CGPoint {
            let at = u * CGFloat(last), i = min(Int(at), last - 1), t = at - CGFloat(i)
            let p0 = nodes[max(i - 1, 0)], p1 = nodes[i], p2 = nodes[i + 1], p3 = nodes[min(i + 2, last)]
            func blend(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t * t * t)
            }
            return CGPoint(x: blend(p0.x, p1.x, p2.x, p3.x), y: blend(p0.y, p1.y, p2.y, p3.y))
        }
        let pieces = last * 3
        var parts = (0..<pieces).map { i -> LiquidCapsule in
            let u = CGFloat(i) / CGFloat(pieces), v = CGFloat(i + 1) / CGFloat(pieces)
            return LiquidCapsule(a: curve(u), b: curve(v), ra: radius(u), rb: radius(v))
        }
        let along = wobble >= 0 ? axis : CGPoint(x: -axis.y, y: axis.x), reach = abs(wobble), r = max(end - reach * 0.45, 0)
        parts.append(LiquidCapsule(a: CGPoint(x: head.x - along.x * reach, y: head.y - along.y * reach),
                                   b: CGPoint(x: head.x + along.x * reach, y: head.y + along.y * reach), ra: r, rb: r))
        return parts
    }

    /// Signed distance from the liquid alone, without the island. Negative is inside.
    func distance(to point: CGPoint) -> CGFloat {
        var d = CGFloat.greatestFiniteMagnitude
        for part in strand { d = min(d, part.distance(point.x, point.y)) }
        return d
    }
    /// Draws the liquid: pure black, joined smoothly to the island, with a thin green edge near its end.
    func render(island: CGRect, cornerRadius: CGFloat, scale: CGFloat, clip: CGRect) -> (image: CGImage, frame: CGRect)? {
        let strand = self.strand
        guard !strand.isEmpty else { return nil }
        var box = CGRect.null
        for part in strand {
            box = box.union(CGRect(x: min(part.a.x, part.b.x), y: min(part.a.y, part.b.y), width: abs(part.a.x - part.b.x), height: abs(part.a.y - part.b.y)).insetBy(dx: -max(part.ra, part.rb) - 30, dy: -max(part.ra, part.rb) - 30))
        }
        let frame = box.intersection(clip).integral
        guard !frame.isNull, frame.width >= 1, frame.height >= 1 else { return nil }
        let width = Int(frame.width * scale), height = Int(frame.height * scale), end = head
        // Under the island's opaque window nothing needs drawing.
        let covered = island.insetBy(dx: cornerRadius + 1, dy: 0)
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let out = raw.bindMemory(to: UInt8.self).baseAddress!
            strand.withUnsafeBufferPointer { parts in
                for row in 0..<height {
                    let y = frame.maxY - (CGFloat(row) + 0.5) / scale
                    for column in 0..<width {
                        let x = frame.minX + (CGFloat(column) + 0.5) / scale
                        if covered.contains(CGPoint(x: x, y: y)) { continue }
                        var nearest = CGFloat.greatestFiniteMagnitude
                        for part in parts { nearest = min(nearest, part.distance(x, y)) }
                        let d = blend(islandDistance(x, y, island, cornerRadius), nearest, 16)
                        if d > 18 { continue }
                        let dx = x - end.x, dy = y - end.y
                        // Only the liquid glows, so the island's own edge fades out well inside this picture.
                        let reach = nearest > 0 ? exp(-(nearest / 10) * (nearest / 10)) : 1
                        var glow = exp(-(d / 1.1) * (d / 1.1)) * 0.7
                        if d > 0 { glow += exp(-d / 4) * 0.3 }
                        glow = min(glow * exp(-(dx * dx + dy * dy) / (2 * 34 * 34)) * reach, 1)
                        let cover = min(max(0.5 - d * scale, 0), 1)
                        let alpha = max(cover, glow)
                        let pixel = out + (row * width + column) * 4
                        pixel[0] = UInt8(min(glow * 0.29, alpha) * 255)
                        pixel[1] = UInt8(min(glow * 0.93, alpha) * 255)
                        pixel[2] = UInt8(min(glow * 0.47, alpha) * 255)
                        pixel[3] = UInt8(alpha * 255)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return (image, frame)
    }
}

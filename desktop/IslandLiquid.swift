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

/// A drop that has pinched off. It jiggles, sags, then surface tension draws it back to merge.
struct LiquidDrop {
    var position: CGPoint
    var velocity: CGPoint
    var radius: CGFloat
    var wobble: CGFloat
    var wobbleVelocity: CGFloat = 0
    var axis: CGPoint
    var age: CGFloat = 0
    /// Longer along one axis, then the other, keeping roughly the same amount of liquid.
    var capsule: LiquidCapsule {
        let along = wobble >= 0 ? axis : CGPoint(x: -axis.y, y: axis.x), reach = abs(wobble)
        let r = max(radius - reach * 0.45, 0)
        return LiquidCapsule(a: CGPoint(x: position.x - along.x * reach, y: position.y - along.y * reach),
                             b: CGPoint(x: position.x + along.x * reach, y: position.y + along.y * reach), ra: r, rb: r)
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

/// The look of thick oil: pure black, with faint colorless gloss where slow swirls catch the light.
enum Petroleum {
    @inline(__always) private static func noise(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        @inline(__always) func corner(_ ix: Int, _ iy: Int) -> CGFloat {
            var n = ix &* 374_761_393 &+ iy &* 668_265_263
            n = (n ^ (n >> 13)) &* 1_274_126_177
            return CGFloat((n ^ (n >> 16)) & 0xFFFF) / 65535
        }
        let fx = x.rounded(.down), fy = y.rounded(.down), ix = Int(fx), iy = Int(fy)
        let tx = x - fx, ty = y - fy, sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let bottom = corner(ix, iy) + (corner(ix + 1, iy) - corner(ix, iy)) * sx
        let top = corner(ix, iy + 1) + (corner(ix + 1, iy + 1) - corner(ix, iy + 1)) * sx
        return bottom + (top - bottom) * sy
    }
    /// How much gloss a point on screen catches. Most of the surface is exactly zero, so it stays pure black.
    @inline(__always) static func gloss(_ x: CGFloat, _ y: CGFloat, _ time: CGFloat) -> CGFloat {
        // Bending the coordinates through more noise is what makes the streaks swirl.
        let bendA = noise(x * 0.045 + time * 0.09, y * 0.08 - time * 0.05)
        let bendB = noise(x * 0.06 - time * 0.07 + 7, y * 0.1 + time * 0.08 + 3)
        let film = noise(x * 0.03 + bendA * 2.6, y * 0.055 + bendB * 2.6 + time * 0.04) * 2.3
        let ridge = max(0.5 + 0.5 * cos(2 * .pi * film) - 0.5, 0) / 0.5
        return ridge * ridge * 0.14
    }
    /// The same surface for a whole area, which lines up with the liquid because both use screen positions.
    static func image(area: CGRect, hole: CGRect?, time: CGFloat) -> CGImage? {
        let width = Int(area.width), height = Int(area.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let out = raw.bindMemory(to: UInt8.self).baseAddress!
            for row in 0..<height {
                let y = area.maxY - CGFloat(row) - 0.5
                for column in 0..<width {
                    let x = area.minX + CGFloat(column) + 0.5
                    // The camera has no pixels, so nothing there can be seen.
                    if let hole, hole.contains(CGPoint(x: x, y: y)) { continue }
                    let level = UInt8(gloss(x, y, time) * 255), pixel = out + (row * width + column) * 4
                    pixel[0] = level; pixel[1] = level; pixel[2] = level; pixel[3] = 255
                }
            }
        }
        return makeImage(pixels, width: width, height: height)
    }
    fileprivate static func makeImage(_ pixels: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A viscous strand drawn out of the island: nodes joined by tension, slowed by internal
/// friction and pulled by gravity. It thins as it stretches, pinches, and its drops merge back.
struct LiquidSim {
    static let nodeCount = 7
    private static let gravity: CGFloat = -220
    private(set) var nodes = [CGPoint](repeating: .zero, count: nodeCount)
    private var velocities = [CGPoint](repeating: .zero, count: nodeCount)
    private var wobble: CGFloat = 0
    private var wobbleVelocity: CGFloat = 0
    private var axis = CGPoint(x: 0, y: -1)
    private var pinch: CGFloat?
    private var thickness: CGFloat = 1
    private(set) var drops: [LiquidDrop] = []

    var head: CGPoint { nodes[LiquidSim.nodeCount - 1] }
    var length: CGFloat { (1..<LiquidSim.nodeCount).reduce(0) { $0 + hypot(nodes[$1].x - nodes[$1 - 1].x, nodes[$1].y - nodes[$1 - 1].y) } }
    var isSettled: Bool { length < 0.5 && pinch == nil && drops.isEmpty }
    /// The strand's thickness at its middle, which is where it gives way.
    var neckRadius: CGFloat { min(mix(15, 2.4, smoothstep(8, 95, length)), length * 0.6) * thickness * (1 - (pinch ?? 0)) }
    private var headRadius: CGFloat { min(mix(21, 12.5, smoothstep(8, 95, length)), length * 0.7) * thickness }
    private var baseRadius: CGFloat { min(mix(20, 9, smoothstep(8, 95, length)), length * 0.9) }

    mutating func attach(at point: CGPoint) {
        guard length < 1 else { return }
        nodes = [CGPoint](repeating: point, count: LiquidSim.nodeCount)
        velocities = [CGPoint](repeating: .zero, count: LiquidSim.nodeCount)
        wobble = 0; wobbleVelocity = 0; thickness = 1; pinch = nil
    }
    mutating func reset() {
        nodes = [CGPoint](repeating: .zero, count: LiquidSim.nodeCount)
        velocities = [CGPoint](repeating: .zero, count: LiquidSim.nodeCount)
        drops = []; pinch = nil; wobble = 0; wobbleVelocity = 0; thickness = 1
    }
    /// Starts the neck giving way.
    mutating func separate() { if length > 3, pinch == nil { pinch = 0 } }
    mutating func step(_ dt: CGFloat, outline: IslandOutline, pointer: CGPoint?) {
        let steps = max(Int((dt * 240).rounded(.up)), 1), h = dt / CGFloat(steps)
        for _ in 0..<steps { advance(h, outline: outline, pointer: pointer) }
    }

    private mutating func advance(_ h: CGFloat, outline: IslandOutline, pointer: CGPoint?) {
        let last = LiquidSim.nodeCount - 1
        let anchor = outline.point(at: outline.nearest(to: nodes[last]))
        // Gravity only matters once there is a strand for it to pull on.
        let weight = LiquidSim.gravity * min(length / 40, 1)
        // Once the neck is failing it can no longer pull the end back, so momentum carries it on.
        let hold: CGFloat = pinch == nil ? 45 : 0
        var acceleration = CGPoint(x: (nodes[last - 1].x - nodes[last].x) * hold, y: (nodes[last - 1].y - nodes[last].y) * hold + weight * 0.35)
        if pinch == nil {
            let target: CGPoint, stiffness: CGFloat, drag: CGFloat
            if let pointer {
                // Slow and heavy like oil: it reaches most of the way, then the pointer pulls away.
                let start = outline.point(at: outline.nearest(to: pointer))
                let gap = outline.rect.contains(pointer) ? 0 : hypot(pointer.x - start.x, pointer.y - start.y)
                let reach = min(0.92, 90 / max(gap, 1))
                target = CGPoint(x: start.x + (pointer.x - start.x) * reach, y: start.y + (pointer.y - start.y) * reach)
                (stiffness, drag) = (80, 9.5)
            } else {
                target = anchor
                (stiffness, drag) = (300, 24)
            }
            acceleration.x += (target.x - nodes[last].x) * stiffness - velocities[last].x * drag
            acceleration.y += (target.y - nodes[last].y) * stiffness - velocities[last].y * drag
        } else {
            acceleration.x -= velocities[last].x * 3
            acceleration.y -= velocities[last].y * 3
        }
        // The rounded end jiggles when it's jerked around.
        let jerk = min(hypot(acceleration.x, acceleration.y), 4000)
        wobbleVelocity += (-520 * wobble - 8 * wobbleVelocity + jerk * 0.6) * h
        wobble = min(max(wobble + wobbleVelocity * h, -8), 8)
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
        thickness = min(thickness + h * 2.5, 1)
        if let value = pinch {
            let next = value + h / 0.14
            if next >= 1 { split() } else { pinch = next }
        }
        advanceDrops(h, outline: outline)
    }

    /// The neck breaks at its middle: the end flies on as a drop, with a tiny one left where it broke.
    private mutating func split() {
        let last = LiquidSim.nodeCount - 1, middle = last / 2
        let direction = CGPoint(x: head.x - nodes[middle].x, y: head.y - nodes[middle].y)
        let size = max(hypot(direction.x, direction.y), 0.001)
        let along = CGPoint(x: direction.x / size, y: direction.y / size)
        let radius = max(headRadius * 0.85, 4)
        drops.append(LiquidDrop(position: head, velocity: CGPoint(x: velocities[last].x + along.x * 70, y: velocities[last].y + along.y * 70),
                                radius: radius, wobble: radius * 0.35, axis: along))
        let at = nodes[middle + 1]
        drops.append(LiquidDrop(position: at, velocity: CGPoint(x: velocities[last].x * 0.4, y: velocities[last].y * 0.4), radius: 3, wobble: 1, axis: along))
        let breakPoint = nodes[middle], base = nodes[0]
        for i in 0...last {
            let t = CGFloat(i) / CGFloat(last)
            nodes[i] = CGPoint(x: mix(base.x, breakPoint.x, t), y: mix(base.y, breakPoint.y, t))
            velocities[i] = .zero
        }
        wobble = 0; wobbleVelocity = 0; thickness = 0.45; pinch = nil
    }

    private mutating func advanceDrops(_ h: CGFloat, outline: IslandOutline) {
        for i in drops.indices.reversed() {
            var drop = drops[i]
            drop.age += h
            drop.wobbleVelocity += (-620 * drop.wobble - 6.5 * drop.wobbleVelocity) * h
            drop.wobble += drop.wobbleVelocity * h
            let gap = outline.distance(to: drop.position)
            if drop.age < 0.42 {
                drop.velocity.x -= drop.velocity.x * 3 * h
                drop.velocity.y += (LiquidSim.gravity - drop.velocity.y * 3) * h
            } else {
                let home = outline.point(at: outline.nearest(to: drop.position))
                let dx = home.x - drop.position.x, dy = home.y - drop.position.y, size = max(hypot(dx, dy), 1)
                drop.velocity.x += (dx / size * 700 - drop.velocity.x * 5) * h
                drop.velocity.y += (dy / size * 700 - drop.velocity.y * 5) * h
            }
            drop.position.x += drop.velocity.x * h
            drop.position.y += drop.velocity.y * h
            if gap < drop.radius * 0.7 || drop.age > 3 { drop.radius -= 70 * h }
            if drop.radius < 0.6 { drops.remove(at: i) } else { drops[i] = drop }
        }
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
        for drop in drops { d = min(d, drop.capsule.distance(point.x, point.y)) }
        return d
    }
    /// Whether a click here lands on the liquid, with some room because the pointer pulls ahead of it.
    func touches(_ point: CGPoint, outline: IslandOutline) -> Bool {
        !outline.rect.contains(point) && distance(to: point) < 12
    }

    /// Draws the liquid: pure black with a petroleum gloss, joined smoothly to the island, with a green glow
    /// around the part nearest its moving ends and a small highlight that makes it read as wet.
    func render(island: CGRect, cornerRadius: CGFloat, scale: CGFloat, clip: CGRect, time: CGFloat = 0) -> (image: CGImage, frame: CGRect)? {
        let strand = self.strand, dropParts = drops.map(\.capsule)
        guard !strand.isEmpty || !dropParts.isEmpty else { return nil }
        var box = CGRect.null
        for part in strand + dropParts {
            box = box.union(CGRect(x: min(part.a.x, part.b.x), y: min(part.a.y, part.b.y), width: abs(part.a.x - part.b.x), height: abs(part.a.y - part.b.y)).insetBy(dx: -max(part.ra, part.rb) - 34, dy: -max(part.ra, part.rb) - 34))
        }
        let frame = box.intersection(clip).integral
        guard !frame.isNull, frame.width >= 1, frame.height >= 1 else { return nil }
        let width = Int(frame.width * scale), height = Int(frame.height * scale)
        var focuses: [(x: CGFloat, y: CGFloat, r: CGFloat)] = drops.map { ($0.position.x, $0.position.y, $0.radius) }
        if !strand.isEmpty { focuses.append((head.x, head.y, headRadius)) }
        // Under the island's opaque window nothing needs drawing.
        let covered = island.insetBy(dx: cornerRadius + 1, dy: 0)
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let out = raw.bindMemory(to: UInt8.self).baseAddress!
            strand.withUnsafeBufferPointer { parts in
                dropParts.withUnsafeBufferPointer { dropBuffer in
                    for row in 0..<height {
                        let y = frame.maxY - (CGFloat(row) + 0.5) / scale
                        for column in 0..<width {
                            let x = frame.minX + (CGFloat(column) + 0.5) / scale
                            if covered.contains(CGPoint(x: x, y: y)) { continue }
                            var d = islandDistance(x, y, island, cornerRadius)
                            var nearest = CGFloat.greatestFiniteMagnitude
                            if !parts.isEmpty {
                                var strandDistance = CGFloat.greatestFiniteMagnitude
                                for part in parts { strandDistance = min(strandDistance, part.distance(x, y)) }
                                d = blend(d, strandDistance, 16)
                                nearest = strandDistance
                            }
                            for part in dropBuffer {
                                let dropDistance = part.distance(x, y)
                                d = blend(d, dropDistance, 12)
                                nearest = min(nearest, dropDistance)
                            }
                            if d > 26 { continue }
                            var nearness: CGFloat = 0, shine: CGFloat = 0
                            for focus in focuses {
                                let dx = x - focus.x, dy = y - focus.y
                                nearness = max(nearness, exp(-(dx * dx + dy * dy) / (2 * 52 * 52)))
                                if d < 0, focus.r > 4 {
                                    let sx = dx + focus.r * 0.3, sy = dy - focus.r * 0.38, spread = focus.r * 0.2
                                    shine = max(shine, exp(-(sx * sx + sy * sy) / (2 * spread * spread)) * 0.28)
                                }
                            }
                            var glow = exp(-(d / 1.3) * (d / 1.3)) * 0.95
                            if d > 0 { glow += exp(-d / 5.5) * 0.55 }
                            // Only the liquid glows, so the island's own edge fades out well inside this picture.
                            let reach = nearest > 0 ? exp(-(nearest / 14) * (nearest / 14)) : 1
                            glow = min(glow * nearness * reach, 1)
                            let cover = min(max(0.5 - d * scale, 0), 1)
                            let alpha = max(cover, min(glow + shine, 1))
                            // Oil catches more light toward its edge.
                            let oil = d < 0.5 ? Petroleum.gloss(x, y, time) * min(0.55 + exp(min(d, 0) / 7) * 0.9, 1.45) * cover : 0
                            let pixel = out + (row * width + column) * 4
                            pixel[0] = UInt8(min(glow * 0.29 + shine + oil, alpha) * 255)
                            pixel[1] = UInt8(min(glow * 0.93 + shine + oil, alpha) * 255)
                            pixel[2] = UInt8(min(glow * 0.47 + shine + oil, alpha) * 255)
                            pixel[3] = UInt8(alpha * 255)
                        }
                    }
                }
            }
        }
        guard let image = Petroleum.makeImage(pixels, width: width, height: height) else { return nil }
        return (image, frame)
    }
}

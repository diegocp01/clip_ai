import AppKit

func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func mix(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
    NSRect(x: mix(a.minX, b.minX, t), y: mix(a.minY, b.minY, t), width: mix(a.width, b.width, t), height: mix(a.height, b.height, t))
}
func smoothstep(_ from: CGFloat, _ to: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - from) / (to - from), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Shared luminous finish: a bright core, translucent shoulders and fading tips.
/// Geometry and animation belong to the caller.
enum SignalFinish {
    static func apply(to layer: CAGradientLayer, tint: NSColor, core: NSColor,
                      glowRadius: CGFloat = 5, glowOpacity: Float = 1) {
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.colors = [tint.withAlphaComponent(0), tint.withAlphaComponent(0.6), core,
                        tint.withAlphaComponent(0.6), tint.withAlphaComponent(0)].map(\.cgColor)
        layer.locations = [0, 0.3, 0.5, 0.7, 1]
        layer.shadowColor = tint.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = glowRadius
        layer.shadowOpacity = glowOpacity
    }
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

/// A slower, nearly critically damped arrival. The upright mark becomes a bead
/// before the horizontal glow spreads, with the same path on pointer exit.
struct HoverWake {
    private var spring = Spring(stiffness: 45, damping: 14)
    var value: CGFloat { spring.value }
    var target: CGFloat {
        get { spring.target }
        set { spring.target = newValue }
    }
    var isSettled: Bool { spring.isSettled }
    var bead: CGFloat { smoothstep(0.04, 0.62, value) }
    var drop: CGFloat { smoothstep(0, 0.38, value) }
    var glide: CGFloat { smoothstep(0.4, 0.88, value) }
    var spread: CGFloat { smoothstep(0.62, 1, value) }
    var crossfade: CGFloat { smoothstep(0.66, 0.98, value) }
    var attention: CGFloat { smoothstep(0.82, 1, value) }
    func frame(from rest: NSRect, to awake: NSRect) -> NSRect {
        var frame = mix(rest, awake, min(max(value, 0), 1))
        // Make room below the camera before the light travels there.
        frame.origin.y = mix(rest.minY, awake.minY, drop)
        frame.size.height = mix(rest.height, awake.height, drop)
        return frame
    }
    func line(from rest: NSRect, to awake: NSRect) -> NSRect {
        let width = mix(rest.width, 6, bead), height = mix(rest.height, awake.height, bead)
        return NSRect(x: mix(rest.midX, awake.midX, glide) - width / 2,
                      y: mix(rest.midY, awake.midY, drop) - height / 2, width: width, height: height)
    }
    mutating func step(_ dt: CGFloat) { spring.step(dt) }
    mutating func jump(to position: CGFloat) { spring.jump(to: position) }
}

/// The awake line's behavior: it moves side to side, then splits into two eyes that look
/// toward the pointer and blink, then flows back together. The first round is quick, so it
/// all shows within the hold that opens the composer.
struct SignalBar {
    static let firstSweep: CGFloat = 0.55
    static let firstRound: CGFloat = 2.6
    static let sweepTime: CGFloat = 2.4
    static let eyesTime: CGFloat = 2
    private(set) var time: CGFloat = 0
    private var sway = Spring(stiffness: 120, damping: 14)
    private var split = Spring(stiffness: 200, damping: 20)
    private var look = Spring(stiffness: 70, damping: 11)
    var pattern: String? = nil
    /// The notch hover's opening round, fitted inside the hold that opens the composer.
    private var quickRound: Bool { pattern == nil && time < SignalBar.firstRound }
    /// How long the eyes have been open, if they are.
    private var eyesOpen: CGFloat? {
        if let pattern { return pattern == "eyes" ? time.truncatingRemainder(dividingBy: 4.8) : nil }
        if quickRound { return time > SignalBar.firstSweep ? time - SignalBar.firstSweep : nil }
        let phase = (time - SignalBar.firstRound).truncatingRemainder(dividingBy: SignalBar.sweepTime + SignalBar.eyesTime)
        return phase > SignalBar.sweepTime ? phase - SignalBar.sweepTime : nil
    }
    var isEyes: Bool { eyesOpen != nil }
    /// Two quick closes while the eyes are open: 1 is shut.
    var blink: CGFloat {
        guard let open = eyesOpen else { return 0 }
        let first = quickRound ? (open - 0.28) / 0.05 : (open - 1.3) / 0.07
        let second = quickRound ? (open - 1.3) / 0.07 : (open - 2.4) / 0.07
        return min(exp(-first * first) + exp(-second * second), 1)
    }
    /// `pointer` runs from -1 at the island's left edge to 1 at its right.
    mutating func step(_ dt: CGFloat, pointer: CGFloat, swayScale: CGFloat = 1) {
        time += dt
        split.target = isEyes ? 1 : 0
        sway.target = isEyes ? 0 : sin(time * 2 * .pi / (quickRound ? 0.8 : 2.4)) * swayScale
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

/// A soft light that eases after the pointer, the same at any frame rate.
struct CursorGlow {
    private(set) var position = CGPoint.zero
    mutating func jump(to point: CGPoint) { position = point }
    mutating func follow(_ point: CGPoint, dt: CGFloat) {
        let ease = 1 - exp(-dt * 14)
        position.x += (point.x - position.x) * ease
        position.y += (point.y - position.y) * ease
    }
}

/// Opens the composer once the pointer has stayed on the island long enough. Opening
/// uses up the hold, so the pointer has to leave and come back to open it again.
struct DwellTimer {
    static let duration: CGFloat = 1
    private(set) var elapsed: CGFloat = 0
    private var armed = true
    var progress: CGFloat { min(elapsed / DwellTimer.duration, 1) }
    /// Returns true on the update where the hold completes.
    mutating func update(inside: Bool, dt: CGFloat) -> Bool {
        guard inside else { elapsed = 0; armed = true; return false }
        guard armed else { return false }
        elapsed += dt
        guard elapsed >= DwellTimer.duration else { return false }
        disarm()
        return true
    }
    mutating func disarm() { elapsed = 0; armed = false }
}

enum IslandShape {
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


/// Separate microphone and playback envelopes make speaker identity visible.
struct VoiceEnergy {
    private(set) var input: CGFloat = 0
    private(set) var output: CGFloat = 0
    private(set) var listening = true
    var level: CGFloat { max(input, output) }
    mutating func step(input targetInput: CGFloat, output targetOutput: CGFloat,
                       userSpeaking: Bool, fresh: Bool, dt: Double) {
        func smooth(_ value: CGFloat, _ raw: CGFloat) -> CGFloat {
            let target = fresh && raw.isFinite ? min(1, max(0, raw)) : 0
            let response = target > value ? 0.065 : 0.18
            let next = value + (target - value) * CGFloat(1 - exp(-min(max(dt, 0), 0.1) / response))
            return next < 0.001 ? 0 : next
        }
        input = smooth(input, targetInput); output = smooth(output, targetOutput)
        // Realtime speech detection gives a user's interruption priority over playback.
        if fresh && userSpeaking { listening = true }
        else if output > 0.04 { listening = false }
        else if output < 0.015 { listening = true }
    }
}

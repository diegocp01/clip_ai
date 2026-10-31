import AppKit

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

// Actual M5 display metrics, plus the same display positioned left of another.
for origin in [NSPoint.zero, NSPoint(x: -1710, y: 250)] {
    let screen = NSRect(origin: origin, size: NSSize(width: 1710, height: 1107))
    let left = NSRect(x: screen.minX, y: screen.maxY - 33.5, width: 762.5, height: 33.5)
    let right = NSRect(x: screen.minX + 947.5, y: left.minY, width: 762.5, height: 33.5)
    for expanded in [false, true] {
        let layout = IslandLayout(screen: screen, safeTop: 33.5, leftArea: left, rightArea: right, expanded: expanded)
        if expanded { expect(layout.frame.midX == screen.midX, "Island must follow display coordinates") }
        expect(layout.isNotched, "Hardware notch must be detected")
        if expanded {
            let bridge = layout.notchBridge!
            expect(layout.frame.maxY == left.minY, "Expanded controls must stay below the camera")
            expect(bridge.minX == left.maxX && bridge.maxX == right.minX, "Expanded bridge must not cover adjacent menu items")
            expect(bridge.maxY == screen.maxY && bridge.minY == layout.frame.maxY, "Camera cover must stop at the glass edge")
            expect(!bridge.intersects(layout.frame), "Black camera cover must never show through the glass body")
        } else {
            expect(layout.frame.maxY == screen.maxY && layout.frame.minY == left.minY, "Collapsed island must occupy the notch row, never hang below it")
            expect(layout.notchBridge == nil, "Collapsed island must not leave a connector below the notch")
            let onScreen = { (rect: NSRect, layout: IslandLayout) in rect.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY) }
            let resting = layout.frame.width
            expect(resting == 185 + 24, "Resting island must be only slightly wider than the camera")
            expect(layout.frame.minX == left.maxX, "Resting island must not extend left of the camera")
            expect(right.contains(onScreen(layout.wakeArea, layout)), "Only the line's side may wake the island")
            let hovered = IslandLayout(screen: screen, safeTop: 33.5, leftArea: left, rightArea: right, expanded: false, content: .idle, hovered: true)
            expect(hovered.frame.width == 185 + 48 && hovered.frame.midX == screen.midX, "Hover must grow only slightly and evenly past the camera, leaving no empty blocks")
            expect(onScreen(hovered.wakeArea, hovered) == hovered.frame, "The whole awake island must keep it awake")
            expect(hovered.frame.maxY == screen.maxY && hovered.frame.minY < left.minY, "Awake island must stay on the screen edge and hang below the camera")
            let sensing = onScreen(hovered.lineFrame, hovered)
            expect(sensing.maxY <= left.minY && hovered.frame.contains(sensing), "Awake line must sit below the camera, where there are pixels")
            expect(sensing.midX == screen.midX && sensing.width < hovered.frame.width, "Awake line must be centered under the camera, inside the island")
            expect(layout.lineFrame.height > layout.lineFrame.width, "Resting line must be vertical")
            expect(right.contains(onScreen(layout.lineFrame, layout)) && layout.frame.contains(onScreen(layout.lineFrame, layout)), "Resting line must be visible entirely right of the physical camera")
            let audio = IslandLayout(screen: screen, safeTop: 33.5, leftArea: left, rightArea: right, expanded: false, content: .audio)
            expect(audio.frame.width > resting, "Audio must grow the island")
            expect(audio.frame.minX == left.maxX, "Audio island must not extend left of the camera")
            expect(right.contains(onScreen(audio.activityFrame, audio)) && audio.frame.contains(onScreen(audio.activityFrame, audio)), "Activity indicator must be visible entirely right of the physical camera")
            for textWidth: CGFloat in [40, 600] {
                let status = IslandLayout(screen: screen, safeTop: 33.5, leftArea: left, rightArea: right, expanded: false, content: .status(textWidth: textWidth))
                expect(status.frame.width <= 185 + 260, "Long status text must truncate instead of covering the menu bar")
                expect(left.contains(onScreen(status.statusFrame, status)) && status.frame.contains(onScreen(status.statusFrame, status)), "Status text must be visible entirely left of the physical camera")
                expect(right.contains(onScreen(status.lineFrame, status)), "Status line must be right of the physical camera")
            }
        }
    }
}
let external = NSRect(x: 1710, y: -400, width: 2560, height: 1440)
for expanded in [false, true] {
    let layout = IslandLayout(screen: external, safeTop: 0, leftArea: nil, rightArea: nil, expanded: expanded)
    expect(layout.notchBridge == nil, "External/non-notched screens must retain a floating pill")
    expect(layout.frame.maxY == external.maxY - 4, "Floating pill keeps its top inset")
    expect(layout.frame.width == (expanded ? ComposerGeometry.size.width : 30), "Floating pill rests at line size")
    expect(layout.bounds.contains(layout.lineFrame), "Line must remain inside the pill")
    expect(layout.frame.midX == external.midX, "External display origin must be respected")
}
let unknown = IslandLayout(screen: external, safeTop: 30, leftArea: nil, rightArea: nil, expanded: false)
expect(unknown.notchBridge == nil && unknown.frame.maxY == external.maxY - 30, "Missing notch bounds must fall back below the safe area")
let audioPill = IslandLayout(screen: external, safeTop: 0, leftArea: nil, rightArea: nil, expanded: false, content: .audio)
let hoveredPill = IslandLayout(screen: external, safeTop: 0, leftArea: nil, rightArea: nil, expanded: false, content: .idle, hovered: true)
expect(hoveredPill.frame.width > 30 && hoveredPill.frame.midX == external.midX && hoveredPill.bounds.contains(hoveredPill.lineFrame), "Floating pill must grow around its line on hover")
expect(hoveredPill.lineFrame.width > hoveredPill.lineFrame.height, "Floating pill's awake line must lie flat")
expect(audioPill.frame.width == 40 && audioPill.bounds.contains(audioPill.activityFrame), "Floating pill must fit the waveform")
let statusPill = IslandLayout(screen: external, safeTop: 0, leftArea: nil, rightArea: nil, expanded: false, content: .status(textWidth: 600))
expect(statusPill.frame.width == 278 && statusPill.bounds.contains(statusPill.statusFrame), "Floating pill must cap and fit status text")
// The spring settles exactly on its target, overshooting a little on the way.
var spring = Spring(stiffness: 150, damping: 17)
spring.target = 1
var peak: CGFloat = 0
for _ in 0..<240 { spring.step(1.0 / 60); peak = max(peak, spring.value) }
expect(spring.value == 1 && spring.isSettled && peak > 1 && peak < 1.2, "Wake spring must settle on target after a small overshoot")

// The tether holds while near, and separates when too far, too slow or clicked away.
var tether = GooTether()
expect(!tether.update(inside: false, distance: 5, pressed: false, dt: 0.1) && !tether.attached, "Passing near must not attach")
expect(!tether.update(inside: true, distance: 0, pressed: false, dt: 0.1) && tether.attached, "Being inside must attach")
expect(!tether.update(inside: false, distance: 60, pressed: false, dt: 0.1) && tether.attached, "Nearby pointer must stay attached")
expect(tether.update(inside: false, distance: GooTether.reach + 1, pressed: false, dt: 0.1) && !tether.attached, "Too far must separate")
expect(!tether.update(inside: false, distance: 0, pressed: false, dt: 0.1), "Separating must only report once")
_ = tether.update(inside: true, distance: 0, pressed: false, dt: 0.1)
var waited = 0
while !tether.update(inside: false, distance: 10, pressed: false, dt: 0.1) { waited += 1; expect(waited < 100, "Tether must run out of patience") }
expect(CGFloat(waited) * 0.1 <= GooTether.patience + 0.11, "Tether must separate after its patience")
_ = tether.update(inside: true, distance: 0, pressed: false, dt: 0.1)
expect(tether.update(inside: false, distance: 10, pressed: true, dt: 0.1), "Clicking elsewhere must separate")
_ = tether.update(inside: true, distance: 0, pressed: false, dt: 0.1)
expect(!tether.update(inside: true, distance: 0, pressed: true, dt: 0.1) && tether.attached, "Clicking the island must not separate")

// The outline runs down the left, across the bottom and up the right.
let island = IslandOutline(rect: CGRect(x: 100, y: 200, width: 273, height: 44))
expect(island.point(at: 0) == CGPoint(x: 100, y: 244) && island.point(at: island.length) == CGPoint(x: 373, y: 244), "Outline must start and end on the top edge")
for point in [CGPoint(x: 200, y: 150), CGPoint(x: 400, y: 220), CGPoint(x: 50, y: 220), CGPoint(x: 400, y: 150)] {
    let nearest = island.point(at: island.nearest(to: point))
    expect(abs(hypot(point.x - nearest.x, point.y - nearest.y) - island.distance(to: point)) < 0.001, "Nearest outline point must match the distance")
}
expect(island.point(at: island.nearest(to: CGPoint(x: 200, y: 150))) == CGPoint(x: 200, y: 200), "Point below must anchor on the bottom edge")

// The awake line wanders side to side, then splits into two eyes that look at the pointer and blink.
let barLine = CGRect(x: 51.5, y: 4, width: 130, height: 2)
let barBounds = CGRect(x: 0, y: 0, width: 233, height: 44)
var bar = SignalBar()
var leftmost = CGFloat.infinity, rightmost = -CGFloat.infinity
for _ in 0..<Int(SignalBar.sweepTime * 60) {
    bar.step(1.0 / 60, pointer: 0)
    let parts = bar.bars(line: barLine, room: 51.5)
    leftmost = min(leftmost, parts.left.midX); rightmost = max(rightmost, parts.left.midX)
    expect(barBounds.contains(parts.left) && barBounds.contains(parts.right), "The line must stay inside the island")
}
expect(!bar.isEyes && leftmost < barLine.midX - 15 && rightmost > barLine.midX + 15, "The line must move left and right")
expect(abs(bar.bars(line: barLine, room: 51.5).left.midX - bar.bars(line: barLine, room: 51.5).right.midX) < 8, "While sweeping it must read as one line")
for _ in 0..<60 { bar.step(1.0 / 60, pointer: 1) }
expect(bar.isEyes, "It must split into eyes after sweeping")
let lookingRight = bar.bars(line: barLine, room: 51.5)
expect(lookingRight.right.minX > lookingRight.left.maxX, "The eyes must be fully apart")
expect(lookingRight.left.width < barLine.width / 2, "Each eye must be much shorter than the line")
expect((lookingRight.left.midX + lookingRight.right.midX) / 2 > barLine.midX + 10, "The eyes must look toward the pointer")
expect(barBounds.contains(lookingRight.left) && barBounds.contains(lookingRight.right), "The eyes must stay inside the island")
for _ in 0..<60 { bar.step(1.0 / 60, pointer: -1) }
let lookingLeft = bar.bars(line: barLine, room: 51.5)
expect((lookingLeft.left.midX + lookingLeft.right.midX) / 2 < barLine.midX - 10, "The eyes must follow the pointer across")
var blinked = false, shortest = CGFloat.infinity
for _ in 0..<Int(SignalBar.eyesTime * 60) {
    if bar.isEyes { shortest = min(shortest, bar.bars(line: barLine, room: 51.5).left.height); if bar.blink > 0.9 { blinked = true } }
    bar.step(1.0 / 60, pointer: 0)
}
expect(blinked && shortest < barLine.height, "The eyes must blink")
for _ in 0..<60 { bar.step(1.0 / 60, pointer: 0) }
expect(!bar.isEyes, "The eyes must flow back into one line")

// The liquid behaves like something heavy and viscous rather than following the pointer exactly.
func run(_ sim: inout LiquidSim, _ seconds: CGFloat, pointer: CGPoint?, each: (LiquidSim) -> Void = { _ in }) {
    for _ in 0..<Int(seconds * 60) {
        sim.step(1.0 / 60, outline: island, pointer: pointer)
        for node in sim.nodes { expect(node.x.isFinite && node.y.isFinite, "Liquid must stay finite") }
        each(sim)
    }
}
var liquid = LiquidSim()
expect(liquid.isSettled, "New liquid must be at rest")
let below = CGPoint(x: 236, y: 130)
liquid.attach(at: island.point(at: island.nearest(to: below)))
run(&liquid, 0.05, pointer: below)
expect(liquid.length < 30, "Liquid must lag behind the pointer at first")
var longest: CGFloat = 0
run(&liquid, 2, pointer: below) { longest = max(longest, $0.length) }
expect(liquid.length > 50 && longest > liquid.length + 1, "Liquid must reach toward the pointer, overshoot and settle")
expect(liquid.distance(to: liquid.head) < 0, "The rounded end must be inside the liquid")
expect(liquid.distance(to: CGPoint(x: 600, y: 600)) > 0, "Far away must be outside the liquid")
expect(liquid.touches(liquid.head, outline: island), "A click on the liquid must count")
expect(!liquid.touches(CGPoint(x: 236, y: 220), outline: island), "The island handles its own clicks")
expect(!liquid.touches(CGPoint(x: 600, y: 600), outline: island), "A click far away must not count")

// It thins as it stretches.
let stretchedNeck = liquid.neckRadius
var short = LiquidSim()
let close = CGPoint(x: 236, y: 180)
short.attach(at: island.point(at: island.nearest(to: close)))
run(&short, 2, pointer: close)
expect(short.neckRadius > stretchedNeck + 3, "A longer strand must have a thinner neck")

// Gravity makes a sideways strand sag.
var sideways = LiquidSim()
let beside = CGPoint(x: 460, y: 225)
sideways.attach(at: island.point(at: island.nearest(to: beside)))
run(&sideways, 2, pointer: beside)
expect(sideways.nodes[3].y < (sideways.nodes[0].y + sideways.head.y) / 2, "A sideways strand must sag under gravity")

// The neck gives way, the end flies on as a drop, and everything merges back.
let before = liquid.head
liquid.separate()
run(&liquid, 0.3, pointer: nil)
expect(liquid.drops.count == 2 && !liquid.isSettled, "Separating must leave a drop and a smaller one")
let drop = liquid.drops[0]
expect(hypot(drop.position.x - before.x, drop.position.y - before.y) < 60, "The drop must carry on from where the end was")
expect(drop.radius > liquid.drops[1].radius, "The main drop must be the larger one")
expect(liquid.distance(to: drop.position) < 0, "A drop must be solid")
expect(liquid.length < 40, "The stump must recoil")
var merged = false
run(&liquid, 4, pointer: nil) { if $0.isSettled { merged = true } }
expect(merged && liquid.isSettled && liquid.drops.isEmpty, "Drops must merge back and the liquid must come to rest")

// It's drawn as solid black with a green glow, and not at all when there's no liquid.
expect(liquid.render(island: island.rect, cornerRadius: 18, scale: 2, clip: CGRect(x: 0, y: 0, width: 800, height: 800)) == nil, "Settled liquid must draw nothing")
var drawn = LiquidSim()
drawn.attach(at: island.point(at: island.nearest(to: below)))
run(&drawn, 2, pointer: below)
let clip = CGRect(x: 0, y: 0, width: 800, height: 800)
let picture = drawn.render(island: island.rect, cornerRadius: 18, scale: 2, clip: clip)!
expect(picture.frame.contains(drawn.head) && clip.contains(picture.frame), "The picture must cover the liquid inside the panel")
let bitmap = NSBitmapImageRep(cgImage: picture.image)
func pixel(_ point: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    let color = bitmap.colorAt(x: Int((point.x - picture.frame.minX) * 2), y: Int((picture.frame.maxY - point.y) * 2))!
    return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
}
let middle = pixel(CGPoint(x: drawn.nodes[3].x, y: drawn.nodes[3].y))
expect(middle.a > 0.99 && max(middle.r, middle.g, middle.b) < 0.45, "The inside of the liquid must be solid and dark")
expect(pixel(drawn.head).a > 0.99, "The liquid's end must be drawn")
let outside = pixel(CGPoint(x: drawn.head.x + 12.5 + 12, y: drawn.head.y - 4))
expect(outside.a < 0.6 && outside.g > outside.r, "Outside the liquid must be a green glow, not black")
// The petroleum look is texture only: colorless, mostly pure black, and drifting over time.
var brightest: CGFloat = 0, blackPoints = 0, points = 0
for x in stride(from: CGFloat(0), to: 400, by: 3) {
    for y in stride(from: CGFloat(0), to: 200, by: 3) {
        let level = Petroleum.gloss(x, y, 1)
        brightest = max(brightest, level); points += 1
        if level == 0 { blackPoints += 1 }
    }
}
expect(brightest > 0.05 && brightest <= 0.2, "The gloss must show without stopping it reading as black")
expect(blackPoints * 2 > points, "Most of the surface must be pure black")
let moved = (0..<80).contains { i in
    let x = CGFloat(i) * 9
    return abs(Petroleum.gloss(x, 50, 1) - Petroleum.gloss(x, 50, 9)) > 0.01
}
expect(moved, "The gloss must drift over time")
let oilArea = CGRect(x: 100, y: 200, width: 100, height: 44)
let oilHole = CGRect(x: 120, y: 214, width: 60, height: 30)
let oilBitmap = NSBitmapImageRep(cgImage: Petroleum.image(area: oilArea, hole: oilHole, time: 1)!)
expect(oilBitmap.colorAt(x: 50, y: 5)!.alphaComponent == 0 && oilBitmap.colorAt(x: 50, y: 40)!.alphaComponent == 1 && oilBitmap.colorAt(x: 5, y: 5)!.alphaComponent == 1, "The texture must skip the camera and cover the rest")
for x in stride(from: 0, to: 100, by: 7) {
    let color = oilBitmap.colorAt(x: x, y: 40)!
    expect(color.redComponent == color.greenComponent && color.greenComponent == color.blueComponent, "The texture must have no color")
}
print("Native island layout checks passed (notched, shifted, external, and missing bounds).")

// Opening/closing shares the final top edge, and every composer control stays visible.
let composerBounds = NSRect(origin: .zero, size: ComposerGeometry.size)
let controls = [ComposerGeometry.prompt, ComposerGeometry.send, ComposerGeometry.collapse,
                ComposerGeometry.screen, ComposerGeometry.talk, ComposerGeometry.voice,
                ComposerGeometry.tier, ComposerGeometry.more]
for (i, control) in controls.enumerated() {
    expect(composerBounds.contains(control), "Composer control must fit inside the surface")
    for other in controls.dropFirst(i + 1) { expect(!control.intersects(other), "Composer controls must not overlap") }
}
let morphSources = [NSRect(x: 762.5, y: 1073.5, width: 209, height: 33.5),
                    NSRect(x: -800, y: 250, width: 233, height: 43.5),
                    NSRect(x: 400, y: 900, width: 30, height: 22)]
for source in morphSources {
    let target = NSRect(x: source.midX - 220, y: source.maxY - 209.5, width: 440, height: 176)
    expect(ComposerGeometry.morphFrame(from: source, to: target, progress: 0) == source, "Morph must begin at the actual visible island")
    expect(ComposerGeometry.morphFrame(from: source, to: target, progress: 1) == target, "Morph must end at composer bounds")
    for step in 0...60 {
        let p = CGFloat(step) / 60
        let frame = ComposerGeometry.morphFrame(from: source, to: target, progress: p)
        expect(frame.width >= min(source.width, target.width) && frame.height >= min(source.height, target.height), "Surface must never collapse to a line or disappear")
        let reverse = ComposerGeometry.morphFrame(from: frame, to: source, progress: 0)
        expect(reverse == frame, "Interrupting a morph must keep its current frame")
        let backwards = ComposerGeometry.morphFrame(from: target, to: source, progress: 1 - p)
        expect(abs(frame.minX - backwards.minX) < 0.0001 && abs(frame.height - backwards.height) < 0.0001, "Opening and closing must follow the same shape path")
    }
}
print("Composer bounds, clean camera boundary, continuous morph and reversal checks passed.")

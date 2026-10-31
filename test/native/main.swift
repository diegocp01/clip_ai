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
// At startup a light sweeps around the camera, ending exactly where the resting line sits.
do {
    let screen = NSRect(x: 0, y: 0, width: 1710, height: 1107)
    let left = NSRect(x: 0, y: screen.maxY - 33.5, width: 762.5, height: 33.5)
    let right = NSRect(x: 947.5, y: left.minY, width: 762.5, height: 33.5)
    let loading = IslandLayout(screen: screen, safeTop: 33.5, leftArea: left, rightArea: right, expanded: false, content: .loading)
    let resting = IslandLayout(screen: screen, safeTop: 33.5, leftArea: left, rightArea: right, expanded: false)
    let onScreen = { (p: CGPoint) in CGPoint(x: p.x + loading.frame.minX, y: p.y + loading.frame.minY) }
    let path = loading.loadingPath.map(onScreen)
    expect(loading.frame.midX == screen.midX && loading.frame.minY < left.minY, "The startup shape must wrap the camera evenly")
    expect(path.count == 4 && path.allSatisfy { loading.frame.contains($0) }, "The light must stay inside the island")
    expect(path[0].x < left.maxX && path[1].x < left.maxX, "The light must start left of the camera")
    expect(path[1].y < left.minY && path[2].y < left.minY, "The light must pass under the camera, where there are pixels")
    expect(path[2].x > right.minX && path[3].x > right.minX, "The light must finish right of the camera")
    expect(path[3].x == resting.lineFrame.midX + resting.frame.minX && path[3].y == resting.lineFrame.maxY + resting.frame.minY, "The light must end on the resting line")
    let settled = loading.lineFrame.offsetBy(dx: loading.frame.minX, dy: loading.frame.minY), line = resting.lineFrame.offsetBy(dx: resting.frame.minX, dy: resting.frame.minY)
    expect(settled == line, "The light must become the resting line without moving")
    expect(loading.loadingLineFraction > 0 && loading.loadingLineFraction < 0.1, "The resting line must be a small part of the path")
    let pill = IslandLayout(screen: NSRect(x: 0, y: 0, width: 2560, height: 1440), safeTop: 0, leftArea: nil, rightArea: nil, expanded: false, content: .loading)
    expect(pill.loadingPath.count == 2 && pill.loadingPath.allSatisfy { pill.bounds.contains($0) } && pill.bounds.contains(pill.lineFrame), "Without a camera the light must cross the pill")
}

// The spring settles exactly on its target, overshooting a little on the way.
var spring = Spring(stiffness: 150, damping: 17)
spring.target = 1
var peak: CGFloat = 0
for _ in 0..<240 { spring.step(1.0 / 60); peak = max(peak, spring.value) }
expect(spring.value == 1 && spring.isSettled && peak > 1 && peak < 1.2, "Wake spring must settle on target after a small overshoot")

// Resting on the island for a second opens it, once, until the pointer leaves and returns.
var hold = DwellTimer()
expect(!hold.update(inside: true, dt: 0.5) && abs(hold.progress - 0.5) < 0.001, "The hold must fill up over time")
expect(!hold.update(inside: false, dt: 0.1) && hold.progress == 0, "Leaving must restart the hold")
expect(!hold.update(inside: true, dt: 0.9), "A partial hold must not open")
expect(hold.update(inside: true, dt: 0.1), "A full second must open")
expect(hold.progress == 0, "The ring must clear on opening")
expect(!hold.update(inside: true, dt: 5) && hold.progress == 0, "Staying put must not open it again")
_ = hold.update(inside: false, dt: 0.1)
expect(!hold.update(inside: true, dt: 0.5) && hold.update(inside: true, dt: 0.5), "Returning must allow another hold")
hold = DwellTimer()
_ = hold.update(inside: true, dt: 0.5)
hold.disarm()
expect(!hold.update(inside: true, dt: 2), "Opening some other way must use up the hold")

// The tether holds while near, and separates when too far, too slow or clicked away.
var tether = GooTether()
expect(!tether.update(inside: false, distance: 5, pressed: false, dt: 0.1) && !tether.attached, "Passing near must not attach")
expect(!tether.update(inside: true, distance: 0, pressed: false, dt: 0.1) && tether.attached, "Being inside must attach")
expect(!tether.update(inside: false, distance: 30, pressed: false, dt: 0.1) && tether.attached, "Nearby pointer must stay attached")
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

// The liquid grabs a little like something heavy and viscous, and doesn't follow the pointer exactly.
func run(_ sim: inout LiquidSim, _ seconds: CGFloat, pointer: CGPoint?, each: (LiquidSim) -> Void = { _ in }) {
    for _ in 0..<Int(seconds * 60) {
        sim.step(1.0 / 60, outline: island, pointer: pointer)
        for node in sim.nodes { expect(node.x.isFinite && node.y.isFinite, "Liquid must stay finite") }
        each(sim)
    }
}
var liquid = LiquidSim()
expect(liquid.isSettled, "New liquid must be at rest")
let below = CGPoint(x: 236, y: 165)
liquid.attach(at: island.point(at: island.nearest(to: below)))
run(&liquid, 0.05, pointer: below)
expect(liquid.length < LiquidSim.maxReach - 5, "Liquid must lag behind the pointer at first")
var longest: CGFloat = 0
run(&liquid, 2, pointer: below) { longest = max(longest, $0.length) }
expect(liquid.length > 12 && longest > liquid.length + 0.5, "Liquid must reach toward the pointer, overshoot and settle")
expect(longest < LiquidSim.maxReach + 8, "The grab must stay small")
expect(liquid.distance(to: liquid.head) < 0, "The rounded end must be inside the liquid")
expect(liquid.distance(to: CGPoint(x: 600, y: 600)) > 0, "Far away must be outside the liquid")

// However far the pointer goes, the reach stays short.
var far = LiquidSim()
let distant = CGPoint(x: 236, y: 60)
far.attach(at: island.point(at: island.nearest(to: distant)))
var farthest: CGFloat = 0
run(&far, 2, pointer: distant) { farthest = max(farthest, island.distance(to: $0.head)) }
expect(farthest < LiquidSim.maxReach + 8, "The reach must stay short however far the pointer goes")

// It thins as it stretches.
var short = LiquidSim()
let close = CGPoint(x: 236, y: 172)
short.attach(at: island.point(at: island.nearest(to: close)))
run(&short, 2, pointer: close)
expect(short.neckRadius > far.neckRadius + 1, "A longer pull must have a thinner neck")

// Gravity makes a sideways pull sag.
var sideways = LiquidSim()
let beside = CGPoint(x: 460, y: 225)
sideways.attach(at: island.point(at: island.nearest(to: beside)))
run(&sideways, 2, pointer: beside)
expect(sideways.nodes[3].y < (sideways.nodes[0].y + sideways.head.y) / 2, "A sideways pull must sag under gravity")

// Letting go, it flows back quickly in one piece, with nothing left behind.
var settledAt: CGFloat?, elapsed: CGFloat = 0
run(&liquid, 2, pointer: nil) {
    elapsed += 1.0 / 60
    if $0.isSettled && settledAt == nil { settledAt = elapsed }
    expect($0.distance(to: CGPoint(x: 236, y: 100)) > 0, "Nothing may detach from the island")
}
expect(settledAt != nil && settledAt! < 1.5 && liquid.isSettled, "Letting go must flow back and come to rest")
expect(liquid.render(island: island.rect, cornerRadius: 18, scale: 2, clip: CGRect(x: 0, y: 0, width: 800, height: 800)) == nil, "Settled liquid must draw nothing")

// It's drawn pure black with a green edge, with no color or texture inside.
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
for point in [drawn.nodes[3], drawn.head, CGPoint(x: drawn.nodes[1].x, y: drawn.nodes[1].y - 1)] {
    let inside = pixel(point)
    expect(inside.a > 0.99 && max(inside.r, inside.g, inside.b) < 0.004, "The inside of the liquid must be pure black")
}
var edge = drawn.head
while drawn.distance(to: edge) < 1.5 { edge.y -= 0.5 }
let outside = pixel(edge)
expect(outside.a < 0.9 && outside.g > outside.r && outside.g > 0.05, "Just outside the liquid must be a green edge, not black")
print("Native island layout checks passed (notched, shifted, external, and missing bounds).")

// Opening/closing shares the final top edge, and every composer control stays visible.
let composerBounds = NSRect(origin: .zero, size: ComposerGeometry.size)
let controls = [ComposerGeometry.modelCaption, ComposerGeometry.input, ComposerGeometry.send, ComposerGeometry.collapse,
                ComposerGeometry.screen, ComposerGeometry.talk, ComposerGeometry.voice,
                ComposerGeometry.draw, ComposerGeometry.more, ComposerGeometry.provider]
for (i, control) in controls.enumerated() {
    expect(composerBounds.contains(control), "Composer control must fit inside the surface")
    let shell = ComposerGeometry.shellPath(in: composerBounds)
    for point in [NSPoint(x: control.minX, y: control.minY), NSPoint(x: control.maxX, y: control.minY),
                  NSPoint(x: control.minX, y: control.maxY), NSPoint(x: control.maxX, y: control.maxY)] {
        expect(shell.contains(point), "Every control must remain inside the curved petroleum shell")
    }
    for other in controls.dropFirst(i + 1) { expect(!control.intersects(other), "Composer controls must not overlap") }
}
let morphSources = [NSRect(x: 762.5, y: 1073.5, width: 209, height: 33.5),
                    NSRect(x: -800, y: 250, width: 233, height: 43.5),
                    NSRect(x: 400, y: 900, width: 30, height: 22)]
for source in morphSources {
    let target = NSRect(x: source.midX - ComposerGeometry.size.width / 2, y: source.maxY - ComposerGeometry.size.height - 33.5, width: ComposerGeometry.size.width, height: ComposerGeometry.size.height)
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
let composerLayout = IslandLayout(screen: external, safeTop: 0, leftArea: nil, rightArea: nil, expanded: true)
expect(!composerLayout.statusFrame.intersects(ComposerGeometry.provider), "Status text must not run under the model toggle")
for frame in [composerLayout.statusFrame, composerLayout.activityFrame, composerLayout.lineFrame] {
    expect(composerBounds.contains(frame), "Busy/error/audio status must fit the shorter composer")
    expect(!frame.intersects(ComposerGeometry.input), "Status must not cover the typing area")
}
print("Composer bounds, clean camera boundary, continuous morph and reversal checks passed.")

// Hover sectors belong to one option and never cover the typing controls.
for (index, frame) in ComposerGeometry.optionFrames.enumerated() {
    expect(ComposerGeometry.option(at: NSPoint(x: frame.midX, y: frame.midY)) == index,
           "Each circular option must highlight its own wedge")
}
for frame in [ComposerGeometry.input, ComposerGeometry.send, ComposerGeometry.modelCaption] {
    for point in [NSPoint(x: frame.minX, y: frame.minY), NSPoint(x: frame.midX, y: frame.midY),
                  NSPoint(x: frame.maxX - 0.1, y: frame.maxY - 0.1)] {
        expect(ComposerGeometry.option(at: point) == nil, "Typing and Send must not highlight an option")
    }
}
for point in [NSPoint(x: -1, y: 100), NSPoint(x: 480, y: 0), NSPoint(x: 240, y: -1)] {
    expect(ComposerGeometry.option(at: point) == nil, "Leaving the shell clears the option")
}
print("Composer hover sectors and central input exclusion passed.")

// Selection persistence and provider isolation use the same catalog as the server.
let models = try JSONDecoder().decode([DrawingModel].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let suite = "clippy-model-tests-\(UUID().uuidString)"
let preferences = UserDefaults(suiteName: suite)!
defer { preferences.removePersistentDomain(forName: suite) }
let choices = DrawingPreferences(models: models, defaults: preferences)
expect(choices.model(for: "gpt").id == "gpt-6.1-terra", "GPT default must stay Terra")
choices.select(model: "gpt-6.1-sol", provider: "gpt")
choices.select(effort: "high", provider: "gpt")
expect(choices.model(for: "claude").id == "claude-sonnet-5-5", "Provider selections must stay independent")
choices.select(model: "claude-opus-5-5", provider: "gpt")
expect(choices.model(for: "gpt").id == "gpt-6.1-sol", "Reject cross-provider models")
choices.select(effort: "invalid", provider: "gpt")
expect(choices.effort(for: "gpt") == "high", "Reject unsupported efforts")
let restored = DrawingPreferences(models: models, defaults: preferences)
expect(restored.request(for: "gpt")["model"] == "gpt-6.1-sol" && restored.request(for: "gpt")["reasoningEffort"] == "high", "Model and effort must survive a relaunch")
restored.select(model: "gpt-6.1-terra", provider: "gpt")
expect(restored.effort(for: "gpt") == "low", "Each model keeps its own effort")
print("Drawing model and effort preferences passed.")

// Selection counts describe words rather than whitespace runs or punctuation.
expect(SelectionSummary.wordCount("Hello, world!\nOne more word.") == 5, "Count words across lines and punctuation")
expect(SelectionSummary.wordCount("   \n!!! 🙂") == 0, "Whitespace, punctuation and emoji are not words")
expect(SelectionSummary.wordCount("café déjà vu") == 3, "Count accented words")
expect(SelectionSummary.label(for: 1) == "1 word | selected text", "Use singular for one word")
expect(SelectionSummary.label(for: 12) == "12 words | selected text", "Use requested badge wording")
expect(SelectionSummary.label(for: 0) == nil, "Hide the empty selection badge")
expect(composerBounds.contains(ComposerGeometry.selectionIndicator), "Selection badge stays inside composer")
expect(!ComposerGeometry.selectionIndicator.intersects(ComposerGeometry.input), "Selection badge must not cover input")
for frame in ComposerGeometry.optionFrames + [ComposerGeometry.send] {
    expect(!ComposerGeometry.selectionIndicator.intersects(frame), "Selection badge must not overlap controls")
}
print("Selected-text word counting and badge geometry passed.")

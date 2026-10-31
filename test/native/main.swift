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

// The light eases after the pointer instead of snapping to it, the same at any frame rate.
var glow = CursorGlow()
glow.jump(to: CGPoint(x: 100, y: 50))
expect(glow.position == CGPoint(x: 100, y: 50), "The light must start at the pointer")
glow.follow(CGPoint(x: 200, y: 50), dt: 1.0 / 60)
expect(glow.position.x > 100 && glow.position.x < 130, "The light must trail the pointer")
for _ in 0..<60 { glow.follow(CGPoint(x: 200, y: 50), dt: 1.0 / 60) }
expect(abs(glow.position.x - 200) < 0.5, "The light must catch up within a second")
var fast = CursorGlow(), slow = CursorGlow()
for _ in 0..<12 { fast.follow(CGPoint(x: 100, y: 0), dt: 1.0 / 120) }
for _ in 0..<3 { slow.follow(CGPoint(x: 100, y: 0), dt: 1.0 / 30) }
expect(abs(fast.position.x - slow.position.x) < 0.01, "The light must move the same at any frame rate")

// Within the first second, the line moves both ways, splits into eyes that look at the pointer, and blinks.
let barLine = CGRect(x: 51.5, y: 4, width: 130, height: 2)
let barBounds = CGRect(x: 0, y: 0, width: 233, height: 44)
var bar = SignalBar()
var leftmost = CGFloat.infinity, rightmost = -CGFloat.infinity
for _ in 0..<Int(SignalBar.firstSweep * 60) {
    bar.step(1.0 / 60, pointer: 0)
    let parts = bar.bars(line: barLine, room: 51.5)
    leftmost = min(leftmost, parts.left.midX); rightmost = max(rightmost, parts.left.midX)
    expect(barBounds.contains(parts.left) && barBounds.contains(parts.right), "The line must stay inside the island")
}
expect(!bar.isEyes && leftmost < barLine.midX - 5 && rightmost > barLine.midX + 5, "The line must move left and right")
var blinked = false, shortest = CGFloat.infinity, widestGap: CGFloat = 0
for _ in Int(SignalBar.firstSweep * 60)..<60 {
    bar.step(1.0 / 60, pointer: 1)
    let parts = bar.bars(line: barLine, room: 51.5)
    shortest = min(shortest, parts.left.height); widestGap = max(widestGap, parts.right.minX - parts.left.maxX)
    expect(barBounds.contains(parts.left) && barBounds.contains(parts.right), "The eyes must stay inside the island")
    if bar.blink > 0.9 { blinked = true }
}
expect(bar.isEyes && bar.time >= 0.99, "It must split into eyes within the hold")
expect(widestGap > 5, "The eyes must come apart before the composer opens")
expect(blinked && shortest < barLine.height, "The eyes must blink before the composer opens")
let lookingRight = bar.bars(line: barLine, room: 51.5)
expect(lookingRight.left.width < barLine.width / 2, "Each eye must be much shorter than the line")
expect((lookingRight.left.midX + lookingRight.right.midX) / 2 > barLine.midX + 5, "The eyes must look toward the pointer")
for _ in 0..<60 { bar.step(1.0 / 60, pointer: -1) }
let lookingLeft = bar.bars(line: barLine, room: 51.5)
expect((lookingLeft.left.midX + lookingLeft.right.midX) / 2 < barLine.midX - 5, "The eyes must follow the pointer across")
var flowedBack = false
for _ in 0..<Int((SignalBar.firstRound + 1) * 60) { bar.step(1.0 / 60, pointer: 0); if !bar.isEyes { flowedBack = true } }
expect(flowedBack, "The eyes must flow back into one line")

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
expect(restored.caption(for: "gpt").hasSuffix(" · Low"), "The caption must name the level without the word effort")
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
let sourceElement = AXUIElementCreateApplication(123)
let selection = SelectionSummary.Snapshot(pid: 123, element: sourceElement, range: CFRange(location: 0, length: 5), text: "hello")
let duplicate = SelectionSummary.Snapshot(pid: 123, element: sourceElement, range: CFRange(location: 0, length: 5), text: "hello")
let moved = SelectionSummary.Snapshot(pid: 123, element: sourceElement, range: CFRange(location: 9, length: 5), text: "hello")
let changed = SelectionSummary.Snapshot(pid: 123, element: sourceElement, range: CFRange(location: 0, length: 5), text: "Hallo")
expect(selection.fingerprint == duplicate.fingerprint, "Reopening the same selection has a stable duplicate identity")
expect(selection.fingerprint != moved.fingerprint, "The same words elsewhere are a new selection")
expect(selection.fingerprint != changed.fingerprint, "Changed selected text is eligible for another edit")
expect(!selection.fingerprint.contains("hello"), "Duplicate identity retains no plaintext selection")
expect(SelectionSummary.readSelection(pid: ProcessInfo.processInfo.processIdentifier) == nil, "Never capture Clip's own prompt")
print("Selected-text word counting, badge geometry and selection identity passed.")

let chatModels = try JSONDecoder().decode([DrawingModel].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
let chat = ChatPreferences(models: chatModels, defaults: preferences)
let drawBefore = choices.request(for: "gpt")
expect(chat.isAuto, "Chat defaults to Auto before the user makes a selection")
expect(chat.request(for: "gpt")["model"] == "auto" && chat.request(for: "gpt")["reasoningEffort"] == "auto", "Auto owns both model and effort")
expect(chat.request(for: "gpt")["mode"] == "chat", "Auto is chat only")
expect(choices.request(for: "gpt") == drawBefore, "Auto must not mutate Draw preferences")
chat.isAuto = false
expect(!ChatPreferences(models: chatModels, defaults: preferences).isAuto, "An explicit manual choice survives relaunch")
chat.manual.select(model: "gpt-6-astra", provider: "gpt")
chat.manual.select(effort: "ultra", provider: "gpt")
expect(chat.request(for: "gpt")["reasoningEffort"] == "ultra", "Chat supports all GPT reasoning efforts")
expect(choices.request(for: "gpt") == drawBefore, "Manual chat selections must not mutate Draw")
chat.isAuto = true
let restoredChat = ChatPreferences(models: chatModels, defaults: preferences)
expect(restoredChat.isAuto && restoredChat.manual.effort(for: "gpt") == "ultra", "Auto and manual settings persist independently")
expect(choices.request(for: "gpt") == drawBefore, "Restoring chat must not mutate Draw")
print("Chat Auto persistence and Draw isolation passed.")

assert(ComposerSignal.stripFrame.maxY <= ComposerGeometry.size.height)
assert(!ComposerSignal.stripFrame.intersects(ComposerGeometry.modelCaption))
assert(!ComposerSignal.stripFrame.intersects(ComposerGeometry.input))
for pattern in ["line", "eyes", "wave"] {
    var signal = SignalBar(); signal.pattern = pattern
    for i in 0..<900 {
        signal.step(1.0 / 30, pointer: i < 450 ? -1 : 1)
        let bars = signal.bars(line: CGRect(x: 45, y: 3.75, width: 130, height: 2.5), room: 24)
        for rect in [bars.left, bars.right] {
            assert(rect.width > 0 && rect.height > 0)
            assert(rect.minX >= 0 && rect.maxX <= 220 && rect.minY >= 0 && rect.maxY <= 10)
        }
    }
    assert(signal.isEyes == (pattern == "eyes"))
}
print("Expanded signal stays within its strip and clear of caption/input.")

// Translucency must not attenuate the actual backdrop blur, including mid-morph.
let frostedSurface = ComposerSurface(content: NSView(frame: .zero))
frostedSurface.frame = NSRect(origin: .zero, size: ComposerGeometry.size)
frostedSurface.showComposer(true)
let material = frostedSurface.subviews.compactMap { $0 as? NSVisualEffectView }.first!
assert(material.material == .hudWindow && material.blendingMode == .behindWindow)
assert(material.state == .active)
for reveal: CGFloat in [0, 0.2, 0.5, 0.8, 1] {
    frostedSurface.setMorph(reveal: reveal, radius: 28, notched: true)
    assert(material.alphaValue == 1 && frostedSurface.alphaValue == 1)
}
frostedSurface.endMorph()
assert(material.alphaValue == 1)
assert(material.subviews.first!.alphaValue == 0.8)
print("Frosted material retains full blur while tint fades independently.")

expect(composerBounds.contains(ComposerGeometry.screenshotIndicator), "Screenshot notice stays inside the composer")
for frame in ComposerGeometry.optionFrames + [ComposerGeometry.input, ComposerGeometry.selectionIndicator] {
    expect(!frame.intersects(ComposerGeometry.screenshotIndicator), "Screenshot notice does not overlap input, selection, or controls")
}
print("Screenshot notice geometry passed.")

// The dismiss control floats just below the island, centered on the camera when there is one.
let dismissUnder = DismissGeometry.frame(under: NSRect(x: 762, y: 1073, width: 209, height: 34), centeredOn: 855)
expect(dismissUnder.midX == 855, "The X must center on the camera, not the off-center resting island")
expect(dismissUnder.maxY == 1073 - DismissGeometry.gap, "The X must sit right under the island")
expect(dismissUnder.width == DismissGeometry.size && dismissUnder.height == DismissGeometry.size, "The X must stay round")
let dismissComposer = DismissGeometry.frame(under: NSRect(x: 615, y: 840, width: 480, height: 233), centeredOn: 855)
expect(dismissComposer.maxY < 840 && dismissComposer.midX == 855, "With the composer open, the X must sit under it")
let dismissFloating = DismissGeometry.frame(under: NSRect(x: 100, y: 500, width: 30, height: 22), centeredOn: nil)
expect(dismissFloating.midX == 115 && dismissFloating.maxY < 500, "Without a camera, the X must center on the pill")

let shortReplySize = ReplyCardLayout.size(text: "A short reply.", available: NSSize(width: 1440, height: 900))
let longReplySize = ReplyCardLayout.size(text: String(repeating: "A full paragraph remains readable. ", count: 200), available: NSSize(width: 1440, height: 900))
assert(shortReplySize.width >= 240 && shortReplySize.width <= 640 && shortReplySize.height >= 64)
assert(longReplySize.height > shortReplySize.height && longReplySize.height <= 342)
let narrowReplySize = ReplyCardLayout.size(text: "Readable", available: NSSize(width: 360, height: 600))
assert(narrowReplySize.width <= 312)
print("Reply cards fit short, long and narrow-screen answers without limiting text.")

// Reopening and relaunching should feel fresh without an API or context access.
var greetings = OpeningGreeting(defaults: preferences)
var seenGreetings = Set<String>()
for _ in OpeningGreeting.phrases {
    let line = greetings.next()
    expect(!line.isEmpty && line.split(whereSeparator: { $0.isWhitespace }).count <= 5, "Opening greetings must contain at most five words")
    expect(seenGreetings.insert(line).inserted, "A greeting deck must not repeat before exhaustion")
}
let lastGreeting = preferences.string(forKey: "lastOpeningGreeting")
var relaunchedGreetings = OpeningGreeting(defaults: preferences)
expect(relaunchedGreetings.next() != lastGreeting, "Relaunch must not repeat the last greeting")
expect(OpeningCaptionFrame.at(2, reducedMotion: false).greeting, "Keep the greeting readable before fading")
expect(OpeningCaptionFrame.at(3.8, reducedMotion: false).opacity < 1, "Greeting fades slowly")
expect(!OpeningCaptionFrame.at(4.6, reducedMotion: false).greeting, "Restore the selector during its fade in")
expect(OpeningCaptionFrame.at(5, reducedMotion: false).finished, "Always finish with the model selector")
expect(OpeningCaptionFrame.at(3.3, reducedMotion: true).finished && OpeningCaptionFrame.at(3.3, reducedMotion: true).opacity == 1, "Reduced motion restores the selector without fading")
print("Opening greeting variety, five-word limit and fade timing passed.")

// Voice energy only changes the compact audio shell, with its top pinned and camera covered.
for origin in [NSPoint.zero, NSPoint(x: -1900, y: 300)] {
    let screen = NSRect(origin: origin, size: NSSize(width: 1710, height: 1107))
    let left = NSRect(x: screen.minX, y: screen.maxY - 33.5, width: 762.5, height: 33.5)
    let right = NSRect(x: screen.minX + 947.5, y: left.minY, width: 762.5, height: 33.5)
    for notched in [true, false] {
        func voiceLayout(_ level: CGFloat, expanded: Bool = false, content: IslandContent = .audio) -> IslandLayout {
            IslandLayout(screen: screen, safeTop: notched ? 33.5 : 0, leftArea: notched ? left : nil,
                         rightArea: notched ? right : nil, expanded: expanded, content: content, audioLevel: level)
        }
        let quiet = voiceLayout(0), loud = voiceLayout(1)
        expect(loud.frame.maxY == quiet.frame.maxY, "Voice shell stays attached to the top")
        expect(loud.frame.width == quiet.frame.width + 20 && loud.frame.height == quiet.frame.height + 4, "Voice movement stays subtle and bounded")
        expect(loud.bounds.contains(loud.activityFrame), "Voice waveform remains inside the growing shell")
        if let notch = loud.notchFrame {
            expect(loud.frame.contains(notch), "Voice motion never uncovers the camera")
            expect(loud.activityFrame.minX + loud.frame.minX >= notch.maxX, "Voice waveform stays outside the physical camera")
        }
        expect(voiceLayout(-10).frame == quiet.frame && voiceLayout(.nan).frame == quiet.frame, "Invalid levels settle quietly")
        expect(voiceLayout(10).frame == loud.frame, "Extreme peaks cannot overgrow")
        expect(voiceLayout(0, expanded: true).frame == voiceLayout(1, expanded: true).frame, "Expanded controls stay still during voice")
        expect(voiceLayout(0, content: .idle).frame == voiceLayout(1, content: .idle).frame, "Idle signal ignores voice levels")
    }
}
print("Voice shell geometry passed: bounded energy, pinned top, camera clearance, external displays and stable composer.")

var voiceIdentity = VoiceEnergy()
for _ in 0..<30 { voiceIdentity.step(input: 0.7, output: 0, userSpeaking: true, fresh: true, dt: 1.0 / 30) }
expect(voiceIdentity.listening && voiceIdentity.input > 0.6 && voiceIdentity.output == 0, "Microphone drives the green listening signal")
for _ in 0..<30 { voiceIdentity.step(input: 0.01, output: 0.8, userSpeaking: false, fresh: true, dt: 1.0 / 30) }
expect(!voiceIdentity.listening && voiceIdentity.output > 0.7, "Playback drives the white reply waveform")
voiceIdentity.step(input: 0.5, output: 0.8, userSpeaking: true, fresh: true, dt: 1.0 / 30)
expect(voiceIdentity.listening, "User interruption takes priority over reply audio")
for _ in 0..<90 { voiceIdentity.step(input: 1, output: 1, userSpeaking: true, fresh: false, dt: 1.0 / 30) }
expect(voiceIdentity.listening && voiceIdentity.level == 0, "Stale audio cannot leave a speaking indicator stuck on")
print("Voice identity passed: input, playback, interruption and stale-level recovery.")

chat.selectGlobalAuto()
expect(chat.isGlobalAuto && chat.request(for: "gpt")["autoScope"] == "all", "Bottom Auto must cover all four models")
chat.selectProvider("gpt")
expect(chat.isAuto && !chat.isGlobalAuto && chat.request(for: "gpt")["autoScope"] == "gpt", "Codex mascot plus Auto stays inside Codex")
chat.setAuto(false, for: "gpt")
chat.selectProvider("claude")
expect(chat.isAuto && chat.request(for: "claude")["autoScope"] == "claude", "Claude initially offers scoped Auto")
chat.selectGlobalAuto(); chat.selectProvider("gpt")
expect(!chat.isAuto && chat.request(for: "gpt")["autoScope"] == nil, "Return to Codex preserves its explicit manual selection")
chat.selectProvider("claude")
let scopedRestore = ChatPreferences(models: chatModels, defaults: preferences)
expect(scopedRestore.isAuto && !scopedRestore.isGlobalAuto && scopedRestore.autoScope == "claude", "Provider scope persists across launches")
expect(choices.request(for: "gpt") == drawBefore, "Provider Auto must leave Draw unchanged")
print("Global and provider Auto scopes, manual persistence and Draw isolation passed.")

let attentionBounds = NSRect(origin: .zero, size: ComposerGeometry.size)
expect(ComposerAttention.pointer(NSPoint(x: 40, y: 170), in: attentionBounds) != nil, "Pointer tracking includes the whole bowl, not just the signal strip")
expect(ComposerAttention.pointer(NSPoint(x: 10, y: 10), in: attentionBounds) == nil, "Points outside the curved shell do not attract the signal")
expect(ComposerAttention.pointer(NSPoint(x: -30, y: 170), in: attentionBounds) == nil, "Outside-screen motion is ignored")
var follows = ComposerAttention()
for _ in 0..<90 { follows.step(1.0 / 30, pointer: NSPoint(x: -1, y: 0.6)) }
expect(follows.horizontal < -0.9 && follows.vertical > 0.5, "Follow reacts to horizontal and vertical pointer movement")
for _ in 0..<90 { follows.step(1.0 / 30, pointer: NSPoint(x: 1, y: -0.6)) }
expect(follows.horizontal > 0.9 && follows.vertical < -0.5, "Follow changes direction with the pointer")
for mode in ["wander", "drift_left", "drift_right"] {
    var a = ComposerAttention(), b = ComposerAttention(); a.mode = mode; b.mode = mode
    var minX: CGFloat = 10, maxX: CGFloat = -10
    var bodies = ["line", "eyes", "wave"].map { pattern -> SignalBar in var bar = SignalBar(); bar.pattern = pattern; return bar }
    for _ in 0..<900 {
        a.step(1.0 / 30, pointer: NSPoint(x: -1, y: -1)); b.step(1.0 / 30, pointer: NSPoint(x: 1, y: 1))
        expect(abs(a.horizontal - b.horizontal) < 0.00001 && abs(a.vertical - b.vertical) < 0.00001, "Independent behavior must ignore the actual mouse")
        minX = min(minX, a.horizontal); maxX = max(maxX, a.horizontal)
        for index in bodies.indices {
            bodies[index].step(1.0 / 30, pointer: a.horizontal, swayScale: 0.4)
            let line = CGRect(x: 45 + a.horizontal * 10, y: 3.75 + a.vertical * 0.7, width: 130, height: 2.5)
            let pair = bodies[index].bars(line: line, room: 24)
            expect(NSRect(x: 0, y: 0, width: 220, height: 10).contains(pair.left) && NSRect(x: 0, y: 0, width: 220, height: 10).contains(pair.right), "Independent motion stays within its strip")
        }
    }
    expect(maxX - minX > 1, "Independent motion must travel without pointer input")
}
var transitions = ComposerAttention()
for _ in 0..<90 { transitions.step(1.0 / 30, pointer: NSPoint(x: 1, y: 0)) }
let beforeSwitch = transitions.horizontal
transitions.mode = "wander"; transitions.step(1.0 / 30, pointer: NSPoint(x: -1, y: 0))
expect(abs(transitions.horizontal - beforeSwitch) < 0.1, "Changing attention mode must not snap the signal")
transitions.mode = "follow"; transitions.step(1.0 / 30, pointer: nil)
expect(!transitions.following, "Follow mode wanders when the mouse leaves")
print("Composer mouse attention, autonomous motion, bounds and smooth switching passed.")
for screen in [NSRect(x: 0, y: 0, width: 1710, height: 1107), NSRect(x: -1920, y: 200, width: 1920, height: 1080), NSRect(x: 0, y: 1107, width: 1280, height: 720)] {
    for point in [screen.origin, NSPoint(x: screen.maxX - 1, y: screen.maxY - 1), NSPoint(x: screen.midX, y: screen.midY)] {
        let region = PointerFocus.region(point: point, screen: screen)
        expect(screen.contains(region), "Pointer crop must stay on the pointed display")
        expect(region.width <= 760 && region.height <= 520 && region.contains(point), "Share only a bounded focus region")
        let normalized = PointerFocus.normalized(point, in: region)
        expect(normalized.allSatisfy { $0 >= 0 && $0 <= 1 }, "Pointer coordinates must fit the cropped image")
        let capture = PointerFocus.captureRect(region, desktopTop: 1107)
        expect(capture.maxY == 1107 - region.minY, "Cocoa capture coordinates must invert around primary display top")
    }
}
let pointerRegion = NSRect(x: 0, y: 0, width: 120, height: 100)
let pointerFixture = NSImage(size: pointerRegion.size, flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
let marked = VoicePointerShare.annotated(pointerFixture, region: pointerRegion, samples: [PointerSample(point: NSPoint(x: 40, y: 40), time: 1), PointerSample(point: NSPoint(x: 60, y: 60), time: 2)], now: 2)!
let markedBytes = Data(base64Encoded: String(marked.split(separator: ",")[1]))!
let markedBitmap = NSBitmapImageRep(data: markedBytes)!
expect(markedBitmap.pixelsWide == 120 && markedBitmap.pixelsHigh == 100, "Annotation must preserve crop size")
let red = markedBitmap.colorAt(x: 60, y: 35)!.usingColorSpace(.deviceRGB)!
expect(red.redComponent > red.greenComponent + 0.2, "Shared screenshot must include the red pointer annotation")
print("Pointer crop coordinates, display edges and visible annotation passed.")

let spokenText = String(repeating: "Hello Diego. 🌿 你好.\n", count: 300)
let speechParts = ReplyVoice.chunks(spokenText)
expect(speechParts.joined() == spokenText, "Speech preserves the exact displayed text across chunks")
expect(speechParts.allSatisfy { $0.utf16.count <= 1200 }, "Speech requests bound Unicode text")
expect(ReplyVoice.chunks("").isEmpty, "Empty text creates no speech request")
preferences.set("missing", forKey: "replyVoice")
expect(ReplyVoice.selected(preferences) == "marin", "Unknown saved voice falls back to Marin")
preferences.set("cedar", forKey: "replyVoice")
expect(ReplyVoice.selected(preferences) == "cedar", "Reply voice preference persists")
print("Reply speech text identity, Unicode chunk limits and voice preferences passed.")

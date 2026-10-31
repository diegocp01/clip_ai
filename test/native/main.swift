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
let controls = [ComposerGeometry.input, ComposerGeometry.send, ComposerGeometry.collapse,
                ComposerGeometry.screen, ComposerGeometry.talk, ComposerGeometry.voice,
                ComposerGeometry.tier, ComposerGeometry.more, ComposerGeometry.provider]
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
print("Composer bounds, clean camera boundary, continuous morph and reversal checks passed.")

// Hover sectors belong to one option and never cover the typing controls.
for (index, frame) in ComposerGeometry.optionFrames.enumerated() {
    expect(ComposerGeometry.option(at: NSPoint(x: frame.midX, y: frame.midY)) == index,
           "Each circular option must highlight its own wedge")
}
for frame in [ComposerGeometry.input, ComposerGeometry.send, ComposerGeometry.collapse] {
    for point in [NSPoint(x: frame.minX, y: frame.minY), NSPoint(x: frame.midX, y: frame.midY),
                  NSPoint(x: frame.maxX - 0.1, y: frame.maxY - 0.1)] {
        expect(ComposerGeometry.option(at: point) == nil, "Typing and Send must not highlight an option")
    }
}
for point in [NSPoint(x: -1, y: 100), NSPoint(x: 480, y: 0), NSPoint(x: 240, y: -1)] {
    expect(ComposerGeometry.option(at: point) == nil, "Leaving the shell clears the option")
}
print("Composer hover sectors and central input exclusion passed.")

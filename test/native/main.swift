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
            expect(bridge.maxY == screen.maxY && bridge.minY < layout.frame.maxY, "Bridge must overlap expanded body")
            expect(bridge.minY >= layout.frame.minY, "Bridge must end inside the body")
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

// The blob reaches the tip and stays out of the way when there is nothing to draw.
for tip in [CGPoint(x: 200, y: 150), CGPoint(x: 400, y: 220), CGPoint(x: 390, y: 170), CGPoint(x: 60, y: 210)] {
    let box = GooShape.blob(outline: island, tip: tip)!.boundingBoxOfPath
    expect(box.insetBy(dx: -1, dy: -1).contains(tip), "Blob must reach its tip")
    expect(box.intersects(island.rect), "Blob must stay joined to the island")
}
// Clicks count on the blob and just around it, never on the island itself or further away.
let tip = CGPoint(x: 200, y: 150)
expect(GooShape.touches(outline: island, tip: tip, point: CGPoint(x: 200, y: 160)), "A point inside the blob must count")
expect(GooShape.touches(outline: island, tip: tip, point: CGPoint(x: 200, y: 142)), "A point just past the tip must count")
expect(!GooShape.touches(outline: island, tip: tip, point: CGPoint(x: 200, y: 100)), "A point far past the tip must not count")
expect(!GooShape.touches(outline: island, tip: tip, point: CGPoint(x: 300, y: 160)), "A point beside the blob must not count")
expect(!GooShape.touches(outline: island, tip: tip, point: CGPoint(x: 200, y: 220)), "The island handles its own clicks")
expect(!GooShape.touches(outline: island, tip: CGPoint(x: 200, y: 220), point: CGPoint(x: 200, y: 180)), "No blob must mean no click")
expect(GooShape.blob(outline: island, tip: CGPoint(x: 200, y: 220)) == nil, "A tip inside the island must draw nothing")
expect(GooShape.blob(outline: island, tip: CGPoint(x: 200, y: 199.5)) == nil, "A tip on the edge must draw nothing")
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
for width: CGFloat in [0, 30, 185, 273, 1000] {
    let target = NSRect(x: -500, y: 200, width: 440, height: 176)
    let start = ComposerGeometry.originFrame(for: target, compactWidth: width)
    expect(start.maxY == target.maxY && start.midX == target.midX, "Composer must grow down from its top-center anchor")
    expect(start.height == 1 && start.width <= target.width, "Opening must begin as a narrow menu-bar edge")
}
print("Composer bounds, separation, and top-anchored motion checks passed.")

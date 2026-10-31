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
            expect(hovered.frame.width == 185 + 88 && hovered.frame.midX == screen.midX, "Hover must grow the island evenly on both sides")
            expect(onScreen(hovered.wakeArea, hovered) == hovered.frame, "The whole awake island must keep it awake")
            expect(hovered.frame.maxY == screen.maxY && hovered.frame.minY < left.minY, "Awake island must stay on the screen edge and hang below the camera")
            let sensing = onScreen(hovered.lineFrame, hovered)
            expect(sensing.maxY <= left.minY && hovered.frame.contains(sensing), "Awake line must sit below the camera, where there are pixels")
            expect(sensing.width > hovered.frame.width / 2 && sensing.midX == hovered.frame.midX, "Awake line must span the island evenly")
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

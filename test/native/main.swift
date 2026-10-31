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
        expect(layout.frame.midX == screen.midX, "Island must follow display coordinates")
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
            let dot = layout.frame.width
            expect(dot == 185 + 48, "Resting island must be only slightly wider than the camera")
            expect(right.contains(onScreen(layout.dotFrame, layout)) && layout.frame.contains(onScreen(layout.dotFrame, layout)), "Dot must be visible entirely right of the physical camera")
            let audio = IslandLayout(screen: screen, safeTop: 33.5, leftArea: left, rightArea: right, expanded: false, content: .audio)
            expect(audio.frame.width > dot, "Audio must grow the island")
            expect(audio.frame.midX == screen.midX, "Audio island must stay centered on the camera")
            expect(right.contains(onScreen(audio.activityFrame, audio)) && audio.frame.contains(onScreen(audio.activityFrame, audio)), "Activity indicator must be visible entirely right of the physical camera")
            for textWidth: CGFloat in [40, 600] {
                let status = IslandLayout(screen: screen, safeTop: 33.5, leftArea: left, rightArea: right, expanded: false, content: .status(textWidth: textWidth))
                expect(status.frame.width <= 185 + 260, "Long status text must truncate instead of covering the menu bar")
                expect(left.contains(onScreen(status.statusFrame, status)) && status.frame.contains(onScreen(status.statusFrame, status)), "Status text must be visible entirely left of the physical camera")
                expect(right.contains(onScreen(status.dotFrame, status)), "Status dot must be right of the physical camera")
            }
        }
    }
}
let external = NSRect(x: 1710, y: -400, width: 2560, height: 1440)
for expanded in [false, true] {
    let layout = IslandLayout(screen: external, safeTop: 0, leftArea: nil, rightArea: nil, expanded: expanded)
    expect(layout.notchBridge == nil, "External/non-notched screens must retain a floating pill")
    expect(layout.frame.maxY == external.maxY - 4, "Floating pill keeps its top inset")
    expect(layout.frame.width == (expanded ? 400 : 30), "Floating pill rests at dot size")
    expect(layout.bounds.contains(layout.dotFrame), "Dot must remain inside the pill")
    expect(layout.frame.midX == external.midX, "External display origin must be respected")
}
let unknown = IslandLayout(screen: external, safeTop: 30, leftArea: nil, rightArea: nil, expanded: false)
expect(unknown.notchBridge == nil && unknown.frame.maxY == external.maxY - 30, "Missing notch bounds must fall back below the safe area")
let audioPill = IslandLayout(screen: external, safeTop: 0, leftArea: nil, rightArea: nil, expanded: false, content: .audio)
expect(audioPill.frame.width == 40 && audioPill.bounds.contains(audioPill.activityFrame), "Floating pill must fit the waveform")
let statusPill = IslandLayout(screen: external, safeTop: 0, leftArea: nil, rightArea: nil, expanded: false, content: .status(textWidth: 600))
expect(statusPill.frame.width == 278 && statusPill.bounds.contains(statusPill.statusFrame), "Floating pill must cap and fit status text")
print("Native island layout checks passed (notched, shifted, external, and missing bounds).")

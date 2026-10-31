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
        let bridge = layout.notchBridge!
        expect(layout.frame.maxY == left.minY, "Controls must stay below the camera area")
        expect(layout.frame.midX == screen.midX, "Island must follow display coordinates")
        expect(layout.frame.width == (expanded ? 400 : 209), "Collapsed width must fit the notch")
        expect(bridge.minX == left.maxX && bridge.maxX == right.minX, "Bridge must not cover menu items beside the notch")
        expect(bridge.maxY == screen.maxY && bridge.minY < layout.frame.maxY, "Bridge must join the top edge and body without a seam")
        expect(bridge.minY >= layout.frame.minY, "Bridge must end inside the body")
    }
}
let external = NSRect(x: 1710, y: -400, width: 2560, height: 1440)
for expanded in [false, true] {
    let layout = IslandLayout(screen: external, safeTop: 0, leftArea: nil, rightArea: nil, expanded: expanded)
    expect(layout.notchBridge == nil, "External/non-notched screens must retain a floating pill")
    expect(layout.frame.maxY == external.maxY - 4, "Floating pill keeps its top inset")
    expect(layout.frame.width == (expanded ? 400 : 192), "Floating pill keeps its original width")
    expect(layout.frame.midX == external.midX, "External display origin must be respected")
}
let unknown = IslandLayout(screen: external, safeTop: 30, leftArea: nil, rightArea: nil, expanded: false)
expect(unknown.notchBridge == nil && unknown.frame.maxY == external.maxY - 30, "Missing notch bounds must fall back below the safe area")
print("Native island layout checks passed (notched, shifted, external, and missing bounds).")

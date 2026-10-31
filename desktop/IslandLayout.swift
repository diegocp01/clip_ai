import AppKit

/// Screen coordinates are in points and may have a nonzero (or negative) origin.
struct IslandLayout {
    let frame: NSRect
    let notchBridge: NSRect?
    let cornerRadius: CGFloat
    let isNotched: Bool
    let statusFrame: NSRect
    let activityFrame: NSRect

    init(screen: NSRect, safeTop: CGFloat, leftArea: NSRect?, rightArea: NSRect?, expanded: Bool) {
        let notch: NSRect?
        if safeTop > 0, let left = leftArea, let right = rightArea,
           left.width > 0, right.width > 0, right.minX > left.maxX,
           left.maxX >= screen.minX, right.minX <= screen.maxX {
            notch = NSRect(x: left.maxX, y: screen.maxY - safeTop,
                           width: right.minX - left.maxX, height: safeTop)
        } else {
            notch = nil
        }
        isNotched = notch != nil
        // The camera is physical, not drawable screen space. Keep the compact
        // content in two wings beside it, at menu-bar height, with nothing below.
        if let notch, !expanded {
            let wing: CGFloat = 72
            frame = NSRect(x: notch.minX - wing, y: notch.minY,
                           width: notch.width + wing * 2, height: notch.height)
            cornerRadius = 10
            notchBridge = nil
            statusFrame = NSRect(x: 12, y: (notch.height - 18) / 2, width: wing - 20, height: 18)
            activityFrame = NSRect(x: wing + notch.width + (wing - 24) / 2,
                                   y: (notch.height - 20) / 2, width: 24, height: 20)
            return
        }
        cornerRadius = expanded ? 18 : 14
        let width: CGFloat = expanded ? 400 : max(192, (notch?.width ?? 0) + 24)
        let height: CGFloat = expanded ? 144 : 28
        let center = notch?.midX ?? screen.midX
        let top = screen.maxY - max(safeTop, notch == nil ? 4 : 0)
        frame = NSRect(x: center - width / 2, y: top - height, width: width, height: height)
        statusFrame = expanded ? NSRect(x: 46, y: 110, width: 294, height: 20)
                               : NSRect(x: 14, y: 5, width: width - 54, height: 18)
        activityFrame = expanded ? NSRect(x: 16, y: 110, width: 24, height: 20)
                                 : NSRect(x: width - 34, y: 4, width: 24, height: 20)
        // A separate, always click-through panel connects the body to the camera
        // housing. No transparent window wings cover the adjacent menu items.
        if let notch {
            notchBridge = NSRect(x: notch.minX, y: top - cornerRadius, width: notch.width,
                                 height: notch.height + cornerRadius)
        } else {
            notchBridge = nil
        }
    }
}

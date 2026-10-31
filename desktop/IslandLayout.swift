import AppKit

/// Screen coordinates are in points and may have a nonzero (or negative) origin.
struct IslandLayout {
    let frame: NSRect
    let notchBridge: NSRect?
    let cornerRadius: CGFloat

    init(screen: NSRect, safeTop: CGFloat, leftArea: NSRect?, rightArea: NSRect?, expanded: Bool) {
        cornerRadius = expanded ? 18 : 14
        let notch: NSRect?
        if safeTop > 0, let left = leftArea, let right = rightArea,
           left.width > 0, right.width > 0, right.minX > left.maxX,
           left.maxX >= screen.minX, right.minX <= screen.maxX {
            notch = NSRect(x: left.maxX, y: screen.maxY - safeTop,
                           width: right.minX - left.maxX, height: safeTop)
        } else {
            notch = nil
        }
        let width: CGFloat = expanded ? 400 : max(192, (notch?.width ?? 0) + 24)
        let height: CGFloat = expanded ? 144 : 28
        let center = notch?.midX ?? screen.midX
        let top = screen.maxY - max(safeTop, notch == nil ? 4 : 0)
        frame = NSRect(x: center - width / 2, y: top - height, width: width, height: height)
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

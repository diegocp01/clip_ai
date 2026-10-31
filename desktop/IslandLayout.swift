import AppKit

/// What the collapsed island shows, which decides how much room it takes.
enum IslandContent: Equatable {
    case dot
    case audio
    case status(textWidth: CGFloat)
}

/// Screen coordinates are in points and may have a nonzero (or negative) origin.
struct IslandLayout {
    let frame: NSRect
    let notchBridge: NSRect?
    let cornerRadius: CGFloat
    let isNotched: Bool
    let statusFrame: NSRect
    let activityFrame: NSRect
    let dotFrame: NSRect
    /// The part of the island that reacts to the pointer while it rests as a dot.
    let dotArea: NSRect
    var bounds: NSRect { NSRect(origin: .zero, size: frame.size) }

    init(screen: NSRect, safeTop: CGFloat, leftArea: NSRect?, rightArea: NSRect?, expanded: Bool, content: IslandContent = .dot, hovered: Bool = false) {
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
        // Text goes left of the camera; the dot and waveform go right of it, so
        // nothing extends left of the camera unless there is text to show.
        let dotSize: CGFloat = hovered && content == .dot ? 12 : 8
        if let notch, !expanded {
            let leftWing: CGFloat, rightWing: CGFloat
            switch content {
            case .dot: leftWing = 0; rightWing = hovered ? 44 : 24
            case .audio: leftWing = 0; rightWing = 36
            case .status(let textWidth): leftWing = min(textWidth + 20, 130); rightWing = 24
            }
            frame = NSRect(x: notch.minX - leftWing, y: notch.minY,
                           width: notch.width + leftWing + rightWing, height: notch.height)
            cornerRadius = 10
            notchBridge = nil
            statusFrame = NSRect(x: 12, y: (notch.height - 18) / 2, width: max(leftWing - 20, 0), height: 18)
            activityFrame = NSRect(x: leftWing + notch.width + (rightWing - 24) / 2,
                                   y: (notch.height - 20) / 2, width: 24, height: 20)
            dotFrame = NSRect(x: leftWing + notch.width + (rightWing - dotSize) / 2,
                              y: (notch.height - dotSize) / 2, width: dotSize, height: dotSize)
            dotArea = NSRect(x: leftWing + notch.width, y: 0, width: rightWing, height: notch.height)
            return
        }
        cornerRadius = expanded ? 18 : 11
        let textWidth: CGFloat
        let compactWidth: CGFloat
        switch content {
        case .dot: textWidth = 0; compactWidth = hovered ? 42 : 30
        case .audio: textWidth = 0; compactWidth = 40
        case .status(let width): textWidth = min(width, 240); compactWidth = 38 + textWidth
        }
        let width: CGFloat = expanded ? 400 : compactWidth
        let height: CGFloat = expanded ? 144 : 22
        let center = notch?.midX ?? screen.midX
        let top = screen.maxY - max(safeTop, notch == nil ? 4 : 0)
        frame = NSRect(x: center - width / 2, y: top - height, width: width, height: height)
        statusFrame = expanded ? NSRect(x: 46, y: 110, width: 294, height: 20)
                               : NSRect(x: 26, y: 2, width: textWidth, height: 18)
        activityFrame = expanded ? NSRect(x: 16, y: 110, width: 24, height: 20)
                                 : NSRect(x: 8, y: 1, width: 24, height: 20)
        dotFrame = expanded ? NSRect(x: 24, y: 116, width: 8, height: 8)
                            : NSRect(x: content == .dot ? (width - dotSize) / 2 : 12, y: (height - dotSize) / 2, width: dotSize, height: dotSize)
        dotArea = NSRect(x: 0, y: 0, width: width, height: height)
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

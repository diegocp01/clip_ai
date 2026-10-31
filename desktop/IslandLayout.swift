import AppKit

/// What the collapsed island shows, which decides how much room it takes.
enum IslandContent: Equatable {
    case idle
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
    /// The signal line: upright at rest, lying along the bottom edge once awake.
    let lineFrame: NSRect
    /// The part of the idle island that reacts to the pointer.
    let wakeArea: NSRect
    var bounds: NSRect { NSRect(origin: .zero, size: frame.size) }

    init(screen: NSRect, safeTop: CGFloat, leftArea: NSRect?, rightArea: NSRect?, expanded: Bool, content: IslandContent = .idle, hovered: Bool = false) {
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
        // Text goes left of the camera; the line and waveform go right of it, so
        // nothing extends left of the camera unless there is text to show.
        let awake = hovered && content == .idle
        if let notch, !expanded {
            let leftWing: CGFloat, rightWing: CGFloat
            switch content {
            case .idle: leftWing = hovered ? 44 : 0; rightWing = hovered ? 44 : 24
            case .audio: leftWing = 0; rightWing = 36
            case .status(let textWidth): leftWing = min(textWidth + 20, 130); rightWing = 24
            }
            // Only while awake does it hang below the camera, which is what makes
            // room for a line along its bottom edge: the camera itself has no pixels.
            let drop: CGFloat = awake ? 10 : 0
            frame = NSRect(x: notch.minX - leftWing, y: notch.minY - drop,
                           width: notch.width + leftWing + rightWing, height: notch.height + drop)
            cornerRadius = awake ? 14 : 10
            notchBridge = nil
            statusFrame = NSRect(x: 12, y: (notch.height - 18) / 2, width: max(leftWing - 20, 0), height: 18)
            activityFrame = NSRect(x: leftWing + notch.width + (rightWing - 24) / 2,
                                   y: (notch.height - 20) / 2, width: 24, height: 20)
            lineFrame = awake ? NSRect(x: leftWing + (notch.width - 130) / 2, y: 4, width: 130, height: 2)
                              : NSRect(x: leftWing + notch.width + (rightWing - 3) / 2,
                                       y: (notch.height - 14) / 2, width: 3, height: 14)
            // At rest only the line's side reacts. Once awake, the whole island keeps it awake.
            wakeArea = awake ? NSRect(origin: .zero, size: frame.size)
                             : NSRect(x: leftWing + notch.width, y: 0, width: rightWing, height: notch.height)
            return
        }
        cornerRadius = expanded ? 18 : 11
        let textWidth: CGFloat
        let compactWidth: CGFloat
        switch content {
        case .idle: textWidth = 0; compactWidth = hovered ? 64 : 30
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
        if expanded { lineFrame = NSRect(x: 26.5, y: 113, width: 3, height: 14) }
        else if awake { lineFrame = NSRect(x: 10, y: 3, width: width - 20, height: 2) }
        else { lineFrame = NSRect(x: content == .idle ? (width - 3) / 2 : 12, y: (height - 14) / 2, width: 3, height: 14) }
        wakeArea = NSRect(x: 0, y: 0, width: width, height: height)
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

import AppKit

/// Expanded-only metrics. The compact signal/hover geometry is independent.
enum ComposerGeometry {
    static let size = NSSize(width: 480, height: 238)
    static let cornerRadius: CGFloat = 28
    static let prompt = NSRect(x: 90, y: 112, width: 300, height: 68)
    static let input = NSRect(x: 106, y: 135, width: 226, height: 22)
    static let send = NSRect(x: 342, y: 128, width: 36, height: 36)
    static let collapse = NSRect(x: 420, y: 194, width: 28, height: 28)
    static let screen = NSRect(x: 52, y: 88, width: 36, height: 36)
    static let talk = NSRect(x: 110, y: 40, width: 36, height: 36)
    static let voice = NSRect(x: 182, y: 16, width: 36, height: 36)
    static let tier = NSRect(x: 334, y: 40, width: 36, height: 36)
    static let provider = NSRect(x: 262, y: 16, width: 36, height: 36)
    static let more = NSRect(x: 392, y: 88, width: 36, height: 36)

    /// A shallow bowl with flat shoulders at the camera edge. Coordinates scale
    /// with the window during the existing compact-to-expanded morph.
    static func shellPath(in rect: NSRect) -> NSBezierPath {
        let w = rect.width, h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        let path = NSBezierPath()
        path.move(to: point(0.035, 1))
        path.line(to: point(0.965, 1))
        path.curve(to: point(1, 0.93), controlPoint1: point(0.99, 1), controlPoint2: point(1, 0.98))
        path.curve(to: point(0.5, 0), controlPoint1: point(1, 0.34), controlPoint2: point(0.80, 0))
        path.curve(to: point(0, 0.93), controlPoint1: point(0.20, 0), controlPoint2: point(0, 0.34))
        path.curve(to: point(0.035, 1), controlPoint1: point(0, 0.98), controlPoint2: point(0.01, 1))
        path.close()
        return path
    }

    /// Keep the real compact frame as the source: never flatten the material
    /// into a one-pixel strip or jump it below the camera before opening.
    static func morphFrame(from source: NSRect, to target: NSRect, progress: CGFloat) -> NSRect {
        let p = min(max(progress, 0), 1)
        let t = p * p * (3 - 2 * p)
        return NSRect(x: source.minX + (target.minX - source.minX) * t,
                      y: source.minY + (target.minY - source.minY) * t,
                      width: source.width + (target.width - source.width) * t,
                      height: source.height + (target.height - source.height) * t)
    }
}

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
    let notchFrame: NSRect?
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
        notchFrame = notch
        // The camera is physical, not drawable screen space. Keep the compact
        // content in two wings beside it, at menu-bar height, with nothing below.
        // Text goes left of the camera; the line and waveform go right of it, so
        // nothing extends left of the camera unless there is text to show.
        let awake = hovered && content == .idle
        if let notch, !expanded {
            let leftWing: CGFloat, rightWing: CGFloat
            switch content {
            case .idle: leftWing = hovered ? 24 : 0; rightWing = 24
            case .audio: leftWing = 0; rightWing = 36
            case .status(let textWidth): leftWing = min(textWidth + 20, 130); rightWing = 24
            }
            // Only while awake does it hang below the camera, which is what makes
            // room for a line along its bottom edge: the camera itself has no pixels.
            let drop: CGFloat = awake ? 10 : 0
            frame = NSRect(x: notch.minX - leftWing, y: notch.minY - drop,
                           width: notch.width + leftWing + rightWing, height: notch.height + drop)
            cornerRadius = awake ? 18 : 10
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
        cornerRadius = expanded ? ComposerGeometry.cornerRadius : 11
        let textWidth: CGFloat
        let compactWidth: CGFloat
        switch content {
        case .idle: textWidth = 0; compactWidth = hovered ? 64 : 30
        case .audio: textWidth = 0; compactWidth = 40
        case .status(let width): textWidth = min(width, 240); compactWidth = 38 + textWidth
        }
        let width: CGFloat = expanded ? ComposerGeometry.size.width : compactWidth
        let height: CGFloat = expanded ? ComposerGeometry.size.height : 22
        let center = notch?.midX ?? screen.midX
        let top = screen.maxY - max(safeTop, notch == nil ? 4 : 0)
        frame = NSRect(x: center - width / 2, y: top - height, width: width, height: height)
        statusFrame = expanded ? NSRect(x: 210, y: 199, width: 195, height: 20)
                               : NSRect(x: 26, y: 2, width: textWidth, height: 18)
        activityFrame = expanded ? NSRect(x: 180, y: 199, width: 24, height: 20)
                                 : NSRect(x: 8, y: 1, width: 24, height: 20)
        if expanded { lineFrame = NSRect(x: 193, y: 202, width: 3, height: 14) }
        else if awake { lineFrame = NSRect(x: 10, y: 3, width: width - 20, height: 2) }
        else { lineFrame = NSRect(x: content == .idle ? (width - 3) / 2 : 12, y: (height - 14) / 2, width: 3, height: 14) }
        wakeArea = NSRect(x: 0, y: 0, width: width, height: height)
        // Cover only the physical camera area. Extending this black rectangle
        // into a translucent composer leaves a visible dark block inside the glass.
        if let notch {
            notchBridge = notch
        } else {
            notchBridge = nil
        }
    }
}

import AppKit

struct HabitHistoryDay {
    let date: Date
    /// nil means the date predates tracking; today is always provisional.
    let result: Int?
    let isToday: Bool
    var description: String {
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        guard let result else { return "\(day) · not tracked" }
        if isToday { return "\(day) · today, not final" }
        return "\(day) · \(result == 1 ? "1 — all seven" : "0 — fewer than seven")"
    }
}

/// A small native chart: no web view, dependency, polling, or animation timer.
final class HabitHistoryChart: NSView {
    var days = [HabitHistoryDay]() { didSet {
        needsDisplay = true
        setAccessibilityLabel("Daily habit history. One means all seven; zero means fewer than seven. " + days.map(\.description).joined(separator: ". "))
    } }
    var onHover: ((String?) -> Void)?
    private var hoverIndex: Int? { didSet { if oldValue != hoverIndex { needsDisplay = true } } }
    private let mint = NSColor(calibratedRed: 0.48, green: 0.95, blue: 0.66, alpha: 1)
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var plot: NSRect { bounds.insetBy(dx: 22, dy: 21) }
    private func point(_ index: Int, _ value: Int) -> NSPoint {
        NSPoint(x: plot.minX + CGFloat(index) / CGFloat(max(1, days.count - 1)) * plot.width,
                y: plot.minY + CGFloat(value) * plot.height)
    }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        guard !days.isEmpty else { return }
        let location = convert(event.locationInWindow, from: nil)
        let index = min(days.count - 1, max(0, Int(((location.x - plot.minX) / plot.width * CGFloat(days.count - 1)).rounded())))
        hoverIndex = index; toolTip = days[index].description; onHover?(days[index].description)
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; onHover?(nil) }
    private func label(_ text: String, at point: NSPoint, color: NSColor = .secondaryLabelColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: color])
    }
    override func draw(_ dirtyRect: NSRect) {
        for value in [0, 1] {
            let y = point(0, value).y
            let rule = NSBezierPath(); rule.move(to: NSPoint(x: plot.minX, y: y)); rule.line(to: NSPoint(x: plot.maxX, y: y))
            NSColor.white.withAlphaComponent(0.1).setStroke(); rule.lineWidth = 0.5; rule.stroke()
            label(String(value), at: NSPoint(x: 3, y: y - 5))
        }
        for index in days.indices {
            guard let value = days[index].result else { continue }
            let p = point(index, value)
            if index > 0, let previous = days[index - 1].result {
                let line = NSBezierPath(); line.move(to: point(index - 1, previous)); line.line(to: p)
                line.lineWidth = 1.5
                if days[index].isToday { line.setLineDash([2, 3], count: 2, phase: 0) }
                mint.withAlphaComponent(days[index].isToday ? 0.35 : 0.8).setStroke(); line.stroke()
            }
            let r: CGFloat = days[index].isToday || hoverIndex == index ? 3.4 : days.count > 7 ? 2.1 : 2.8
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            mint.withAlphaComponent(value == 1 ? 1 : 0.5).setStroke()
            if !days[index].isToday { mint.withAlphaComponent(value == 1 ? 1 : 0.5).setFill(); dot.fill() }
            dot.lineWidth = 1.3; dot.stroke()
        }
        if let first = days.first, let last = days.last {
            label(first.date.formatted(.dateTime.month(.abbreviated).day()), at: NSPoint(x: plot.minX, y: 2))
            let text = last.date.formatted(.dateTime.month(.abbreviated).day())
            label(text, at: NSPoint(x: plot.maxX - 35, y: 2))
        }
    }
}

import AppKit

/// Stable IDs keep saved progress independent of display labels.
struct ClipHabit {
    let id: String
    let title: String
    static let all: [ClipHabit] = [
        .init(id: "meditate", title: "Meditate"), .init(id: "exercise", title: "Exercise"),
        .init(id: "stretch", title: "Stretch"), .init(id: "read", title: "Read"),
        .init(id: "journal", title: "Journal"), .init(id: "math", title: "Math"),
        .init(id: "push-ups", title: "Push ups")
    ]
}

final class HabitStore {
    private let defaults: UserDefaults
    private let key = "clip.habits.days.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func dayKey(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    func completed(on date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Set<String> {
        let days = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set(days[Self.dayKey(date, calendar: calendar)] ?? []).intersection(ClipHabit.all.map(\.id))
    }
    func toggle(_ id: String, on date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        guard ClipHabit.all.contains(where: { $0.id == id }) else { return }
        var days = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        let day = Self.dayKey(date, calendar: calendar)
        var done = completed(on: date, calendar: calendar)
        if done.contains(id) { done.remove(id) } else { done.insert(id) }
        days[day] = done.sorted()
        // Bounded local history; no database or worker process.
        for old in days.keys.sorted().dropLast(90) { days.removeValue(forKey: old) }
        defaults.set(days, forKey: key)
    }
}

enum HabitTrackerLayout {
    static let size = NSSize(width: 104, height: 104)
    static func frame(beside composer: NSRect, visible: NSRect) -> NSRect {
        // Use the expanded footprint in both states, so opening Clip never pushes the ring away.
        let x = max(visible.minX + 8, composer.minX - size.width - 12)
        var top = min(visible.maxY - 8, composer.maxY - 8)
        // Very narrow displays cannot fit it beside the composer: keep both usable.
        if x + size.width > composer.minX - 4 { top = min(top, composer.minY - 12) }
        return NSRect(x: x, y: max(visible.minY + 8, top - size.height), width: size.width, height: size.height)
    }
}

private final class HabitPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
enum HabitRingGeometry {
    static let radius: CGFloat = 38
    static func angle(_ index: Int) -> CGFloat { 90 - CGFloat(index) * 360 / 7 }
    static func center(_ index: Int) -> NSPoint {
        let radians = angle(index) * .pi / 180
        return NSPoint(x: 52 + cos(radians) * radius, y: 52 + sin(radians) * radius)
    }
    static func index(at point: NSPoint) -> Int? {
        let dx = point.x - 52, dy = point.y - 52
        guard (27...51).contains(hypot(dx, dy)) else { return nil }
        let clockwise = (90 - atan2(dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return Int((clockwise + 180 / 7).truncatingRemainder(dividingBy: 360) / (360 / 7))
    }
}

private final class HabitButton: NSButton {
    var onHover: ((Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self {
            NSColor.white.withAlphaComponent(0.65).setStroke()
            let focus = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)); focus.lineWidth = 1; focus.stroke()
        }
    }
}

private final class HabitRing: NSView {
    var done = Set<String>() { didSet { needsDisplay = true } }
    var hovered: Int? { didSet { needsDisplay = true } }
    var onToggle: ((Int) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if let index = HabitRingGeometry.index(at: convert(event.locationInWindow, from: nil)) { onToggle?(index) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let mint = NSColor(calibratedRed: 0.47, green: 0.91, blue: 0.65, alpha: 1)
        for (index, habit) in ClipHabit.all.enumerated() {
            let complete = done.contains(habit.id)
            (complete ? mint : NSColor.white.withAlphaComponent(hovered == index ? 0.5 : 0.18)).setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 52, y: 52), radius: HabitRingGeometry.radius,
                          startAngle: HabitRingGeometry.angle(index) + 15.5,
                          endAngle: HabitRingGeometry.angle(index) - 15.5, clockwise: true)
            arc.lineWidth = hovered == index ? 13 : 11
            arc.lineCapStyle = .round; arc.stroke()
            if complete {
                // A tiny check distinguishes completion even without color.
                let c = HabitRingGeometry.center(index)
                NSColor.black.withAlphaComponent(0.65).setStroke()
                let check = NSBezierPath(); check.move(to: NSPoint(x: c.x - 3, y: c.y))
                check.line(to: NSPoint(x: c.x - 1, y: c.y - 2)); check.line(to: NSPoint(x: c.x + 3, y: c.y + 2))
                check.lineWidth = 1.2; check.lineCapStyle = .round; check.stroke()
            }
        }
    }
}

final class HabitTracker: NSObject {
    private let store: HabitStore
    private let window: HabitPanel
    private let counter = NSTextField(labelWithString: "0/7")
    private var buttons = [NSButton]()
    private let ring = HabitRing(frame: NSRect(origin: .zero, size: HabitTrackerLayout.size))
    private var midnightTimer: Timer?
    private var observers = [NSObjectProtocol]()
    private var wakeObserver: NSObjectProtocol?
    var isVisible: Bool { window.isVisible }
    func owns(_ candidate: NSWindow) -> Bool { candidate === window }
    override convenience init() { self.init(store: HabitStore()) }
    init(store: HabitStore) {
        self.store = store
        window = HabitPanel(contentRect: NSRect(origin: .zero, size: HabitTrackerLayout.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "Clip habits"
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: HabitTrackerLayout.size))
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true; glass.layer?.cornerRadius = 52; glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5; glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        window.contentView = glass
        glass.addSubview(ring)
        ring.onToggle = { [weak self] index in self?.toggle(index) }
        let title = NSTextField(labelWithString: "today")
        title.font = .systemFont(ofSize: 8, weight: .regular)
        title.textColor = NSColor.white.withAlphaComponent(0.45); title.alignment = .center
        title.frame = NSRect(x: 28, y: 33, width: 48, height: 12); ring.addSubview(title)
        counter.font = .monospacedDigitSystemFont(ofSize: 15, weight: .light)
        counter.textColor = NSColor.white.withAlphaComponent(0.9)
        counter.alignment = .center; counter.frame = NSRect(x: 27, y: 46, width: 50, height: 21)
        ring.addSubview(counter)
        for (index, _) in ClipHabit.all.enumerated() {
            let c = HabitRingGeometry.center(index)
            let button = HabitButton(frame: NSRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24))
            button.tag = index; button.title = ""; button.isBordered = false
            button.setButtonType(.toggle); button.target = self; button.action = #selector(toggleHabit(_:))
            button.onHover = { [weak self] inside in self?.ring.hovered = inside ? index : nil }
            ring.addSubview(button); buttons.append(button)
        }
        for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    @objc private func toggleHabit(_ sender: NSButton) {
        toggle(sender.tag)
    }
    private func toggle(_ index: Int) {
        store.toggle(ClipHabit.all[index].id)
        refresh()
    }
    private func refresh() {
        let done = store.completed()
        ring.done = done
        counter.stringValue = "\(done.count)/7"
        counter.setAccessibilityLabel("\(done.count) of 7 habits completed today")
        for (button, habit) in zip(buttons, ClipHabit.all) {
            let checked = done.contains(habit.id)
            button.state = checked ? .on : .off
            button.setAccessibilityLabel("\(habit.title), \(checked ? "completed" : "not completed") today")
            button.toolTip = checked ? "Undo \(habit.title.lowercased())" : "Complete \(habit.title.lowercased())"
        }
        midnightTimer?.invalidate()
        if let next = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: Date())?.end {
            let timer = Timer(fire: next.addingTimeInterval(0.1), interval: 0, repeats: false) { [weak self] _ in self?.refresh() }
            midnightTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    func show(beside composer: NSRect, visible: NSRect) {
        let frame = HabitTrackerLayout.frame(beside: composer, visible: visible)
        if window.frame != frame { window.setFrame(frame, display: true) }
        if !window.isVisible { refresh(); window.orderFrontRegardless() }
    }
    func focus() { window.makeKeyAndOrderFront(nil) }
    func hide() { window.orderOut(nil) }
    deinit {
        midnightTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

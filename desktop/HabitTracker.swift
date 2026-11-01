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
    static let size = NSSize(width: 148, height: 228)
    static func frame(beside composer: NSRect, visible: NSRect) -> NSRect {
        // Use the expanded footprint in both states, so opening Clip never pushes the checklist away.
        let x = max(visible.minX + 8, composer.minX - size.width - 12)
        var top = min(visible.maxY - 8, composer.maxY - 8)
        // Very narrow displays cannot fit it beside the composer: keep both usable.
        if x + size.width > composer.minX - 4 { top = min(top, composer.minY - 12) }
        return NSRect(x: x, y: max(visible.minY + 8, top - size.height), width: size.width, height: size.height)
    }
}

private final class HabitPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class HabitButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class HabitTracker: NSObject {
    private let store: HabitStore
    private let window: HabitPanel
    private let counter = NSTextField(labelWithString: "0/7")
    private var buttons = [NSButton]()
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
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: HabitTrackerLayout.size))
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true; glass.layer?.cornerRadius = 18; glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5; glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        window.contentView = glass
        let title = NSTextField(labelWithString: "Today")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = NSColor.white.withAlphaComponent(0.65)
        title.frame = NSRect(x: 16, y: 199, width: 70, height: 16); glass.addSubview(title)
        counter.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        counter.textColor = NSColor(calibratedRed: 0.47, green: 0.91, blue: 0.65, alpha: 1)
        counter.alignment = .right; counter.frame = NSRect(x: 94, y: 199, width: 38, height: 16)
        glass.addSubview(counter)
        for (index, habit) in ClipHabit.all.enumerated() {
            let button = HabitButton(frame: NSRect(x: 13, y: 166 - CGFloat(index) * 25, width: 122, height: 24))
            button.tag = index; button.title = "  " + habit.title
            button.font = .systemFont(ofSize: 12, weight: .regular)
            button.alignment = .left; button.isBordered = false; button.imagePosition = .imageLeading
            button.setButtonType(.toggle); button.target = self; button.action = #selector(toggleHabit(_:))
            glass.addSubview(button); buttons.append(button)
        }
        for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    @objc private func toggleHabit(_ sender: NSButton) {
        store.toggle(ClipHabit.all[sender.tag].id)
        refresh()
    }
    private func refresh() {
        let done = store.completed()
        counter.stringValue = "\(done.count)/7"
        counter.setAccessibilityLabel("\(done.count) of 7 habits completed today")
        for (button, habit) in zip(buttons, ClipHabit.all) {
            let checked = done.contains(habit.id)
            button.state = checked ? .on : .off
            button.image = NSImage(systemSymbolName: checked ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            button.contentTintColor = checked ? NSColor(calibratedRed: 0.47, green: 0.91, blue: 0.65, alpha: 1) : NSColor.white.withAlphaComponent(0.8)
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
    func hide() { window.orderOut(nil) }
    deinit {
        midnightTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

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
    private static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              dayKey(date, calendar: calendar) == key else { return nil }
        return date
    }
    /// Finalized binary outcomes survive the bounded per-habit detail cache.
    /// Run on refresh/wake, so days missed while Clip was closed become zero too.
    func rollover(on date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        let today = Self.dayKey(date, calendar: calendar)
        let days = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        var archive = defaults.dictionary(forKey: "clip.habits.history.v1") as? [String: Int] ?? [:]
        let oldArchive = archive
        let savedStart = defaults.string(forKey: "clip.habits.started.v1")
        let first = ([today] + days.keys.filter { $0 <= today } + [savedStart].compactMap { $0 })
            .filter { Self.date($0, calendar: calendar) != nil }.min() ?? today
        if savedStart != first { defaults.set(first, forKey: "clip.habits.started.v1") }
        // Import existing saved days once, without converting partial completions into success.
        for (day, completed) in days where day < today && archive[day] == nil {
            archive[day] = Set(completed).intersection(ClipHabit.all.map(\.id)).count == 7 ? 1 : 0
        }
        let last = defaults.string(forKey: "clip.habits.finalizedThrough.v1")
            .flatMap { Self.date($0, calendar: calendar) }
        var cursor = last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            ?? Self.date(first, calendar: calendar)!
        let end = calendar.startOfDay(for: date)
        while cursor < end {
            let day = Self.dayKey(cursor, calendar: calendar)
            if archive[day] == nil { archive[day] = 0 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        if archive != oldArchive { defaults.set(archive, forKey: "clip.habits.history.v1") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: end),
           Self.dayKey(yesterday, calendar: calendar) >= first {
            let checkpoint = Self.dayKey(yesterday, calendar: calendar)
            if defaults.string(forKey: "clip.habits.finalizedThrough.v1") != checkpoint {
                defaults.set(checkpoint, forKey: "clip.habits.finalizedThrough.v1")
            }
        }
    }
    func history(days count: Int, on date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [HabitHistoryDay] {
        rollover(on: date, calendar: calendar)
        let archive = defaults.dictionary(forKey: "clip.habits.history.v1") as? [String: Int] ?? [:]
        let today = calendar.startOfDay(for: date)
        let first = defaults.string(forKey: "clip.habits.started.v1") ?? Self.dayKey(today, calendar: calendar)
        return (0..<max(0, min(count, 366))).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = Self.dayKey(day, calendar: calendar), live = offset == 0
            let value: Int? = key < first ? nil : live ? (completed(on: date, calendar: calendar).count == 7 ? 1 : 0) : archive[key] ?? 0
            return HabitHistoryDay(date: day, result: value, isToday: live)
        }
    }
    func completed(on date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Set<String> {
        let days = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set(days[Self.dayKey(date, calendar: calendar)] ?? []).intersection(ClipHabit.all.map(\.id))
    }
    func toggle(_ id: String, on date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        guard ClipHabit.all.contains(where: { $0.id == id }) else { return }
        rollover(on: date, calendar: calendar)
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
    static let size = NSSize(width: 168, height: 236)
    static let historySize = NSSize(width: 288, height: 236)
    static let notchWidth: CGFloat = 48
    /// The hit target is transparent; the existing notch shell paints all black behind it.
    static func badge(notch: NSRect?, shell: NSRect, expanded: Bool) -> NSRect {
        if let notch {
            return NSRect(x: notch.minX - notchWidth + 6, y: notch.minY, width: 28, height: notch.height)
        }
        let height = min(24, shell.height)
        return NSRect(x: shell.minX + (expanded ? 78 : 6),
                      y: shell.maxY - height - (expanded ? 4 : 0), width: 28, height: height)
    }
    static func list(under badge: NSRect, visible: NSRect, size: NSSize = size) -> NSRect {
        let x = min(max(badge.maxX - size.width, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(x: x, y: max(visible.minY + 8, badge.minY - size.height - 8), width: size.width, height: size.height)
    }
}

private final class HabitPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
private final class HabitButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
/// One accessible button; individual habits are changed only in the opened list.
private final class HabitBadge: NSButton {
    var done = Set<String>() { didSet { needsDisplay = true } }
    var listOpen = false { didSet { needsDisplay = true } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let mint = NSColor(calibratedRed: 0.48, green: 0.95, blue: 0.66, alpha: 1)
        let radius = min(10, bounds.height / 2 - 4)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        for (index, habit) in ClipHabit.all.enumerated() {
            let complete = done.contains(habit.id)
            NSGraphicsContext.saveGraphicsState()
            if complete {
                let glow = NSShadow(); glow.shadowColor = mint.withAlphaComponent(0.5)
                glow.shadowBlurRadius = 3; glow.shadowOffset = .zero; glow.set()
            }
            mint.withAlphaComponent(complete ? 1 : listOpen ? 0.4 : 0.23).setStroke()
            let arc = NSBezierPath(), angle = 90 - CGFloat(index) * 360 / 7
            arc.appendArc(withCenter: center, radius: radius, startAngle: angle + 17, endAngle: angle - 17, clockwise: true)
            arc.lineWidth = 1.8; arc.lineCapStyle = .round; arc.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        if window?.firstResponder === self {
            NSColor.white.withAlphaComponent(0.65).setStroke()
            let focus = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 2)); focus.lineWidth = 0.7; focus.stroke()
        }
    }
}

final class HabitTracker: NSObject {
    private let store: HabitStore
    private let badgeWindow: HabitPanel
    private let window: HabitPanel
    private let badge = HabitBadge()
    private let counter = NSTextField(labelWithString: "0/7")
    private var buttons = [NSButton]()
    private var checklistControls = [NSView]()
    private let historyView = NSView(frame: NSRect(origin: .zero, size: HabitTrackerLayout.historySize))
    private let historyChart = HabitHistoryChart(frame: NSRect(x: 8, y: 52, width: 272, height: 124))
    private let historyRange = NSSegmentedControl(labels: ["7D", "30D"], trackingMode: .selectOne, target: nil, action: nil)
    private let historyCount = NSTextField(labelWithString: "")
    private let historyDetail = NSTextField(labelWithString: "")
    private var showingHistory = false
    private var midnightTimer: Timer?
    private var observers = [NSObjectProtocol]()
    private var wakeObserver: NSObjectProtocol?
    private var visibleFrame = NSRect.zero
    private(set) var listOpen = false
    var isVisible: Bool { badgeWindow.isVisible }
    func owns(_ candidate: NSWindow) -> Bool { candidate === window || candidate === badgeWindow }
    func contains(_ point: NSPoint) -> Bool { badgeWindow.frame.contains(point) || (listOpen && window.frame.contains(point)) }
    override convenience init() { self.init(store: HabitStore()) }
    private static func panel(_ size: NSSize, level: Int) -> HabitPanel {
        let p = HabitPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.becomesKeyOnlyIfNeeded = true; p.isOpaque = false; p.backgroundColor = .clear
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.level = NSWindow.Level(rawValue: level)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }
    init(store: HabitStore) {
        self.store = store
        badgeWindow = Self.panel(NSSize(width: 32, height: 33.5), level: NSWindow.Level.statusBar.rawValue + 2)
        window = Self.panel(HabitTrackerLayout.size, level: NSWindow.Level.popUpMenu.rawValue)
        super.init()
        badgeWindow.title = "Clip habit ring"; badgeWindow.hasShadow = false
        let hitTarget = NSView(frame: NSRect(origin: .zero, size: badgeWindow.frame.size))
        badgeWindow.contentView = hitTarget
        badge.frame = hitTarget.bounds; badge.autoresizingMask = [.width, .height]
        badge.title = ""; badge.isBordered = false; badge.target = self; badge.action = #selector(toggleList)
        hitTarget.addSubview(badge)
        window.title = "Clip habits"; window.hasShadow = true
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: HabitTrackerLayout.size))
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true; glass.layer?.cornerRadius = 16; glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5; glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        window.contentView = glass
        let title = NSTextField(labelWithString: "Today")
        title.font = .systemFont(ofSize: 11, weight: .medium); title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 15, y: 207, width: 50, height: 16); glass.addSubview(title)
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        counter.textColor = NSColor(calibratedRed: 0.48, green: 0.95, blue: 0.66, alpha: 1)
        counter.alignment = .right; counter.frame = NSRect(x: 95, y: 207, width: 30, height: 16)
        glass.addSubview(counter)
        let history = HabitButton(frame: NSRect(x: 69, y: 205, width: 20, height: 20))
        history.title = ""; history.isBordered = false
        history.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: "Habit history")
        history.contentTintColor = .secondaryLabelColor
        history.toolTip = "History · all seven or zero"; history.setAccessibilityLabel("Show habit history")
        history.target = self; history.action = #selector(showHistory); glass.addSubview(history)
        let close = HabitButton(frame: NSRect(x: 136, y: 205, width: 20, height: 20))
        close.title = ""; close.isBordered = false; close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close habit list")
        close.contentTintColor = .secondaryLabelColor; close.target = self; close.action = #selector(closeList)
        close.setAccessibilityLabel("Close habit list"); glass.addSubview(close)
        for (index, habit) in ClipHabit.all.enumerated() {
            let button = HabitButton(frame: NSRect(x: 13, y: 174 - CGFloat(index) * 25, width: 142, height: 24))
            button.tag = index; button.title = "  " + habit.title; button.font = .systemFont(ofSize: 12)
            button.alignment = .left; button.isBordered = false; button.imagePosition = .imageLeading
            button.setButtonType(.toggle); button.target = self; button.action = #selector(toggleHabit(_:))
            glass.addSubview(button); buttons.append(button)
        }
        checklistControls = glass.subviews
        historyView.isHidden = true; glass.addSubview(historyView)
        let back = HabitButton(frame: NSRect(x: 12, y: 205, width: 20, height: 20))
        back.title = ""; back.isBordered = false; back.contentTintColor = .secondaryLabelColor
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back to habits")
        back.setAccessibilityLabel("Back to habits"); back.target = self; back.action = #selector(showChecklist)
        historyView.addSubview(back)
        let historyTitle = NSTextField(labelWithString: "History")
        historyTitle.font = .systemFont(ofSize: 11, weight: .medium)
        historyTitle.frame = NSRect(x: 40, y: 207, width: 75, height: 16); historyView.addSubview(historyTitle)
        historyRange.frame = NSRect(x: 155, y: 203, width: 88, height: 24)
        historyRange.segmentStyle = .rounded; historyRange.controlSize = .small; historyRange.selectedSegment = 0
        historyRange.setAccessibilityLabel("History range")
        historyRange.target = self; historyRange.action = #selector(changeHistoryRange)
        historyView.addSubview(historyRange)
        let historyClose = HabitButton(frame: NSRect(x: 256, y: 205, width: 20, height: 20))
        historyClose.title = ""; historyClose.isBordered = false; historyClose.contentTintColor = .secondaryLabelColor
        historyClose.image = close.image; historyClose.setAccessibilityLabel("Close habit history")
        historyClose.target = self; historyClose.action = #selector(closeList); historyView.addSubview(historyClose)
        historyCount.font = .systemFont(ofSize: 10, weight: .medium); historyCount.textColor = counter.textColor
        historyCount.frame = NSRect(x: 18, y: 180, width: 254, height: 16); historyView.addSubview(historyCount)
        historyView.addSubview(historyChart)
        historyDetail.font = .systemFont(ofSize: 10); historyDetail.textColor = .secondaryLabelColor
        historyDetail.frame = NSRect(x: 18, y: 30, width: 254, height: 16); historyView.addSubview(historyDetail)
        let legend = NSTextField(labelWithString: "1 = all seven     0 = fewer than seven")
        legend.font = .systemFont(ofSize: 9); legend.textColor = .tertiaryLabelColor
        legend.frame = NSRect(x: 18, y: 12, width: 254, height: 14); historyView.addSubview(legend)
        historyChart.onHover = { [weak self] text in
            guard let self else { return }
            self.historyDetail.stringValue = text ?? self.todayHistoryDetail
        }
        for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    @objc private func toggleHabit(_ sender: NSButton) { store.toggle(ClipHabit.all[sender.tag].id); refresh() }
    private var todayHistoryDetail: String { "Today · \(store.completed().count)/7 · final at midnight" }
    @objc private func showHistory() { setHistory(true) }
    @objc private func showChecklist() { setHistory(false) }
    private func setHistory(_ visible: Bool) {
        showingHistory = visible
        for control in checklistControls { control.isHidden = visible }
        historyView.isHidden = !visible
        if visible { refreshHistory() }
        if listOpen { positionList() }
    }
    @objc private func changeHistoryRange() { refreshHistory() }
    private func refreshHistory() {
        let days = store.history(days: historyRange.selectedSegment == 1 ? 30 : 7)
        historyChart.days = days
        let finished = days.filter { !$0.isToday && $0.result != nil }
        historyCount.stringValue = "All seven · \(finished.filter { $0.result == 1 }.count) of \(finished.count) finished days"
        historyDetail.stringValue = todayHistoryDetail
    }
    @objc private func toggleList() { listOpen ? closeList() : openList() }
    private func openList() {
        guard !visibleFrame.isEmpty else { return }
        listOpen = true; refresh(); positionList(); window.orderFrontRegardless()
    }
    @objc func closeList() { listOpen = false; setHistory(false); refresh(); window.orderOut(nil) }
    func dismissOutside(_ point: NSPoint) { if listOpen && !contains(point) { closeList() } }
    private func positionList() {
        window.setFrame(HabitTrackerLayout.list(under: badgeWindow.frame, visible: visibleFrame,
                                               size: showingHistory ? HabitTrackerLayout.historySize : HabitTrackerLayout.size), display: true)
    }
    private func refresh() {
        store.rollover()
        let done = store.completed()
        badge.done = done; badge.listOpen = listOpen
        badge.toolTip = "Habits · \(done.count)/7 today · click for checklist"
        badge.setAccessibilityLabel("Daily habits: \(done.count) of 7 completed. \(listOpen ? "Close" : "Open") checklist")
        counter.stringValue = "\(done.count)/7"
        counter.setAccessibilityLabel("\(done.count) of 7 habits completed today")
        for (button, habit) in zip(buttons, ClipHabit.all) {
            let checked = done.contains(habit.id)
            button.state = checked ? .on : .off
            button.image = NSImage(systemSymbolName: checked ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            button.contentTintColor = checked ? NSColor(calibratedRed: 0.48, green: 0.95, blue: 0.66, alpha: 1) : .labelColor
            button.setAccessibilityLabel("\(habit.title), \(checked ? "completed" : "not completed") today")
            button.toolTip = checked ? "Undo \(habit.title.lowercased())" : "Complete \(habit.title.lowercased())"
        }
        if showingHistory { refreshHistory() }
        midnightTimer?.invalidate()
        if let next = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: Date())?.end {
            let timer = Timer(fire: next.addingTimeInterval(0.1), interval: 0, repeats: false) { [weak self] _ in self?.refresh() }
            midnightTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    func show(notch: NSRect?, shell: NSRect, expanded: Bool, visible: NSRect) {
        visibleFrame = visible
        let frame = HabitTrackerLayout.badge(notch: notch, shell: shell, expanded: expanded)
        if badgeWindow.frame != frame { badgeWindow.setFrame(frame, display: true) }
        if !badgeWindow.isVisible { refresh(); badgeWindow.orderFrontRegardless() }
        if listOpen { positionList(); if !window.isVisible { window.orderFrontRegardless() } }
    }
    func focus() { openList(); window.makeKeyAndOrderFront(nil) }
    func hide() { badgeWindow.orderOut(nil); window.orderOut(nil) }
    deinit {
        midnightTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

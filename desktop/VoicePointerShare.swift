import AppKit

struct PointerSample {
    let point: NSPoint
    let time: TimeInterval
}
struct PointerFocus {
    static func region(point: NSPoint, screen: NSRect) -> NSRect {
        let size = NSSize(width: min(760, screen.width), height: min(520, screen.height))
        return NSRect(x: floor(min(max(point.x - size.width / 2, screen.minX), screen.maxX - size.width)),
                      y: floor(min(max(point.y - size.height / 2, screen.minY), screen.maxY - size.height)), width: size.width, height: size.height)
    }
    static func captureRect(_ region: NSRect, desktopTop: CGFloat) -> NSRect {
        NSRect(x: region.minX, y: desktopTop - region.maxY, width: region.width, height: region.height)
    }
    static func normalized(_ point: NSPoint, in region: NSRect) -> [Double] {
        [Double(min(1, max(0, (point.x - region.minX) / region.width))), Double(min(1, max(0, (region.maxY - point.y) / region.height)))].map { ($0 * 10000).rounded() / 10000 }
    }
}

private final class PointerTrailView: NSView {
    var samples: [PointerSample] = []
    var origin = NSPoint.zero
    var now: TimeInterval = 0
    override func draw(_ dirtyRect: NSRect) {
        VoicePointerShare.drawTrail(samples, origin: origin, now: now)
        guard let last = samples.last else { return }
        let point = NSPoint(x: last.point.x - origin.x, y: last.point.y - origin.y)
        let label = "Point & Share"
        (label as NSString).draw(at: NSPoint(x: point.x + 18, y: point.y - 23), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.systemRed])
    }
}

// Samples stay in memory. Only bounded, annotated crops enter the voice session.
final class VoicePointerShare {
    var onFrame: ((String, [String: Any], @escaping (Bool) -> Void) -> Void)?
    var onStop: ((String) -> Void)?
    var excludedRects: (() -> [NSRect])?
    private(set) var active = false
    private var generation = 0
    private var timer: Timer?
    private var panel: NSPanel?
    private let trail = PointerTrailView()
    private var samples: [PointerSample] = []
    private var lastScreen: NSRect?
    private var dirty = false
    private var lastCapture: TimeInterval = 0
    private var lastMotion: TimeInterval = 0
    private var inFlight = false
    private var captureProcess: Process?
    private var frameCount = 0
    private var observers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    init() {
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.stop("Point sharing stopped") }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop("Point sharing stopped") })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.stop("Display changed · restart Point & Share") })
    }
    deinit {
        timer?.invalidate()
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
    }
    func resetSession() { stop(); frameCount = 0 }
    func start() -> Bool {
        guard !active, CGPreflightScreenCaptureAccess(), frameCount < 120 else { return false }
        active = true; generation += 1; samples = []; lastScreen = nil; dirty = false; inFlight = false; lastCapture = ProcessInfo.processInfo.systemUptime
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = trail; panel = p
        }
        let tick = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
        timer = tick; RunLoop.main.add(tick, forMode: .common)
        return true
    }
    func stop(_ reason: String = "") {
        active = false; generation += 1; timer?.invalidate(); timer = nil
        if let process = captureProcess, process.isRunning { process.terminate() }
        captureProcess = nil; panel?.orderOut(nil); samples = []; trail.samples = []; dirty = false; inFlight = false
        if !reason.isEmpty { onStop?(reason) }
    }
    private func step() {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime, pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { return }
        if lastScreen != screen.frame { samples = []; dirty = false; lastScreen = screen.frame; panel?.setFrame(screen.frame, display: false) }
        if excludedRects?().contains(where: { $0.contains(pointer) }) == true {
            samples = []; dirty = false; panel?.orderOut(nil); return
        }
        if let last = samples.last {
            if hypot(pointer.x - last.point.x, pointer.y - last.point.y) >= 2 {
                samples.append(PointerSample(point: pointer, time: now)); dirty = true; lastMotion = now
            }
        } else { samples.append(PointerSample(point: pointer, time: now)); dirty = true; lastMotion = now }
        samples = Array(samples.filter { now - $0.time < 3 }.suffix(90))
        // Retain the marker at rest, but never produce stationary repeat captures.
        if samples.isEmpty { samples = [PointerSample(point: pointer, time: now)] }
        trail.samples = samples; trail.origin = screen.frame.origin; trail.now = now; trail.needsDisplay = true
        if !inFlight { panel?.orderFrontRegardless() }
        guard dirty, !inFlight, now - lastCapture >= 2.5, now - lastMotion >= 0.3 || now - lastCapture >= 4 else { return }
        if frameCount >= 120 { stop("Point sharing limit reached · restart Talk"); return }
        capture(region: PointerFocus.region(point: pointer, screen: screen.frame), samples: samples, now: now)
    }
    private func capture(region: NSRect, samples capturedSamples: [PointerSample], now: TimeInterval) {
        guard CGPreflightScreenCaptureAccess() else { stop("Screen Recording access needed"); return }
        let stamp = generation
        inFlight = true; dirty = false; lastCapture = now; frameCount += 1
        panel?.orderOut(nil)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("clip-point-\(UUID().uuidString).png")
        let rect = PointerFocus.captureRect(region, desktopTop: NSScreen.screens.first?.frame.maxY ?? 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.active, self.generation == stamp else { return }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-t", "png", "-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", target.path]
            process.standardError = FileHandle.nullDevice
            self.captureProcess = process
            do { try process.run() } catch { self.stop("Point capture unavailable"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                process.waitUntilExit()
                let bytes = process.terminationStatus == 0 ? try? Data(contentsOf: target) : nil
                try? FileManager.default.removeItem(at: target)
                DispatchQueue.main.async { [self] in
                    guard self.active, self.generation == stamp else { return }
                    self.captureProcess = nil
                    guard let bytes, let source = NSImage(data: bytes), let image = Self.annotated(source, region: region, samples: capturedSamples, now: now) else { self.stop("Point capture unavailable"); return }
                    self.panel?.orderFrontRegardless()
                    let points = capturedSamples.filter { region.contains($0.point) }
                    let context: [String: Any] = ["pointer": PointerFocus.normalized(capturedSamples.last!.point, in: region), "trail": points.map { PointerFocus.normalized($0.point, in: region) }, "capturedAt": Date().timeIntervalSince1970]
                    self.onFrame?(image, context) { [weak self] success in
                        guard let self, self.active, self.generation == stamp else { return }
                        self.inFlight = false
                        if !success { self.stop("Point sharing unavailable · try again") }
                    }
                }
            }
        }
    }
    static func annotated(_ image: NSImage, region: NSRect, samples: [PointerSample], now: TimeInterval) -> String? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(region.width), pixelsHigh: Int(region.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: region.size))
        drawTrail(samples, origin: region.origin, now: now)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
    static func drawTrail(_ samples: [PointerSample], origin: NSPoint, now: TimeInterval) {
        for pair in zip(samples, samples.dropFirst()) {
            let alpha = max(0.12, 1 - (now - pair.1.time) / 3)
            NSColor.systemRed.withAlphaComponent(alpha * 0.8).setStroke()
            let path = NSBezierPath(); path.lineWidth = 3; path.lineCapStyle = .round
            path.move(to: NSPoint(x: pair.0.point.x - origin.x, y: pair.0.point.y - origin.y))
            path.line(to: NSPoint(x: pair.1.point.x - origin.x, y: pair.1.point.y - origin.y)); path.stroke()
        }
        guard let last = samples.last else { return }
        let p = NSPoint(x: last.point.x - origin.x, y: last.point.y - origin.y)
        NSColor.systemRed.withAlphaComponent(0.2).setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)).fill()
        let comet = NSBezierPath(); comet.move(to: NSPoint(x: p.x, y: p.y + 9)); comet.line(to: NSPoint(x: p.x + 7, y: p.y - 4)); comet.line(to: NSPoint(x: p.x, y: p.y - 1)); comet.line(to: NSPoint(x: p.x - 7, y: p.y - 4)); comet.close()
        NSColor.systemRed.setFill(); comet.fill(); NSColor.white.withAlphaComponent(0.85).setStroke(); comet.lineWidth = 1; comet.stroke()
    }
    static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 24), flipped: false) { _ in
            let path = NSBezierPath(); path.move(to: NSPoint(x: 11, y: 22)); path.line(to: NSPoint(x: 18, y: 9)); path.line(to: NSPoint(x: 11, y: 12)); path.line(to: NSPoint(x: 4, y: 9)); path.close()
            NSColor.white.setStroke(); path.lineWidth = 1.4; path.lineJoinStyle = .round; path.stroke()
            let tail = NSBezierPath(); tail.move(to: NSPoint(x: 11, y: 9)); tail.curve(to: NSPoint(x: 4, y: 2), controlPoint1: NSPoint(x: 15, y: 3), controlPoint2: NSPoint(x: 8, y: 0)); tail.lineWidth = 1.4; tail.lineCapStyle = .round; tail.stroke(); return true
        }
        image.isTemplate = true; image.accessibilityDescription = "Point & Share"; return image
    }
}

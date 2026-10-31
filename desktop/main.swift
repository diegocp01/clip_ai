import AppKit
import AVFoundation
import Speech
import WebKit
import Carbon

private let baseURL = URL(string: "http://127.0.0.1:4317")!
private let coral = NSColor(calibratedRed: 1, green: 0.47, blue: 0.36, alpha: 1)
private let signalGreen = NSColor(calibratedRed: 0.29, green: 0.93, blue: 0.47, alpha: 1)
private let serverUnavailable = "Local server unavailable"
private let drawingUnavailable = "Drawing view unavailable"

/// Which backend answers composer questions: GPT through the Codex SDK, or Claude through the Claude CLI.
enum AIProvider: String {
    case gpt, claude
    var signInRequired: String { self == .claude ? "Sign in with claude auth login" : "Sign in with codex login" }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class IslandView: NSView {
    var onExpand: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onExpand?(); return true }
}

final class ActivityMark: NSView {
    private var timer: Timer?
    private var phase: CGFloat = 0
    var active = false {
        didSet {
            guard active != oldValue else { return }
            timer?.invalidate(); timer = nil
            if active {
                timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    self?.phase += 0.5; self?.needsDisplay = true
                }
            }
            needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        coral.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 0)).fill()
        for i in 0..<4 {
            let height: CGFloat = active ? 4 + abs(sin(phase + CGFloat(i) * 0.85)) * 10 : [5, 10, 13, 7][i]
            coral.withAlphaComponent(active ? 1 : 0.8).setFill()
            NSBezierPath(roundedRect: NSRect(x: 4 + CGFloat(i) * 4, y: (bounds.height - height) / 2, width: 2, height: height), xRadius: 1, yRadius: 1).fill()
        }
    }
    deinit { timer?.invalidate() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, URLSessionDataDelegate, AVSpeechSynthesizerDelegate {
    private var island: FloatingPanel!
    private var notchBridge: FloatingPanel!
    private var islandView: IslandView!
    private var composerSurface: ComposerSurface!
    private var composerTransition = 0
    private var composerTransitioning = false
    private var composerTimer: Timer?
    private var composerReveal: CGFloat = 0
    private var overlay: FloatingPanel!
    private var webView: WKWebView!
    private var captions: FloatingPanel!
    private var captionText: NSTextField!
    private var statusItem: NSStatusItem!
    private var statusLabel: NSTextField!
    private var activityMark: ActivityMark!
    private var signalHost: NSView!
    private let statusLine = CALayer()
    private let loadingLine = CAShapeLayer()
    private var startupLoading = true
    private var loadingFinishing = false
    private var loadingStarted: CFTimeInterval = 0
    private let sensingLine = CAGradientLayer()
    private let sensingEye = CAGradientLayer()
    private var signalBar = SignalBar()
    private var pointerOnIsland = false
    private let wakeSound = WakeSound()
    private var provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .gpt
    private var gooPanel: FloatingPanel!
    private let gooFill = CAShapeLayer()
    private let gooLiquid = CALayer()
    private var liquid = LiquidSim()
    private var wake = Spring(stiffness: 150, damping: 17)
    private var tether = GooTether()
    private var dwell = DwellTimer()
    private var dwellPanel: FloatingPanel!
    private let dwellRing = CAShapeLayer()
    private var wakeEnds: (rest: IslandLayout, awake: IslandLayout)?
    private var wakeRegion = NSRect.zero
    private var frameTimer: Timer?
    private var lastFrame: CFTimeInterval = 0
    private var lastPointerCheck: CFTimeInterval = 0
    private var collapseButton: NSButton!
    private var outsideClickMonitor: Any?
    private var menuTrackingDepth = 0
    private var prompt: NSTextField!
    private var expandedControls = [NSView]()
    private var sendButton: NSButton!
    private var micButton: NSButton!
    private var talkButton: NSButton!
    private var voiceRequested = false
    private var voiceGeneration = 0
    private var captureButton: NSButton!
    private var voiceButton: NSButton!
    private var providerControl: NSPopUpButton!
    private var modelCaption: NSTextField!
    private var expanded = false
    private var overlayReady = false
    private var hitTestTimer: Timer?
    private var hitTestInFlight = false
    private var previous: [String: Any]?
    private var history = [[String: String]]()
    private var attachedImage: String?
    private var voiceEnabled = true
    private var currentStatus = "Starting…"
    // What keeps the island from being ready; "Ready" resolves to this while it is set.
    private var connectionProblem: String? = "Starting…"
    private var healthTimer: Timer?
    private var settleTimer: Timer?
    private var keyboardMonitor: Any?
    private var hotKey: EventHotKeyRef?
    private var editingHotKeys = [EventHotKeyRef]()
    private lazy var selectionEditor = SelectionEditor(provider: { [weak self] in self?.provider.rawValue ?? "gpt" }) { [weak self] text in self?.setStatus(text) }
    private var eventHandler: EventHandlerRef?
    private var ownedServer: Process?
    private var requestTask: URLSessionDataTask?
    private lazy var streamingSession = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    private var requestGeneration = 0
    private var responseBuffer = Data()
    private var responseStatus = 200
    private var resultReceived = false
    private var previewVisible = false
    private var pendingMessage = ""
    private var busy = false
    private let speech = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionTimer: Timer?
    private var recognitionGeneration = 0
    private var permissionGeneration = 0
    private var latestTranscript = ""
    private var recording = false
    private var requestingPermission = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        speech.delegate = self
        buildIsland()
        buildOverlay()
        startOverlayHitTesting()
        buildCaptions()
        buildMenu()
        registerShortcut()
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEndedTracking), name: NSMenu.didEndTrackingNotification, object: nil)
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.menuTrackingDepth == 0 else { return event }
            if event.type != .keyDown {
                if self.expanded, let window = event.window, window !== self.island,
                   window.level.rawValue < NSWindow.Level.popUpMenu.rawValue,
                   !self.island.frame.contains(window.convertPoint(toScreen: event.locationInWindow)) {
                    self.setExpanded(false)
                }
                return event
            }
            if event.keyCode == 53 {
                if self.voiceRequested { self.stopRealtimeVoice() }
                if self.recording { self.stopDictation(sendTranscript: false) }
                else if self.busy { self.cancelRequest() }
                self.hideVisuals(); self.setExpanded(false)
                return nil
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.menuTrackingDepth == 0, self.expanded, !self.island.frame.contains(NSEvent.mouseLocation) else { return }
            self.setExpanded(false)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        island.orderFrontRegardless()
        checkServer(startIfNeeded: true)
    }

    // Native popup menus use their own windows. Selecting a circular menu or
    // pressing Escape inside it must not trigger the composer's outside click.
    @objc private func menuBeganTracking(_ notification: Notification) { menuTrackingDepth += 1 }
    @objc private func menuEndedTracking(_ notification: Notification) { menuTrackingDepth = max(0, menuTrackingDepth - 1) }

    private func panel(_ rect: NSRect, level: NSWindow.Level) -> FloatingPanel {
        let p = FloatingPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = level
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }
    private func label(_ text: String, size: CGFloat, color: NSColor = .white) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: .medium)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
    private func button(_ text: String, frame: NSRect, action: Selector, symbol: String? = nil, iconOnly: Bool = false) -> NSButton {
        let b = NSButton(title: text, target: self, action: action)
        b.frame = frame
        b.isBordered = false
        b.font = .systemFont(ofSize: 11, weight: .medium)
        b.contentTintColor = NSColor(white: 0.92, alpha: 1)
        b.wantsLayer = true
        b.layer?.cornerRadius = frame.height / 2
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        b.layer?.borderWidth = 0.5
        b.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text); b.imagePosition = iconOnly ? .imageOnly : .imageLeading }
        b.setAccessibilityLabel(text)
        b.toolTip = text
        islandView.addSubview(b)
        expandedControls.append(b)
        return b
    }
    private func buildIsland() {
        island = panel(.zero, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        notchBridge = panel(.zero, level: island.level)
        notchBridge.title = "Clippy notch background"
        notchBridge.backgroundColor = .black
        notchBridge.ignoresMouseEvents = true
        notchBridge.setAccessibilityElement(false)
        island.title = "Clippy island"
        island.appearance = NSAppearance(named: .darkAqua)
        islandView = IslandView(frame: .zero)
        islandView.wantsLayer = true
        islandView.layer?.backgroundColor = NSColor(white: 0.025, alpha: 1).cgColor
        islandView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        islandView.layer?.borderWidth = 0.5
        islandView.layer?.cornerCurve = .continuous
        islandView.onExpand = { [weak self] in if self?.expanded == false { self?.setExpanded(true, focus: true) } }
        composerSurface = ComposerSurface(content: islandView)
        island.contentView = composerSurface
        islandView.setAccessibilityElement(true)
        islandView.setAccessibilityRole(.button)
        statusLabel = label(currentStatus, size: 12)
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.alignment = .left
        islandView.addSubview(statusLabel)
        activityMark = ActivityMark(frame: .zero)
        islandView.addSubview(activityMark)
        // A layer-hosting view: AppKit resets shadows and sublayers on layers it backs itself.
        signalHost = NSView(frame: .zero)
        signalHost.layer = CALayer()
        signalHost.wantsLayer = true
        signalHost.layer?.masksToBounds = true
        signalHost.autoresizingMask = [.width, .height]
        // Two bars lying on top of each other read as one line until they split apart.
        for bar in [sensingLine, sensingEye] {
            bar.startPoint = CGPoint(x: 0, y: 0.5)
            bar.endPoint = CGPoint(x: 1, y: 0.5)
            bar.colors = [signalGreen.withAlphaComponent(0), signalGreen.withAlphaComponent(0.6), NSColor(calibratedRed: 0.8, green: 1, blue: 0.86, alpha: 1), signalGreen.withAlphaComponent(0.6), signalGreen.withAlphaComponent(0)].map(\.cgColor)
            bar.locations = [0, 0.3, 0.5, 0.7, 1]
            bar.cornerRadius = 1
            bar.shadowColor = signalGreen.cgColor
            bar.shadowOffset = .zero
            bar.shadowRadius = 5
            bar.shadowOpacity = 1
            bar.opacity = 0
        }
        statusLine.backgroundColor = coral.cgColor
        statusLine.shadowColor = coral.cgColor
        statusLine.shadowOffset = .zero
        statusLine.shadowRadius = 4
        statusLine.shadowOpacity = 0.8
        loadingLine.fillColor = nil
        loadingLine.strokeColor = NSColor.white.cgColor
        loadingLine.lineWidth = 2.5
        loadingLine.lineCap = .round
        loadingLine.lineJoin = .round
        loadingLine.shadowColor = NSColor.white.cgColor
        loadingLine.shadowOffset = .zero
        loadingLine.shadowRadius = 5
        loadingLine.shadowOpacity = 0.9
        loadingLine.opacity = 0
        for layer in [sensingLine, sensingEye, statusLine, loadingLine] { signalHost.layer?.addSublayer(layer) }
        islandView.addSubview(signalHost, positioned: .below, relativeTo: statusLabel)
        buildGoo()
        prompt = NSTextField(frame: ComposerGeometry.input)
        prompt.placeholderString = ""
        prompt.setAccessibilityLabel("Ask Clippy")
        prompt.font = .systemFont(ofSize: 14)
        prompt.textColor = .white
        prompt.isBezeled = false
        prompt.drawsBackground = false
        prompt.focusRingType = .none
        prompt.target = self
        prompt.action = #selector(sendPrompt)
        islandView.addSubview(prompt)
        expandedControls.append(prompt)
        collapseButton = button("Collapse island", frame: ComposerGeometry.collapse, action: #selector(collapseIsland), symbol: "chevron.up", iconOnly: true)
        collapseButton.toolTip = "Make smaller · Esc or ⌃⌥Space"
        modelCaption = NSTextField(labelWithString: "")
        modelCaption.frame = ComposerGeometry.modelCaption
        modelCaption.font = .systemFont(ofSize: 10, weight: .light)
        modelCaption.textColor = NSColor.white.withAlphaComponent(0.46)
        modelCaption.alignment = .center
        modelCaption.lineBreakMode = .byTruncatingTail
        islandView.addSubview(modelCaption)
        expandedControls.append(modelCaption)
        captureButton = button("Screen", frame: ComposerGeometry.screen, action: #selector(captureScreen), symbol: "rectangle.dashed", iconOnly: true)
        captureButton.toolTip = "Attach one screenshot to your next question"
        micButton = NSButton(title: "Dictate", target: self, action: #selector(toggleDictation))
        talkButton = button("Talk", frame: ComposerGeometry.talk, action: #selector(toggleRealtimeVoice), symbol: "waveform", iconOnly: true)
        talkButton.toolTip = "Live AI voice · separately billed API usage · click End to stop the microphone"
        voiceButton = button("Voice on", frame: ComposerGeometry.voice, action: #selector(toggleVoice), symbol: "speaker.wave.2", iconOnly: true)
        voiceButton.contentTintColor = .systemBlue
        voiceButton.toolTip = "Spoken replies on · click to mute"
        sendButton = button("Send", frame: ComposerGeometry.send, action: #selector(sendOrCancel), symbol: "arrow.up", iconOnly: true)
        sendButton.layer?.backgroundColor = NSColor.clear.cgColor
        sendButton.layer?.borderWidth = 0
        sendButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .thin)
        sendButton.contentTintColor = .white
        sendButton.toolTip = "Send · Return"
        let drawButton = button("Draw", frame: ComposerGeometry.draw, action: #selector(sendPrompt), symbol: "pencil.tip.crop.circle", iconOnly: true)
        drawButton.toolTip = "Draw your prompt · type an idea, then click Draw"
        providerControl = NSPopUpButton(frame: ComposerGeometry.provider)
        providerControl.addItems(withTitles: ["GPT", "Claude"])
        providerControl.item(at: 0)?.image = mascot("mascot-gpt", description: "GPT") ?? NSImage(systemSymbolName: "cpu", accessibilityDescription: "GPT")
        providerControl.item(at: 1)?.image = mascot("mascot-claude", description: "Claude") ?? NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude")
        providerControl.imagePosition = .imageOnly
        (providerControl.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        providerControl.target = self
        providerControl.action = #selector(providerChanged)
        providerControl.isBordered = false
        providerControl.contentTintColor = .white
        providerControl.wantsLayer = true
        providerControl.layer?.cornerRadius = 18
        providerControl.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        providerControl.layer?.borderWidth = 0.5
        providerControl.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        providerControl.setAccessibilityLabel("Model")
        providerControl.toolTip = "GPT uses the Codex SDK · Claude uses the Claude CLI"
        islandView.addSubview(providerControl)
        expandedControls.append(providerControl)
        updateProviderControl()
        _ = button("More options", frame: ComposerGeometry.more, action: #selector(showIslandOptions(_:)), symbol: "ellipsis", iconOnly: true)
        setExpanded(false)
    }
    // Liquid can reach past the island, so it has its own click-through panel below it.
    // In the island's window it would block the menu bar.
    private func buildGoo() {
        gooPanel = panel(.zero, level: island.level)
        gooPanel.title = "Clippy liquid edge"
        gooPanel.ignoresMouseEvents = true
        gooPanel.setAccessibilityElement(false)
        let host = NSView(frame: .zero)
        host.layer = CALayer()
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        gooPanel.contentView = host
        gooFill.fillColor = NSColor.black.cgColor
        gooLiquid.contentsGravity = .resize
        for layer in [gooFill, gooLiquid] { host.layer?.addSublayer(layer) }
        buildDwellRing()
    }
    // A tiny click-through ring beside the pointer shows the hold filling up.
    private func buildDwellRing() {
        let size: CGFloat = 20
        dwellPanel = panel(NSRect(x: 0, y: 0, width: size, height: size), level: island.level)
        dwellPanel.title = "Clippy hold timer"
        dwellPanel.ignoresMouseEvents = true
        dwellPanel.setAccessibilityElement(false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        host.layer = CALayer()
        host.wantsLayer = true
        dwellPanel.contentView = host
        let circle = CGMutablePath()
        circle.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: 6, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        let track = CAShapeLayer()
        track.path = circle
        track.fillColor = nil
        track.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        track.lineWidth = 1.5
        dwellRing.path = circle
        dwellRing.fillColor = nil
        dwellRing.strokeColor = NSColor.white.withAlphaComponent(0.7).cgColor
        dwellRing.lineWidth = 1.5
        dwellRing.lineCap = .round
        dwellRing.strokeEnd = 0
        host.layer?.addSublayer(track)
        host.layer?.addSublayer(dwellRing)
    }
    private func updateDwell(pointer: NSPoint, inside: Bool, dt: CGFloat) {
        guard !expanded else { dwell.disarm(); hideDwellRing(); return }
        // Text or the waveform has no resting area of its own, so the whole island counts.
        let onIsland = wakeRegion.isEmpty ? island.frame.insetBy(dx: 0, dy: -1).contains(pointer) : inside
        if dwell.update(inside: island.isVisible && onIsland && NSEvent.pressedMouseButtons == 0, dt: dt) {
            hideDwellRing()
            setExpanded(true, focus: true)
            return
        }
        // It stays hidden for a moment, so passing over the notch shows nothing.
        guard dwell.elapsed > 0.1 else { hideDwellRing(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dwellRing.strokeEnd = dwell.progress
        CATransaction.commit()
        dwellPanel.alphaValue = smoothstep(0.1, 0.3, dwell.elapsed)
        dwellPanel.setFrameOrigin(NSPoint(x: pointer.x + 10, y: pointer.y - 26))
        if !dwellPanel.isVisible { dwellPanel.orderFrontRegardless() }
    }
    private func hideDwellRing() { if dwellPanel.isVisible { dwellPanel.orderOut(nil) } }
    @objc private func collapseIsland() { setExpanded(false) }
    @objc private func showIslandOptions(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [("New conversation", #selector(newConversation)), ("Dictate on-device", #selector(toggleDictation)), ("Hide drawing", #selector(hideVisuals)), ("Show last drawing", #selector(showLastVisual)), ("Enable text editing…", #selector(enableTextEditing)), ("Cancel text edit", #selector(cancelTextEdit))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        let soundItem = menu.addItem(withTitle: "Wake sound", action: #selector(toggleWakeSound), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = wakeSound.enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Proofread selection     ⌃⌥D", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Rewrite selection          ⌃D", action: nil, keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSPoint(x: sender.frame.minX, y: sender.frame.minY), in: islandView)
    }
    @objc private func toggleWakeSound() { wakeSound.enabled.toggle() }
    private func buildOverlay() {
        overlay = panel(NSRect(x: 0, y: 0, width: 900, height: 650), level: .floating)
        overlay.title = "Clippy drawing"
        overlay.isMovableByWindowBackground = false
        overlay.ignoresMouseEvents = true
        let content = WKUserContentController()
        content.add(self, name: "clippy")
        content.addUserScript(WKUserScript(source: "window.clippyNative = true; window.clippyCaptionManaged = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController = content
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: overlay.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        overlay.contentView = webView
        positionOverlay()
    }
    private func startOverlayHitTesting() {
        // The transparent WebView has a rectangular native surface. Test its
        // actual drawn objects so the empty area behaves like the desktop.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.updateOverlayHitTesting(); if self?.frameTimer == nil { self?.updatePointer() } }
        hitTestTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func updatePointer() {
        guard !composerTransitioning else { return }
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastPointerCheck, 0.1))
        lastPointerCheck = now
        let pointer = NSEvent.mouseLocation
        if expanded {
            updateDwell(pointer: pointer, inside: false, dt: dt)
            let point = island.isVisible && menuTrackingDepth == 0
                ? NSPoint(x: pointer.x - island.frame.minX, y: pointer.y - island.frame.minY) : nil
            composerSurface.updateHover(at: point, details: [
                attachedImage == nil ? "Attach a screenshot to your next question." : "Remove the attached screenshot.",
                voiceRequested ? "End the live voice conversation." : "Start a live voice conversation.",
                voiceEnabled ? "Mute spoken replies." : "Turn spoken replies on.",
                "Choose GPT or Claude.",
                "Draw your prompt with the selected model.",
                "Open settings and additional actions.",
                "Close the composer and keep your draft."
            ])
            return
        }
        // The pointer can rest on the screen's top edge, which a rect excludes.
        let region = (pointerOnIsland ? island.frame : wakeRegion).insetBy(dx: 0, dy: -1)
        let inside = island.isVisible && region.contains(pointer)
        if wakeEnds?.rest.isNotched == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let outline = IslandOutline(rect: island.frame)
            let clickedAway = NSEvent.pressedMouseButtons != 0
            _ = tether.update(inside: inside, distance: outline.distance(to: pointer), pressed: clickedAway, dt: dt)
        } else { tether.attached = inside }
        updateDwell(pointer: pointer, inside: inside, dt: dt)
        guard !expanded, tether.attached != pointerOnIsland else { return }
        pointerOnIsland = tether.attached
        if pointerOnIsland {
            // Only a fresh idle hover wakes the sound; status changes and
            // live speech/microphone activity remain quiet. Tether motion does not retrigger it.
            if inside && !expanded && currentStatus == "Ready" && !busy && !talking
                && !requestingPermission && !speech.isSpeaking && NSEvent.pressedMouseButtons == 0 {
                wakeSound.play()
            }
            let anchor = IslandOutline(rect: island.frame)
            let start = anchor.point(at: anchor.nearest(to: pointer))
            liquid.attach(at: start)
            if wake.value < 0.1 { signalBar = SignalBar() }
        }
        layoutIsland()
    }
    private func updateOverlayHitTesting() {
        guard overlay.isVisible, overlayReady else {
            overlay.ignoresMouseEvents = true
            return
        }
        // Keep the same receiver from mouse-down to mouse-up, including orbit
        // gestures and the native panel drag. Never steal another app's drag.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let point = NSEvent.mouseLocation
        let frame = overlay.frame
        guard frame.contains(point) else { overlay.ignoresMouseEvents = true; return }
        guard !hitTestInFlight else { return }
        hitTestInFlight = true
        let x = point.x - frame.minX
        let y = frame.maxY - point.y
        webView.evaluateJavaScript("typeof window.clippyHitTest === 'function' && window.clippyHitTest(\(x), \(y))") { [weak self] value, error in
            guard let self else { return }
            self.hitTestInFlight = false
            guard self.overlay.isVisible, self.overlayReady, NSEvent.pressedMouseButtons == 0 else { return }
            let current = NSEvent.mouseLocation
            // A slow script result must not enable a different area after the
            // pointer or panel has moved. The next timer tick will test it.
            guard self.overlay.frame == frame, hypot(current.x - point.x, current.y - point.y) <= 8 else {
                self.overlay.ignoresMouseEvents = true
                return
            }
            self.overlay.ignoresMouseEvents = error != nil || (value as? Bool != true)
        }
    }
    private func buildCaptions() {
        captions = panel(.zero, level: .floating)
        captions.ignoresMouseEvents = true
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.87).cgColor
        v.layer?.cornerRadius = 14
        captionText = label("", size: 16)
        captionText.alignment = .center
        captionText.maximumNumberOfLines = 3
        captionText.lineBreakMode = .byWordWrapping
        v.addSubview(captionText)
        captions.contentView = v
    }
    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Clippy")
        let menu = NSMenu()
        for (title, action) in [("Ask Clippy  ⌃⌥Space", #selector(toggleIsland)), ("Show last drawing", #selector(showLastVisual)), ("Hide drawings", #selector(hideVisuals)), ("New conversation", #selector(newConversation))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clippy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        menu.insertItem(NSMenuItem(title: "Proofread selection: ⌃⌥D", action: nil, keyEquivalent: ""), at: 0)
        menu.insertItem(NSMenuItem(title: "Rewrite selection: ⌃D", action: nil, keyEquivalent: ""), at: 1)
        let cancelEdit = NSMenuItem(title: "Cancel text edit", action: #selector(cancelTextEdit), keyEquivalent: "")
        cancelEdit.target = self
        menu.insertItem(cancelEdit, at: 2)
        let editingAccess = NSMenuItem(title: "Enable text editing…", action: #selector(enableTextEditing), keyEquivalent: "")
        editingAccess.target = self
        menu.insertItem(editingAccess, at: 3)
        let main = NSMenu()
        let appRoot = NSMenuItem(title: "Clippy", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Clippy")
        let showDrawing = appMenu.addItem(withTitle: "Show last drawing", action: #selector(showLastVisual), keyEquivalent: "d")
        showDrawing.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clippy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appRoot.submenu = appMenu
        main.addItem(appRoot)
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editRoot.submenu = edit
        main.addItem(editRoot)
        NSApp.mainMenu = main
    }
    private func registerShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return noErr }
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return noErr }
            let action = id.id
            DispatchQueue.main.async {
                switch action {
                case 2: app.selectionEditor.start("proofread")
                case 3: app.selectionEditor.start("rewrite")
                default: app.toggleIsland()
                }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        let id = EventHotKeyID(signature: OSType(0x434C5059), id: 1)
        if RegisterEventHotKey(49, UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey) != noErr {
            setStatus("Shortcut unavailable. Hold the pointer on the island to open it.")
        }
        for (number, modifiers) in [(UInt32(2), UInt32(controlKey | optionKey)), (UInt32(3), UInt32(controlKey))] {
            var key: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: OSType(0x434C5059), id: number)
            if RegisterEventHotKey(UInt32(kVK_ANSI_D), modifiers, identifier, GetApplicationEventTarget(), 0, &key) == noErr, let key {
                editingHotKeys.append(key)
            } else { setStatus("Text editing shortcut unavailable · already in use") }
        }
    }
    @objc private func toggleIsland() { setExpanded(!expanded, focus: true) }
    @objc private func cancelTextEdit() { selectionEditor.cancel(); setStatus("Text edit cancelled") }
    @objc private func enableTextEditing() { selectionEditor.requestAccess() }
    private func setExpanded(_ value: Bool, focus: Bool = false, animated: Bool = true) {
        let changed = expanded != value
        if !changed && composerTransitioning && animated { return }
        let sourceFrame = island.frame
        let sourceRadius = composerTransitioning ? composerSurface.currentRadius : (islandView.layer?.cornerRadius ?? 10)
        let sourceReveal = composerReveal
        expanded = value
        composerTransition += 1
        let generation = composerTransition
        composerTimer?.invalidate(); composerTimer = nil
        composerTransitioning = false
        stopFrames()
        gooPanel.orderOut(nil)
        let screen = island.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let content: IslandContent = talking ? .audio : currentStatus == "Ready" ? .idle
            : .status(textWidth: ceil(statusLabel.cell?.cellSize.width ?? 52))
        let target = IslandLayout(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                                  leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea,
                                  expanded: value, content: content)
        let shouldAnimate = changed && animated && !sourceFrame.isEmpty
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate else {
            composerReveal = value ? 1 : 0
            finishComposerLayout(focus: focus)
            return
        }

        if value { _ = layoutIsland(updateFrame: false) }
        else { island.makeFirstResponder(nil); island.resignKey() }
        updateNotchBridge(target)
        composerSurface.beginMorph()
        for control in expandedControls { control.isHidden = false }
        islandView.layer?.backgroundColor = NSColor.clear.cgColor
        islandView.layer?.borderWidth = 0
        composerTransitioning = true
        composerSurface.setMorph(reveal: sourceReveal, radius: sourceRadius, notched: target.isNotched)
        island.orderFrontRegardless()
        let started = CACurrentMediaTime()
        let duration = (value ? 0.52 : 0.44) * Double(max(abs((value ? 1 : 0) - sourceReveal), 0.3))
        // One clock owns frame, curvature, the black clearing and control reveal.
        // Reversals start from the current frame/material, not a stale endpoint.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, self.composerTransition == generation else { timer.invalidate(); return }
            let progress = CGFloat(min((CACurrentMediaTime() - started) / duration, 1))
            let eased = progress * progress * (3 - 2 * progress)
            self.composerReveal = mix(sourceReveal, value ? 1 : 0, eased)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.island.setFrame(ComposerGeometry.morphFrame(from: sourceFrame, to: target.frame, progress: progress), display: true)
            self.composerSurface.setMorph(reveal: self.composerReveal,
                                          radius: mix(sourceRadius, target.cornerRadius, eased), notched: target.isNotched)
            CATransaction.commit()
            self.island.hasShadow = self.composerReveal > 0.25
            if progress >= 1 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                timer.invalidate(); self.composerTimer = nil
                self.composerTransitioning = false
                self.composerReveal = value ? 1 : 0
                self.finishComposerLayout(focus: focus)
            }
        }
        composerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func updateNotchBridge(_ layout: IslandLayout) {
        if let bridge = layout.notchBridge {
            notchBridge.setFrame(bridge, display: true)
            notchBridge.orderFrontRegardless()
            notchBridge.order(.below, relativeTo: island.windowNumber)
        } else { notchBridge.orderOut(nil) }
    }
    private func finishComposerLayout(focus: Bool) {
        composerSurface.endMorph()
        composerSurface.showComposer(expanded)
        islandView.alphaValue = 1
        for control in expandedControls { control.isHidden = !expanded }
        let layout = layoutIsland(updateFrame: false)
        island.setFrame(layout.frame, display: true)
        signalHost.frame = layout.bounds
        updateNotchBridge(layout)
        island.hasShadow = expanded
        island.orderFrontRegardless()
        if layout.isNotched && !expanded {
            gooPanel.orderFrontRegardless()
            gooPanel.order(.below, relativeTo: island.windowNumber)
        } else { gooPanel.orderOut(nil) }
        if expanded && focus { island.makeKey(); island.makeFirstResponder(prompt) }
        if !expanded { island.resignKey() }

    }
    private var talking: Bool { voiceRequested || recording || currentStatus == "Speaking" }
    // Resting: a green line. Audio live: the waveform. Anything else to say: text and line.
    @discardableResult private func layoutIsland(updateFrame: Bool = true) -> IslandLayout {
        let content: IslandContent = startupLoading && !expanded ? .loading : talking ? .audio : currentStatus == "Ready" ? .idle : .status(textWidth: ceil(statusLabel.cell?.cellSize.width ?? 52))
        let awake = pointerOnIsland && content == .idle && !expanded
        let screen = island?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let makeLayout = { [expanded] (hovered: Bool) in
            IslandLayout(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                         leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea,
                         expanded: expanded, content: content, hovered: hovered)
        }
        let layout = makeLayout(awake)
        updateLoadingLine(layout: content == .loading ? layout : nil)
        guard !composerTransitioning else { return layout }
        islandView.layer?.cornerRadius = layout.cornerRadius
        islandView.layer?.maskedCorners = layout.isNotched && !expanded
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        islandView.layer?.backgroundColor = (expanded ? NSColor.clear : layout.isNotched ? .black : NSColor(white: 0.025, alpha: 1)).cgColor
        islandView.layer?.borderWidth = expanded || layout.isNotched ? 0 : 0.5
        statusLabel.frame = layout.statusFrame
        activityMark.frame = layout.activityFrame
        signalHost.layer?.maskedCorners = islandView.layer?.maskedCorners ?? []
        // Idle readiness is already represented by the compact menu-bar line.
        if case .status = content { statusLabel.isHidden = false } else { statusLabel.isHidden = true }
        modelCaption.isHidden = !expanded || content != .idle
        activityMark.isHidden = content != .audio
        islandView.toolTip = expanded ? nil : "\(currentStatus) · Hold here to open · ⌃⌥Space"
        islandView.setAccessibilityLabel("Clippy: \(currentStatus)")
        wake.target = awake ? 1 : 0
        if content == .idle && !expanded {
            let rest = makeLayout(false)
            wakeEnds = (rest, makeLayout(true))
            wakeRegion = rest.wakeArea.offsetBy(dx: rest.frame.minX, dy: rest.frame.minY)
            gooPanel.setFrame(rest.frame.insetBy(dx: -220, dy: 0).union(rest.frame.offsetBy(dx: 0, dy: -210)), display: false)
            if awake || wake.value > 0 || !liquid.isSettled || frameTimer != nil {
                startFrames()
                applyWake()
                return layout
            }
        } else {
            // Text or the composer takes over from any liquid still in motion.
            stopFrames()
            wakeRegion = .zero
            wake.jump(to: 0); tether.attached = false; pointerOnIsland = false; liquid.reset()
        }
        updateSignal(content: content, layout: layout)
        if updateFrame {
            if island.frame.isEmpty || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                island.setFrame(layout.frame, display: true)
            } else if island.frame != layout.frame {
                NSAnimationContext.runAnimationGroup { context in
                    // Overshoots slightly at rest so the island feels springy; the composer just opens.
                    context.duration = expanded ? 0.18 : 0.26
                    if !expanded { context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.5, 0.5, 1) }
                    island.animator().setFrame(layout.frame, display: true)
                }
            }
        }
        if layout.isNotched && !expanded {
            gooPanel.setFrame(layout.frame.insetBy(dx: -220, dy: 0).union(layout.frame.offsetBy(dx: 0, dy: -210)), display: false)
            drawGoo(outline: IslandOutline(rect: layout.frame))
        }
        return layout
    }
    private static let loadingCycle: CFTimeInterval = 1.7
    /// When in each sweep the light's front reaches the end of the path.
    private static let loadingArrival = 0.75
    // A white light sweeps around the camera until the server has answered.
    private func updateLoadingLine(layout: IslandLayout?) {
        guard let layout else {
            if !loadingFinishing {
                loadingLine.removeAllAnimations()
                loadingLine.opacity = 0
            }
            return
        }
        let points = layout.loadingPath, path = CGMutablePath()
        path.move(to: points[0])
        if points.count > 2 {
            for i in 1..<points.count - 1 { path.addArc(tangent1End: points[i], tangent2End: points[i + 1], radius: 8) }
        }
        path.addLine(to: points[points.count - 1])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loadingLine.frame = layout.bounds
        loadingLine.path = path
        loadingLine.opacity = 1
        CATransaction.commit()
        guard !loadingFinishing, loadingLine.animation(forKey: "sweep") == nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        func keyframes(_ keyPath: String, _ values: [CGFloat]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = [0, NSNumber(value: AppDelegate.loadingArrival), 1]
            animation.calculationMode = .linear
            return animation
        }
        let sweep = CAAnimationGroup()
        sweep.animations = [keyframes("strokeEnd", [0, 1, 1]), keyframes("strokeStart", [0, 0.72, 1])]
        sweep.duration = AppDelegate.loadingCycle
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        loadingStarted = CACurrentMediaTime()
        loadingLine.add(sweep, forKey: "sweep")
    }
    // Waits for the light to reach the right side, so even an instant start shows one full sweep.
    private func finishLoadingWhenConnected() {
        guard startupLoading, !loadingFinishing, connectionProblem != "Starting…" else { return }
        loadingFinishing = true
        var delay: CFTimeInterval = 0
        if !expanded, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, loadingLine.animation(forKey: "sweep") != nil {
            let arrival = AppDelegate.loadingCycle * AppDelegate.loadingArrival
            let elapsed = (CACurrentMediaTime() - loadingStarted).truncatingRemainder(dividingBy: AppDelegate.loadingCycle)
            delay = elapsed <= arrival ? arrival - elapsed : AppDelegate.loadingCycle - elapsed + arrival
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.settleLoadingLine() }
    }
    // The light gathers into the resting line's spot, then becomes that line and takes its color.
    private func settleLoadingLine() {
        let screen = island.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let layout = IslandLayout(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                                  leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea,
                                  expanded: false, content: .loading)
        let tail = loadingLine.presentation()?.strokeStart ?? 0
        loadingLine.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loadingLine.strokeStart = tail
        loadingLine.strokeEnd = 1
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.loadingLine.opacity = 0
            self.statusLine.frame = layout.lineFrame
            self.statusLine.cornerRadius = 1.5
            self.statusLine.opacity = 1
            CATransaction.commit()
            for keyPath in ["backgroundColor", "shadowColor"] {
                let color = CABasicAnimation(keyPath: keyPath)
                color.fromValue = NSColor.white.cgColor
                color.duration = 0.7
                color.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.statusLine.add(color, forKey: "arrive-\(keyPath)")
            }
            self.startupLoading = false
            self.loadingFinishing = false
            self.layoutIsland()
        }
        loadingLine.strokeStart = 1 - layout.loadingLineFraction
        CATransaction.commit()
    }
    // The resting line, breathing while idle. The spring takes over from here while awake.
    private func updateSignal(content: IslandContent, layout: IslandLayout) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(reduceMotion)
        CATransaction.setAnimationDuration(expanded ? 0.18 : 0.26)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        // It autoresizes with the window, so match the size now rather than the target,
        // or the coming resize is applied twice and clips the line.
        signalHost.frame = islandView.bounds
        signalHost.layer?.cornerRadius = layout.cornerRadius
        statusLine.frame = layout.lineFrame
        statusLine.cornerRadius = min(layout.lineFrame.width, layout.lineFrame.height) / 2
        statusLine.opacity = content == .audio || content == .loading || (expanded && content == .idle) ? 0 : 1
        sensingLine.opacity = 0
        sensingEye.opacity = 0
        CATransaction.commit()
        guard content == .idle, !expanded, !reduceMotion else { statusLine.removeAnimation(forKey: "pulse"); return }
        guard statusLine.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1; pulse.toValue = 0.4
        pulse.duration = 1.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        statusLine.add(pulse, forKey: "pulse")
    }
    private func startFrames() {
        guard frameTimer == nil else { return }
        statusLine.removeAnimation(forKey: "pulse")
        lastFrame = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stepFrame() }
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func stopFrames() { frameTimer?.invalidate(); frameTimer = nil }
    private func stepFrame() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastFrame, 1.0 / 30))
        lastFrame = now
        updatePointer()
        guard frameTimer != nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { wake.jump(to: wake.target) } else {
            wake.step(dt)
            signalBar.step(dt, pointer: (NSEvent.mouseLocation.x - island.frame.midX) / max(island.frame.width / 2, 1))
        }
        applyWake()
        stepGoo(dt)
        if wake.isSettled, wake.value == 0, liquid.isSettled {
            stopFrames()
            layoutIsland()
        }
    }
    // One value drives the whole transition, so window, shape and line never drift apart.
    // The upright line shrinks to a bead and glides under the camera, where it spreads out.
    private func applyWake() {
        guard let rest = wakeEnds?.rest, let awake = wakeEnds?.awake else { return }
        let t = max(wake.value, 0)
        let frame = mix(rest.frame, awake.frame, t)
        if frame != island.frame { island.setFrame(frame, display: true) }
        signalHost.frame = NSRect(origin: .zero, size: frame.size)
        let bead = smoothstep(0, 0.5, t), spread = smoothstep(0.3, 1, t)
        let restLine = rest.lineFrame.offsetBy(dx: rest.frame.minX - frame.minX, dy: rest.frame.minY - frame.minY)
        let awakeLine = awake.lineFrame.offsetBy(dx: awake.frame.minX - frame.minX, dy: awake.frame.minY - frame.minY)
        let width = mix(restLine.width, 6, bead), height = mix(restLine.height, awakeLine.height, bead)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = mix(rest.cornerRadius, awake.cornerRadius, min(t, 1))
        islandView.layer?.cornerRadius = radius
        signalHost.layer?.cornerRadius = radius
        statusLine.frame = NSRect(x: mix(restLine.midX, awakeLine.midX, bead) - width / 2, y: mix(restLine.midY, awakeLine.midY, bead) - height / 2, width: width, height: height)
        statusLine.cornerRadius = min(width, height) / 2
        statusLine.opacity = Float(1 - smoothstep(0.45, 0.75, t))
        // The bars spread out of the bead, from the middle of the line.
        let bars = signalBar.bars(line: awakeLine, room: (awake.frame.width - awake.lineFrame.width) / 2)
        for (layer, bar) in [(sensingLine, bars.left), (sensingEye, bars.right)] {
            let barWidth = mix(8, bar.width, spread)
            layer.frame = NSRect(x: mix(awakeLine.midX, bar.midX, spread) - barWidth / 2, y: bar.minY, width: barWidth, height: bar.height)
            layer.cornerRadius = bar.height / 2
            layer.opacity = Float(smoothstep(0.4, 0.75, t))
        }
        CATransaction.commit()
    }
    private func stepGoo(_ dt: CGFloat) {
        guard wakeEnds?.rest.isNotched == true else { return }
        let outline = IslandOutline(rect: island.frame)
        let pointer = NSEvent.mouseLocation
        liquid.step(dt, outline: outline, pointer: pointerOnIsland ? pointer : nil)
        drawGoo(outline: outline)
    }
    private func drawGoo(outline: IslandOutline) {
        let bounds = gooPanel.frame
        let toPanel = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        let shoulders = CGMutablePath()
        shoulders.addPath(GooShape.shoulders(rect: outline.rect, radius: mix(8, 16, min(max(wake.value, 0), 1))), transform: toPanel)
        let drawn = liquid.render(island: outline.rect, cornerRadius: islandView.layer?.cornerRadius ?? 10, scale: gooPanel.backingScaleFactor, clip: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gooFill.frame = CGRect(origin: .zero, size: bounds.size)
        gooFill.path = shoulders
        gooLiquid.contents = drawn?.image
        if let frame = drawn?.frame { gooLiquid.frame = frame.applying(toPanel) }
        CATransaction.commit()
    }
    @objc private func reposition() { setExpanded(expanded, animated: false); positionOverlay() }
    private func positionOverlay() {
        let screen = island?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let w = min(950, area.width - 64), h = min(650, area.height - 150)
        overlay?.setFrame(NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h), display: true)
    }
    private func setStatus(_ text: String) {
        let text = text == "Ready" ? connectionProblem ?? text : text
        currentStatus = text
        statusLabel.stringValue = text
        let working = ["Thinking", "Drawing", "Speaking", "Listening", "Proofreading", "Rewriting"].contains { text.contains($0) }
        let problem = text == connectionProblem || text.contains("failed") || text.contains("unavailable")
        activityMark.active = talking
        statusLabel.toolTip = text
        statusLabel.textColor = problem ? coral : .white
        let lineColor = (connectionProblem == nil && !working && !problem ? signalGreen : coral).cgColor
        statusLine.backgroundColor = lineColor
        statusLine.shadowColor = lineColor
        // One-off notices fade back to the line; while the composer is open they wait for it to close.
        settleTimer?.invalidate(); settleTimer = nil
        if text != "Ready" && text != connectionProblem && !working && !busy && !talking {
            settleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.setStatus(self.expanded ? self.currentStatus : "Ready")
            }
        }
        layoutIsland()
    }
    private func setConnection(_ problem: String?) {
        guard problem != connectionProblem else { return }
        let resting = connectionProblem ?? "Ready"
        connectionProblem = problem
        if currentStatus == resting { setStatus("Ready") }
        finishLoadingWhenConnected()
    }
    private func showError(_ text: String) {
        setStatus(text)
        setExpanded(true)
        showCaption(text)
    }
    private func showCaption(_ text: String) {
        let screen = island.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let width = min(860, screen.visibleFrame.width - 80)
        let trimmed = String(text.prefix(500))
        let estimated = (trimmed as NSString).boundingRect(with: NSSize(width: width - 36, height: 100), options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 16)]).height
        let height = min(100, max(42, ceil(estimated) + 24))
        captions.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.visibleFrame.minY + 24, width: width, height: height), display: true)
        captionText.frame = NSRect(x: 18, y: 12, width: width - 36, height: height - 24)
        captionText.stringValue = trimmed
        captions.orderFrontRegardless()
    }
    @objc private func toggleVoice() {
        voiceEnabled.toggle()
        voiceButton.title = voiceEnabled ? "Voice on" : "Voice off"
        voiceButton.image = NSImage(systemSymbolName: voiceEnabled ? "speaker.wave.2" : "speaker.slash", accessibilityDescription: voiceButton.title)
        voiceButton.contentTintColor = voiceEnabled ? .systemBlue : NSColor(white: 0.6, alpha: 1)
        voiceButton.toolTip = voiceEnabled ? "Spoken replies on · click to mute" : "Spoken replies off · click to enable"
        voiceButton.setAccessibilityLabel(voiceButton.title)
        webView?.evaluateJavaScript("window.clippyVoice?.setMuted(\(!voiceEnabled)); void 0;")
        if !voiceEnabled { speech.stopSpeaking(at: .immediate) }
    }
    @objc private func hideVisuals() {
        overlay.ignoresMouseEvents = true
        if voiceRequested {
            // Keep WebKit's live media document visible while hiding its marks.
            webView.evaluateJavaScript("document.getElementById('overlay').hidden = true; void 0;")
        } else { overlay.orderOut(nil) }
        captions.orderOut(nil); speech.stopSpeaking(at: .immediate)
    }
    @objc private func showLastVisual() {
        if let previous {
            render(previous)
            // Only this explicit user action moves keyboard focus to a drawing.
            overlay.makeKeyAndOrderFront(nil)
        }
    }
    @objc private func newConversation() {
        stopRealtimeVoice()
        webView.evaluateJavaScript("window.clippyVoice?.setVisual(null); void 0;")
        cancelRequest()
        stopDictation(sendTranscript: false)
        hideVisuals()
        history = []
        previous = nil
        attachedImage = nil
        captureButton.title = "Screen"
        prompt.stringValue = ""
        setStatus("Ready")
    }

    @objc private func providerChanged() { setProvider(providerControl.indexOfSelectedItem == 1 ? .claude : .gpt) }
    private func mascot(_ name: String, description: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"), let source = NSImage(contentsOf: url) else { return nil }
        let height: CGFloat = 24, size = NSSize(width: height * source.size.width / max(source.size.height, 1), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.accessibilityDescription = description
        return image
    }
    private func updateProviderControl() {
        providerControl.selectItem(at: provider == .claude ? 1 : 0)
        modelCaption.stringValue = provider == .claude ? "Claude · …" : "GPT · …"
    }
    private func updateModelCaption(_ status: [String: Any]) {
        guard status["provider"] as? String == provider.rawValue,
              let model = status["model"] as? String,
              let effort = status["reasoningEffort"] as? String else { return }
        let name = ["gpt-6.1-terra": "GPT-6.1 Terra", "claude-sonnet-5-5": "Claude Sonnet 5.5"][model] ?? model
        modelCaption.stringValue = "\(name) · \(effort.capitalized) effort"
    }
    // Remembered across launches, and applies to the next question.
    private func setProvider(_ value: AIProvider) {
        guard value != provider else { return }
        provider = value
        updateProviderControl()
        UserDefaults.standard.set(value.rawValue, forKey: "aiProvider")
        // Talk itself stays on OpenAI's voice API, but its drawings follow the selected model.
        webView?.evaluateJavaScript("window.clippyVoice?.setProvider('\(value.rawValue)'); void 0;")
        // Each backend has its own sign-in, which decides whether the line can be green.
        pollServer()
    }
    private var statusURL: URL { URL(string: "api/status?provider=\(provider.rawValue)", relativeTo: baseURL)!.absoluteURL }
    private func checkServer(startIfNeeded: Bool, retries: Int = 12) {
        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], value["model"] != nil {
                    self.updateModelCaption(value)
                    self.setConnection(value["authenticated"] as? Bool == true ? nil : self.provider.signInRequired)
                    self.webView.load(URLRequest(url: baseURL.appendingPathComponent("overlay.html")))
                    self.startHealthMonitor()
                } else if startIfNeeded && error != nil {
                    self.launchServer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.checkServer(startIfNeeded: false, retries: retries) }
                } else if error != nil && retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.checkServer(startIfNeeded: false, retries: retries - 1) }
                } else {
                    self.setConnection(serverUnavailable)
                    self.showError("Local server unavailable. Run npm start in the Clippy project.")
                    self.startHealthMonitor()
                }
            }
        }.resume()
    }
    // Keeps the green dot honest: it only stays green while the server still answers.
    private func startHealthMonitor() {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.pollServer() }
    }
    private func pollServer() {
        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], value["model"] != nil else {
                    self.setConnection(serverUnavailable); return
                }
                self.updateModelCaption(value)
                if value["authenticated"] as? Bool != true { self.setConnection(self.provider.signInRequired) }
                else { self.setConnection(self.overlayReady ? nil : drawingUnavailable) }
                if !self.overlayReady { self.webView.load(URLRequest(url: baseURL.appendingPathComponent("overlay.html"))) }
            }
        }.resume()
    }
    private func launchServer() {
        guard ownedServer == nil, let file = Bundle.main.url(forResource: "runtime", withExtension: "json"), let data = try? Data(contentsOf: file), let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: String], let node = config["node"], let project = config["project"] else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [project + "/server/index.mjs"]
        process.currentDirectoryURL = URL(fileURLWithPath: project)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let codex = config["codex"] { env["CLIPPY_CODEX_BIN"] = codex }
        if let claude = config["claude"], !claude.isEmpty { env["CLIPPY_CLAUDE_BIN"] = claude }
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); ownedServer = process; setStatus("Starting…") }
        catch { showError("Could not start the local server. Run npm start in Terminal.") }
    }
    @objc private func sendOrCancel() { if busy { cancelRequest() } else { sendPrompt() } }
    @objc private func sendPrompt() {
        let message = prompt.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { island.makeKey(); island.makeFirstResponder(prompt); return }
        guard message.count <= 6000 else { showError("Keep the question under 6,000 characters."); return }
        generate(message)
    }
    private func generate(_ message: String) {
        guard !busy else { return }
        if voiceRequested { stopRealtimeVoice() }
        stopDictation(sendTranscript: false)
        speech.stopSpeaking(at: .immediate)
        busy = true
        sendButton.title = ""
        sendButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel request")
        sendButton.setAccessibilityLabel("Cancel request")
        sendButton.toolTip = "Cancel request"
        requestGeneration += 1
        let generation = requestGeneration
        pendingMessage = message
        setStatus("Thinking…")
        responseBuffer = Data()
        responseStatus = 200
        resultReceived = false
        let tokenRequest = URLRequest(url: baseURL.appendingPathComponent("api/session"), timeoutInterval: 10)
        requestTask = URLSession.shared.dataTask(with: tokenRequest) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self, self.requestGeneration == generation else { return }
                guard error == nil, let data, let tokenData = (try? JSONSerialization.jsonObject(with: data)) as? [String: String], let token = tokenData["token"] else {
                    self.finishRequest(); self.showError("Cannot connect to the local Codex server. Try reopening Clippy."); return
                }
                var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"), timeoutInterval: 135)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(token, forHTTPHeaderField: "X-Clippy-Session")
                let body: [String: Any] = ["message": message, "tier": "fast", "provider": self.provider.rawValue, "history": Array(self.history.suffix(12)), "previous": self.previous as Any? ?? NSNull(), "image": self.attachedImage as Any? ?? NSNull()]
                guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { self.finishRequest(); self.showError("Could not prepare the request."); return }
                request.httpBody = encoded
                self.requestTask = self.streamingSession.dataTask(with: request)
                self.requestTask?.resume()
            }
        }
        requestTask?.resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === requestTask else { completionHandler(.cancel); return }
        responseStatus = (response as? HTTPURLResponse)?.statusCode ?? 500
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === requestTask else { return }
        responseBuffer.append(data)
        guard responseBuffer.count < 2_000_000 else { cancelRequest(); showError("The server response was too large."); return }
        if responseStatus >= 400 { return }
        while let newline = responseBuffer.firstIndex(of: 10) {
            let line = responseBuffer.prefix(upTo: newline)
            responseBuffer.removeSubrange(...newline)
            if let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { handle(event) }
        }
    }
    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "status": setStatus(event["message"] as? String ?? "Thinking…")
        case "preview":
            guard let result = event["result"] as? [String: Any] else { return }
            previewVisible = true
            render(result, preview: true)
            setStatus("Drawing…")
        case "error":
            rollbackPreview()
            resultReceived = true
            showError(event["message"] as? String ?? "Codex could not finish. Try again.")
        case "result":
            guard let result = event["result"] as? [String: Any], let reply = result["reply"] as? String else { showError("Invalid visual response."); return }
            resultReceived = true
            previewVisible = false
            previous = result
            history.append(["role": "user", "content": String(pendingMessage.prefix(4000))])
            history.append(["role": "assistant", "content": String(reply.prefix(4000))])
            history = Array(history.suffix(12))
            attachedImage = nil
            captureButton.title = "Screen"
            prompt.stringValue = ""
            render(result)
            setExpanded(false)
            setStatus("Ready")
            if voiceEnabled { speak(reply) }
        default: break
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === requestTask else { return }
        let received = resultReceived
        let status = responseStatus
        let body = responseBuffer
        finishRequest()
        if !received { rollbackPreview() }
        if status >= 400 {
            let value = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            showError(value?["error"] as? String ?? "Local server returned error \(status).")
        } else if let error { showError(error.localizedDescription) }
        else if !received { showError("Codex ended without a visual. Try again.") }
    }
    private func finishRequest() {
        busy = false; requestTask = nil; sendButton.title = ""
        sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send")
        sendButton.toolTip = "Send · Return"
        sendButton.setAccessibilityLabel("Send")
    }
    private func cancelRequest() {
        rollbackPreview()
        requestGeneration += 1
        requestTask?.cancel()
        finishRequest()
        setStatus("Ready")
    }

    private func rollbackPreview() {
        guard previewVisible else { return }
        previewVisible = false
        let json = previous.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        webView.evaluateJavaScript("window.clippyRollback(\(json)); void 0;")
        if let previous { render(previous) } else if !voiceRequested { overlay.orderOut(nil) }
    }
    private func render(_ result: [String: Any], preview: Bool = false) {
        if overlayReady, let data = try? JSONSerialization.data(withJSONObject: result), let json = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript("window.clippyRender(\(json), \(preview)); \(preview ? "" : "window.clippyVoice?.setVisual(\(json));") void 0;") { [weak self] _, error in
                if error != nil { self?.showError("Drawing renderer unavailable. Reopen Clippy after starting the server.") }
            }
        }
        overlay.orderFrontRegardless()
        if !preview, let reply = result["reply"] as? String { showCaption(reply) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { /* The module sends ready after clippyRender exists. */ }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let allowed = voiceRequested && frame.isMainFrame && type == .microphone && origin.protocol == "http" && origin.host == "127.0.0.1" && origin.port == 4317
        decisionHandler(allowed ? .grant : .deny)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { overlayReady = false; setConnection(drawingUnavailable) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.scheme == "http" && url?.host == "127.0.0.1" && url?.port == 4317 ? .allow : .cancel)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "http", origin.host == "127.0.0.1", origin.port == 4317, let data = message.body as? [String: Any], let action = data["action"] as? String else { return }
        switch action {
        case "ready":
            overlayReady = true
            if connectionProblem == drawingUnavailable { setConnection(nil) }
            if let previous { render(previous) }
        case "followup": if let text = data["text"] as? String, !text.isEmpty, text.count <= 6000 { generate(text) }
        case "closeOverlay": hideVisuals()
        case "dragOverlay": if let event = NSApp.currentEvent { overlay.performDrag(with: event) }
        case "dictate": startDictation()
        case "stopDictation": stopDictation(sendTranscript: true)
        case "speak": if let text = data["text"] as? String, text.count < 12000 { speak(text) }
        case "stopSpeaking": speech.stopSpeaking(at: .immediate)
        case "voiceState":
            guard data["generation"] as? Int == voiceGeneration else { return }
            guard let state = data["state"] as? String else { return }
            let text = String((data["message"] as? String ?? "").prefix(1500))
            if state == "ended" || state == "error" {
                voiceRequested = false; updateTalkButton()
                if state == "error" { showError(text) } else { setStatus(text.isEmpty ? "Ready" : text) }
            } else if voiceRequested {
                if state == "transcript" { showCaption(text) } else { setStatus(text) }
            }
        case "voicePreview":
            if voiceRequested, data["generation"] as? Int == voiceGeneration { overlay.orderFrontRegardless() }
        case "voiceVisual":
            if voiceRequested, data["generation"] as? Int == voiceGeneration, let result = data["result"] as? [String: Any], result["scene"] != nil, result["diagram"] != nil {
                previous = result; render(result)
            }
        default: break
        }
    }
    @objc private func toggleRealtimeVoice() {
        if voiceRequested { stopRealtimeVoice(); return }
        guard overlayReady else { showError("Wait for the drawing view to finish loading, then try Talk."); return }
        cancelRequest(); stopDictation(sendTranscript: false); speech.stopSpeaking(at: .immediate)
        voiceRequested = true; voiceGeneration += 1
        overlay.orderFrontRegardless()
        let generation = voiceGeneration
        updateTalkButton(); setStatus("Connecting live voice…")
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.voiceRequested, self.voiceGeneration == generation else { return }
                guard granted else {
                    self.voiceRequested = false; self.updateTalkButton()
                    self.showError("Allow Clippy microphone access in Privacy & Security to use Talk."); return
                }
                self.webView.evaluateJavaScript("window.clippyVoice.setMuted(\(!self.voiceEnabled)); window.clippyVoice.setProvider('\(self.provider.rawValue)'); window.clippyVoice.start(\(generation)); void 0;") { [weak self] _, error in
                    guard let self, self.voiceGeneration == generation else { return }
                    if error != nil { self.stopRealtimeVoice(); self.showError("Live voice could not start. Reopen Clippy and try again.") }
                }
            }
        }
    }
    private func updateTalkButton() {
        talkButton.title = voiceRequested ? "End" : "Talk"
        talkButton.image = NSImage(systemSymbolName: voiceRequested ? "stop.circle" : "waveform", accessibilityDescription: talkButton.title)
        talkButton.contentTintColor = voiceRequested ? coral : NSColor(white: 0.76, alpha: 1)
        talkButton.setAccessibilityLabel(voiceRequested ? "End live voice" : "Start live voice")
    }
    private func stopRealtimeVoice() {
        voiceGeneration += 1; voiceRequested = false; updateTalkButton()
        webView?.evaluateJavaScript("window.clippyVoice?.stop(); void 0;")
        setStatus("Ready")
    }
    private func speak(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard let voice = voices.first(where: { $0.language == Locale.current.identifier.replacingOccurrences(of: "_", with: "-") }) ?? voices.first(where: { $0.language.hasPrefix("en") }) ?? voices.first else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        speech.speak(utterance)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { if !busy { setStatus("Speaking") } }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { if !busy && currentStatus == "Speaking" { setStatus("Ready") } }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { if !busy && !recording && currentStatus == "Speaking" { setStatus("Ready") } }

    @objc private func captureScreen() {
        guard !busy else { return }
        if attachedImage != nil { attachedImage = nil; captureButton.title = "Screen"; setStatus("Screen removed"); return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { showError("Allow Screen Recording in System Settings, then reopen Clippy to attach a screenshot."); return }
        let overlayVisible = overlay.isVisible, captionsVisible = captions.isVisible
        island.orderOut(nil); notchBridge.orderOut(nil); gooPanel.orderOut(nil); hideDwellRing(); overlay.orderOut(nil); captions.orderOut(nil)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-\(UUID().uuidString).png")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-t", "png", "-D", "1", target.path]
            process.standardError = FileHandle.nullDevice
            var bytes: Data?
            do { try process.run(); process.waitUntilExit(); if process.terminationStatus == 0 { bytes = try Data(contentsOf: target) } } catch { }
            try? FileManager.default.removeItem(at: target)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setExpanded(true)
                if overlayVisible { self.overlay.orderFrontRegardless() }
                if captionsVisible { self.captions.orderFrontRegardless() }
                guard let bytes, let image = NSImage(data: bytes), let bitmap = self.thumbnail(image) else { self.showError("Screen capture failed. Check Screen Recording permission."); return }
                self.attachedImage = "data:image/png;base64," + bitmap.base64EncodedString()
                if self.voiceRequested, let image = self.attachedImage {
                    self.webView.callAsyncJavaScript("await window.clippyVoice.shareScreen(image)", arguments: ["image": image], in: nil, in: .page) { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .success: self.attachedImage = nil; self.captureButton.title = "Screen"; self.setStatus("Screen shared · ask your question")
                        case .failure: self.captureButton.title = "Remove screen"; self.showError("Screen attached for a typed question; live sharing failed.")
                        }
                    }
                    return
                }
                self.captureButton.title = "Remove screen"
                self.setStatus("Screen attached · sent only with your next question")
            }
        }
    }
    private func thumbnail(_ image: NSImage) -> Data? {
        for longest in [1600.0, 1200.0, 900.0] {
            let factor = min(1, longest / max(image.size.width, image.size.height))
            let size = NSSize(width: max(1, image.size.width * factor), height: max(1, image.size.height * factor))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            if let data = bitmap.representation(using: .png, properties: [:]), data.count < 5_000_000 { return data }
        }
        return nil
    }
    @objc private func toggleDictation() { if recording { stopDictation(sendTranscript: true) } else { startDictation() } }
    private func startDictation() {
        if voiceRequested { stopRealtimeVoice() }
        guard !busy && !recording && !requestingPermission else { return }
        guard let candidate = SFSpeechRecognizer(locale: Locale.current), candidate.supportsOnDeviceRecognition, candidate.isAvailable else { showError("On-device dictation unavailable for this Mac or language. Type instead."); return }
        recognizer = candidate
        requestingPermission = true
        permissionGeneration += 1
        let generation = permissionGeneration
        setStatus("Allow speech and microphone access")
        SFSpeechRecognizer.requestAuthorization { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.permissionGeneration == generation else { return }
                guard result == .authorized else { self.requestingPermission = false; self.showError("Speech permission denied. Enable it in Privacy & Security, or type instead."); return }
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self, self.permissionGeneration == generation else { return }
                        self.requestingPermission = false
                        guard granted else { self.showError("Microphone permission denied. Enable it in Privacy & Security, or type instead."); return }
                        self.beginRecording()
                    }
                }
            }
        }
    }
    private func beginRecording() {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { return }
        speech.stopSpeaking(at: .immediate)
        recognitionGeneration += 1
        let generation = recognitionGeneration
        latestTranscript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else { showError("No working microphone found."); return }
        recognitionRequest = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        audioEngine.prepare()
        do { try audioEngine.start() } catch { input.removeTap(onBus: 0); recognitionRequest = nil; showError("Could not start microphone."); return }
        recording = true
        micButton.title = "Stop"
        micButton.contentTintColor = coral
        micButton.setAccessibilityLabel("Stop dictation")
        setStatus("Listening on-device…")
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.recording, self.recognitionGeneration == generation else { return }
                if let result { self.latestTranscript = result.bestTranscription.formattedString; self.prompt.stringValue = String(self.latestTranscript.prefix(6000)) }
                if result?.isFinal == true { self.stopDictation(sendTranscript: true) }
                else if error != nil { self.stopDictation(sendTranscript: false); self.showError("On-device dictation stopped. Try again or type; no cloud fallback is used.") }
            }
        }
        recognitionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in self?.stopDictation(sendTranscript: true) }
    }
    private func stopDictation(sendTranscript: Bool) {
        permissionGeneration += 1; requestingPermission = false
        guard recording else { return }
        recording = false; recognitionGeneration += 1
        recognitionTimer?.invalidate(); recognitionTimer = nil
        audioEngine.stop(); audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio(); recognitionTask?.cancel()
        recognitionTask = nil; recognitionRequest = nil
        micButton.title = "Mic"
        micButton.contentTintColor = NSColor(white: 0.76, alpha: 1)
        micButton.setAccessibilityLabel("Dictate")
        if sendTranscript {
            prompt.stringValue = String(latestTranscript.prefix(6000))
            setStatus("Review your words, then Send")
        } else { setStatus("Dictation stopped") }
        latestTranscript = ""
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard voiceRequested else { return .terminateNow }
        stopRealtimeVoice()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        selectionEditor.cancel()
        for key in editingHotKeys { UnregisterEventHotKey(key) }
        hitTestTimer?.invalidate()
        hitTestTimer = nil
        healthTimer?.invalidate(); settleTimer?.invalidate(); frameTimer?.invalidate(); composerTimer?.invalidate()
        cancelRequest(); stopDictation(sendTranscript: false); speech.stopSpeaking(at: .immediate)
        if let monitor = keyboardMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let server = ownedServer, server.isRunning { server.terminate() }
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

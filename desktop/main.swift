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
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 0)).fill()
        for i in 0..<4 {
            let height: CGFloat = active ? 4 + abs(sin(phase + CGFloat(i) * 0.85)) * 10 : [5, 10, 13, 7][i]
            NSColor.white.withAlphaComponent(active ? 1 : 0.8).setFill()
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
    private var replyCard: ReplyCard!
    private var captionDismissed = false
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
    private let composerSignal = ComposerSignal(frame: ComposerSignal.stripFrame)
    private var signalTask: URLSessionDataTask?
    private var signalGeneration = 0
    private var signalState = ""
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
    private var selectionIndicator: NSTextField!
    private var screenshotIndicator: NSTextField!
    private var captureInProgress = false
    private var selectionReadGeneration = 0
    private var selectionReadPending = false
    private var selectionOwnsOpening = false
    private let selectionReadQueue = DispatchQueue(label: "clippy.selection-summary", qos: .userInitiated)
    private var expandedControls = [NSView]()
    private var sendButton: NSButton!
    private var sendHovered = false
    private var micButton: NSButton!
    private var talkButton: NSButton!
    private var voiceRequested = false
    private var voiceGeneration = 0
    private var captureButton: NSButton!
    private var voiceButton: NSButton!
    private var providerControl: NSButton!
    private var modelCaption: NSButton!
    private var compareBoth = UserDefaults.standard.bool(forKey: "chatCompareBoth")
    private var pendingComparison = false
    private lazy var comparisonPanel: ComparisonPanel = {
        let panel = ComparisonPanel()
        panel.onCancel = { [weak self] in self?.cancelRequest(); self?.selectionEditor.cancel() }
        return panel
    }()
    private var chatProvider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "chatProvider") ?? UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .gpt
    private lazy var chatSettings = ChatPreferences(models: DrawingModel.bundled(resource: "chat-models"))
    private var autoRouteCaption: String?
    private var lastRequestMode = "draw"
    private var pendingRequestMode = "chat"
    private lazy var drawingSettings = DrawingPreferences(models: DrawingModel.bundled())
    private var modelHoverStarted: TimeInterval?
    private var modelMenuLatched = false
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
    private lazy var selectionEditor = SelectionEditor(provider: { [weak self] in self?.compareBoth == true ? "both" : self?.chatProvider.rawValue ?? "gpt" }) { [weak self] text in self?.setStatus(text) }
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
        selectionEditor.onComparisonStart = { [weak self] in
            if self?.busy == true { self?.cancelRequest() }
            self?.stopRealtimeVoice(); self?.comparisonPanel.start(editing: true)
        }
        selectionEditor.onComparisonEvent = { [weak self] event in self?.comparisonPanel.receive(event) }
        selectionEditor.onComparisonEnd = { [weak self] reason in self?.comparisonPanel.stop(reason) }
        selectionEditor.onAutomaticActivity = { [weak self] active in
            guard let self, !self.busy else { return }
            self.sendButton.image = NSImage(systemSymbolName: active ? "xmark" : "arrow.up", accessibilityDescription: active ? "Cancel text edit" : "Send")
            self.sendButton.setAccessibilityLabel(active ? "Cancel text edit" : "Send")
            self.sendButton.toolTip = active ? "Cancel text edit" : "Send · Return · automatically choose a visual or text answer"
        }
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
        notchBridge.title = "Clip notch background"
        notchBridge.backgroundColor = .black
        notchBridge.ignoresMouseEvents = true
        notchBridge.setAccessibilityElement(false)
        island.title = "Clip island"
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
        islandView.addSubview(composerSignal)
        expandedControls.append(composerSignal)
        buildGoo()
        prompt = NSTextField(frame: ComposerGeometry.input)
        prompt.placeholderString = ""
        prompt.setAccessibilityLabel("Ask Clip")
        prompt.font = .systemFont(ofSize: 14)
        prompt.textColor = .white
        prompt.isBezeled = false
        prompt.drawsBackground = false
        prompt.focusRingType = .none
        prompt.target = self
        prompt.action = #selector(sendPrompt)
        islandView.addSubview(prompt)
        expandedControls.append(prompt)
        // A quiet baseline, centered under the text field with softly fading ends.
        let promptLine = NSView(frame: NSRect(x: ComposerGeometry.input.midX - 48, y: ComposerGeometry.input.minY - 4, width: 96, height: 0.5))
        let promptGradient = CAGradientLayer()
        promptGradient.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.clear.cgColor]
        promptGradient.startPoint = CGPoint(x: 0, y: 0.5)
        promptGradient.endPoint = CGPoint(x: 1, y: 0.5)
        promptLine.layer = promptGradient
        promptLine.wantsLayer = true
        promptLine.setAccessibilityElement(false)
        islandView.addSubview(promptLine)
        expandedControls.append(promptLine)
        selectionIndicator = NSTextField(labelWithString: "")
        selectionIndicator.frame = ComposerGeometry.selectionIndicator
        selectionIndicator.font = .systemFont(ofSize: 10, weight: .light)
        selectionIndicator.textColor = NSColor.white.withAlphaComponent(0.55)
        selectionIndicator.lineBreakMode = .byTruncatingTail
        selectionIndicator.isHidden = true
        selectionIndicator.toolTip = "Selected text is automatically proofread or rewritten when you open Clip."
        islandView.addSubview(selectionIndicator)
        screenshotIndicator = NSTextField(labelWithString: "")
        screenshotIndicator.frame = ComposerGeometry.screenshotIndicator
        screenshotIndicator.font = .systemFont(ofSize: 9, weight: .light)
        screenshotIndicator.textColor = NSColor.white.withAlphaComponent(0.65)
        screenshotIndicator.alignment = .center
        screenshotIndicator.setAccessibilityLabel("Screenshot status")
        islandView.addSubview(screenshotIndicator)
        expandedControls.append(screenshotIndicator)
        collapseButton = button("Collapse island", frame: ComposerGeometry.collapse, action: #selector(collapseIsland), symbol: "chevron.up", iconOnly: true)
        collapseButton.toolTip = "Make smaller · Esc or ⌃⌥Space"
        modelCaption = NSButton(title: "", target: self, action: #selector(showModelSettings))
        modelCaption.frame = ComposerGeometry.modelCaption
        modelCaption.font = .systemFont(ofSize: 10, weight: .light)
        modelCaption.isBordered = false
        modelCaption.contentTintColor = NSColor.white.withAlphaComponent(0.46)
        modelCaption.toolTip = "Hover or click to choose a model and reasoning effort"
        modelCaption.alignment = .center
        modelCaption.cell?.lineBreakMode = .byTruncatingTail
        islandView.addSubview(modelCaption)
        expandedControls.append(modelCaption)
        captureButton = button("Screen", frame: ComposerGeometry.screen, action: #selector(captureScreen), symbol: "rectangle.dashed", iconOnly: true)
        updateCaptureButton()
        micButton = NSButton(title: "Dictate", target: self, action: #selector(toggleDictation))
        talkButton = button("Talk", frame: ComposerGeometry.talk, action: #selector(toggleRealtimeVoice), symbol: "waveform", iconOnly: true)
        talkButton.toolTip = "Live AI voice · separately billed API usage · click End to stop the microphone"
        voiceButton = button("Voice on", frame: ComposerGeometry.voice, action: #selector(toggleVoice), symbol: "speaker.wave.2", iconOnly: true)
        voiceButton.contentTintColor = .systemBlue
        voiceButton.toolTip = "Spoken replies on · click to mute"
        sendButton = button("Send", frame: ComposerGeometry.send, action: #selector(sendOrCancel), symbol: "arrow.up", iconOnly: true)
        sendButton.layer?.backgroundColor = NSColor.clear.cgColor
        sendButton.layer?.borderWidth = 1
        sendButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.65).cgColor
        sendButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .thin)
        sendButton.contentTintColor = .white
        sendButton.toolTip = "Send · Return · automatically choose a visual or text answer"
        let drawButton = button("Draw", frame: ComposerGeometry.draw, action: #selector(drawPrompt), symbol: "paintbrush.pointed", iconOnly: true)
        drawButton.image = easelIcon()
        drawButton.toolTip = "Draw your prompt · type an idea, then click Draw"
        providerControl = button("Model", frame: ComposerGeometry.provider, action: #selector(providerChanged), symbol: "cpu", iconOnly: true)
        updateProviderControl()
        _ = button("More options", frame: ComposerGeometry.more, action: #selector(showIslandOptions(_:)), symbol: "ellipsis", iconOnly: true)
        setExpanded(false)
    }
    // Liquid can reach past the island, so it has its own click-through panel below it.
    // In the island's window it would block the menu bar.
    private func buildGoo() {
        gooPanel = panel(.zero, level: island.level)
        gooPanel.title = "Clip liquid edge"
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
        dwellPanel.title = "Clip hold timer"
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
        overlay.title = "Clip drawing"
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
    private func updateSendHover(at point: NSPoint?) {
        let hovered = expanded && sendButton.isEnabled && point.map {
            hypot($0.x - ComposerGeometry.send.midX, $0.y - ComposerGeometry.send.midY) <= ComposerGeometry.send.width / 2
        } == true
        guard hovered != sendHovered else { return }
        sendHovered = hovered
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduced ? 0 : 0.18
        let frame = hovered && !reduced ? ComposerGeometry.send.insetBy(dx: -1, dy: -1).offsetBy(dx: 0, dy: 1.5) : ComposerGeometry.send
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sendButton.animator().frame = frame
        }
        CATransaction.begin()
        CATransaction.setDisableActions(reduced)
        CATransaction.setAnimationDuration(duration)
        sendButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(hovered ? 0.11 : 0).cgColor
        sendButton.layer?.borderColor = NSColor.white.withAlphaComponent(hovered ? 1 : 0.65).cgColor
        sendButton.layer?.shadowColor = NSColor.white.cgColor
        sendButton.layer?.shadowOffset = .zero
        sendButton.layer?.shadowRadius = 5
        sendButton.layer?.shadowOpacity = hovered ? 0.2 : 0
        CATransaction.commit()
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
            if menuTrackingDepth == 0 {
                let overCaption = point.map { ComposerGeometry.modelCaption.insetBy(dx: -6, dy: -5).contains($0) } ?? false
                if overCaption && !busy && !modelCaption.isHidden {
                    if modelHoverStarted == nil { modelHoverStarted = now }
                    if !modelMenuLatched, now - (modelHoverStarted ?? now) >= 0.25 {
                        modelMenuLatched = true
                        showModelSettings()
                    }
                } else {
                    modelHoverStarted = nil
                    modelMenuLatched = false
                }
            }
            updateSendHover(at: point)
            composerSurface.updateHover(at: point)
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
        captions.title = "Clip reply"
        captions.ignoresMouseEvents = false
        captions.hasShadow = true
        replyCard = ReplyCard(frame: .zero)
        replyCard.onDismiss = { [weak self] in
            self?.captionDismissed = true; self?.captions.orderOut(nil)
            self?.speech.stopSpeaking(at: .immediate)
        }
        captions.contentView = replyCard
    }
    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Clip")
        let menu = NSMenu()
        for (title, action) in [("Ask Clip  ⌃⌥Space", #selector(toggleIsland)), ("Show last drawing", #selector(showLastVisual)), ("Hide drawings", #selector(hideVisuals)), ("New conversation", #selector(newConversation))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let appRoot = NSMenuItem(title: "Clip", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Clip")
        let showDrawing = appMenu.addItem(withTitle: "Show last drawing", action: #selector(showLastVisual), keyEquivalent: "d")
        showDrawing.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        if changed {
            selectionReadGeneration += 1
            selectionIndicator.isHidden = true
            selectionIndicator.stringValue = ""
            selectionReadPending = false
            selectionOwnsOpening = false
            if value { refreshSelectionIndicator(automatic: focus) }
            else if !compareBoth { selectionEditor.cancelAutomatic() }
        }
        let sourceFrame = island.frame
        let sourceRadius = composerTransitioning ? composerSurface.currentRadius : (islandView.layer?.cornerRadius ?? 10)
        let sourceReveal = composerReveal
        if !value { updateSendHover(at: nil) }
        expanded = value
        if changed {
            if value { composerSignal.signal = signalBar }
            else { signalBar = composerSignal.signal; signalBar.pattern = nil }
            composerSignal.setActive(value)
            signalGeneration += 1
            signalTask?.cancel(); signalTask = nil
            signalState = ""
            if value { refreshComposerSignal() }
        }
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
    private func refreshSelectionIndicator(automatic: Bool) {
        guard let source = NSWorkspace.shared.frontmostApplication,
              source.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            prompt.toolTip = "Selection check · Clip has focus"
            return
        }
        let pid = source.processIdentifier
        let generation = selectionReadGeneration
        selectionReadPending = automatic
        // The request begins before the composer takes keyboard focus.
        selectionReadQueue.async { [weak self] in
            var diagnostic = "No selection"
            let snapshot = SelectionSummary.readSelection(pid: pid) { diagnostic = $0 }
            DispatchQueue.main.async {
                guard let self, self.expanded, self.selectionReadGeneration == generation else { return }
                self.selectionReadPending = false
                self.prompt.toolTip = snapshot == nil ? "Selection check · \(source.localizedName ?? "Source app") · \(diagnostic)" : "Type a prompt"
                if snapshot == nil && diagnostic == "Accessibility access unavailable" {
                    let help = "Enable selected-text access · More → Enable text editing"
                    self.selectionIndicator.stringValue = "Enable selected-text access"
                    self.selectionIndicator.setAccessibilityLabel(help)
                    self.selectionIndicator.isHidden = false
                }
                let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard foreground == pid || foreground == ProcessInfo.processInfo.processIdentifier else {
                    self.selectionOwnsOpening = true // Never steal focus after the user switches apps.
                    return
                }
                if let snapshot, automatic, !self.busy, !self.talking {
                    self.selectionOwnsOpening = true
                    self.selectionEditor.startAutomatic(snapshot)
                } else if automatic && !self.composerTransitioning {
                    self.island.makeKey(); self.island.makeFirstResponder(self.prompt)
                }
                guard let snapshot, let label = SelectionSummary.label(for: SelectionSummary.wordCount(snapshot.text)) else { return }
                let text = NSMutableAttributedString()
                if let image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: nil) {
                    let attachment = NSTextAttachment()
                    attachment.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.55)]))
                    attachment.bounds = NSRect(x: 0, y: -2, width: 12, height: 12)
                    text.append(NSAttributedString(attachment: attachment))
                    text.append(NSAttributedString(string: "  "))
                }
                text.append(NSAttributedString(string: label, attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .light),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.55)]))
                self.selectionIndicator.attributedStringValue = text
                self.selectionIndicator.setAccessibilityLabel(label)
                self.selectionIndicator.isHidden = false
            }
        }
    }

    private func updateNotchBridge(_ layout: IslandLayout) {
        composerSurface.setNotchWidth(layout.notchFrame?.width)
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
        if expanded && focus && !selectionReadPending && !selectionOwnsOpening { island.makeKey(); island.makeFirstResponder(prompt) }
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
        islandView.setAccessibilityLabel("Clip: \(currentStatus)")
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
        let working = ["Checking screen", "Capturing screen", "Choosing edit", "Choosing response", "Choosing model", "Thinking", "Drawing", "Replying", "Explaining", "Summarizing", "Translating", "Solving", "Exploring", "Speaking", "Listening", "Proofreading", "Rewriting"].contains { text.contains($0) }
        let problem = text == connectionProblem || text.contains("failed") || text.contains("unavailable")
        refreshComposerSignal()
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
    private func refreshComposerSignal() {
        guard expanded, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let state = talking ? "speaking" : busy ? "working" : connectionProblem != nil ? "attention" : "ready"
        guard signalState != state else { return }
        signalState = state
        signalGeneration += 1
        let generation = signalGeneration
        signalTask?.cancel()
        let tokenRequest = URLRequest(url: baseURL.appendingPathComponent("api/session"), timeoutInterval: 3)
        signalTask = URLSession.shared.dataTask(with: tokenRequest) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self, self.expanded, self.signalGeneration == generation,
                      let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String], let token = object["token"] else { return }
                var request = URLRequest(url: baseURL.appendingPathComponent("api/signal"), timeoutInterval: 4)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(token, forHTTPHeaderField: "X-Clippy-Session")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["state": state])
                self.signalTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
                    DispatchQueue.main.async {
                        guard let self, self.expanded, self.signalGeneration == generation,
                              (response as? HTTPURLResponse)?.statusCode == 200,
                              let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String], let pattern = object["pattern"] else { return }
                        self.composerSignal.choose(pattern)
                    }
                }
                self.signalTask?.resume()
            }
        }
        signalTask?.resume()
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
    private func showCaption(_ text: String, live: Bool = false) {
        if live && captionDismissed { return }
        if !live { captionDismissed = false }
        guard !text.isEmpty else { captions.orderOut(nil); return }
        let screen = island.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let size = ReplyCardLayout.size(text: text, available: screen.visibleFrame.size)
        captions.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 24, width: size.width, height: size.height), display: true)
        replyCard.show(text, live: live)
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
        screenshotIndicator.stringValue = ""
        updateCaptureButton()
        prompt.stringValue = ""
        setStatus("Ready")
    }

    @objc private func providerChanged() {
        guard !busy, !selectionEditor.automaticRunning else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        for (value, title) in [("gpt", "Codex"), ("claude", "Claude"), ("both", "Both")] {
            let item = NSMenuItem(title: title, action: #selector(selectChatProvider(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value
            item.state = (compareBoth ? value == "both" : !chatSettings.isAuto && value == chatProvider.rawValue) ? .on : .off
            if value == "both" { item.toolTip = "Compare text answers and edits · optional screenshot · no Draw or voice" }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: providerControl.frame.minX, y: providerControl.frame.minY), in: islandView)
    }
    @objc private func selectChatProvider(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String else { return }
        compareBoth = value == "both"; chatSettings.isAuto = false
        UserDefaults.standard.set(compareBoth, forKey: "chatCompareBoth")
        if let selected = AIProvider(rawValue: value) {
            chatProvider = selected; UserDefaults.standard.set(value, forKey: "chatProvider")
        }
        updateProviderControl(); pollServer()
    }
    private func easelIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.white.setStroke()
            let canvas = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 7, width: 13, height: 9), xRadius: 1, yRadius: 1)
            canvas.lineWidth = 1.25
            canvas.stroke()
            let stand = NSBezierPath()
            stand.lineWidth = 1.25
            stand.lineCapStyle = .round
            for (from, to) in [(NSPoint(x: 10, y: 16), NSPoint(x: 10, y: 19)),
                               (NSPoint(x: 2, y: 6), NSPoint(x: 18, y: 6)),
                               (NSPoint(x: 6, y: 6), NSPoint(x: 3, y: 1)),
                               (NSPoint(x: 14, y: 6), NSPoint(x: 17, y: 1)),
                               (NSPoint(x: 10, y: 6), NSPoint(x: 10, y: 2))] {
                stand.move(to: from)
                stand.line(to: to)
            }
            stand.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Draw on an easel"
        return image
    }
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
        let name = compareBoth ? "Both" : chatSettings.isAuto ? "Auto" : chatProvider == .claude ? "Claude" : "Codex"
        providerControl.image = compareBoth ? NSImage(systemSymbolName: "square.split.2x1", accessibilityDescription: "Both providers") : chatSettings.isAuto ? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Auto chat model")
            : mascot(chatProvider == .claude ? "mascot-claude" : "mascot-gpt", description: name)
        providerControl.setAccessibilityLabel("Chat provider: \(name). Choose Codex, Claude or Both")
        providerControl.toolTip = "Chat: \(name) · choose Codex, Claude or Both"
        updateDrawingSettings()
    }
    private func updateDrawingSettings() {
        modelCaption.title = compareBoth ? "Codex + Claude · Text comparison" : chatSettings.isAuto ? autoRouteCaption ?? chatSettings.caption(for: chatProvider.rawValue)
            : chatSettings.caption(for: chatProvider.rawValue)
        modelCaption.setAccessibilityLabel("\(modelCaption.title). Choose chat model and reasoning effort")
        let settings = drawingSettings.request(for: provider.rawValue)
        if let data = try? JSONSerialization.data(withJSONObject: settings), let json = String(data: data, encoding: .utf8) {
            webView?.evaluateJavaScript("window.clippyVoice?.setDrawingSettings(\(json)); void 0;")
        }
    }
    @objc private func showModelSettings() {
        guard expanded, !busy, !composerTransitioning, menuTrackingDepth == 0 else { return }
        modelMenuLatched = true
        composerSurface.updateHover(at: nil)
        let menu = NSMenu(); menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Chat model", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        let auto = NSMenuItem(title: "Auto", action: #selector(selectAutoChat), keyEquivalent: "")
        auto.target = self; auto.state = chatSettings.isAuto ? .on : .off
        auto.toolTip = "Decisions chooses Astra, Terra, Opus or Sonnet and its supported reasoning effort for each chat prompt"
        menu.addItem(auto)
        if compareBoth {
            for p in ["gpt", "claude"] {
                let item = NSMenuItem(title: p == "gpt" ? "Codex model & effort" : "Claude model & effort", action: nil, keyEquivalent: "")
                let choices = NSMenu(); choices.autoenablesItems = false
                addModelOptions(to: choices, chat: true, comparisonProvider: p)
                item.submenu = choices; menu.addItem(item)
            }
        } else { addModelOptions(to: menu, chat: true) }
        menu.addItem(.separator())
        let draw = NSMenuItem(title: "Draw settings", action: nil, keyEquivalent: "")
        let drawMenu = NSMenu(); drawMenu.autoenablesItems = false
        addModelOptions(to: drawMenu, chat: false)
        draw.submenu = drawMenu; menu.addItem(draw)
        menu.popUp(positioning: nil, at: NSPoint(x: modelCaption.frame.minX, y: modelCaption.frame.minY), in: islandView)
    }
    private func addModelOptions(to menu: NSMenu, chat: Bool, comparisonProvider: String? = nil) {
        let settings = chat ? chatSettings.manual : drawingSettings
        let currentProvider = comparisonProvider.flatMap { AIProvider(rawValue: $0) } ?? (chat ? chatProvider : provider)
        let current = settings.model(for: currentProvider.rawValue)
        for model in settings.models where comparisonProvider == nil || model.provider == comparisonProvider {
            let item = NSMenuItem(title: model.name, action: chat ? #selector(selectChatModel(_:)) : #selector(selectDrawingModel(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = model.id
            item.state = current.id == model.id && (!chat || !chatSettings.isAuto) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let heading = NSMenuItem(title: chat && chatSettings.isAuto ? "Reasoning: Auto (Decisions)" : "Reasoning effort", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        if chat && chatSettings.isAuto { return }
        for effort in current.efforts {
            let item = NSMenuItem(title: DrawingPreferences.effortTitle(effort), action: chat ? #selector(selectChatEffort(_:)) : #selector(selectDrawingEffort(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = comparisonProvider.map { "\($0):\(effort)" } ?? effort
            item.state = settings.effort(for: currentProvider.rawValue) == effort ? .on : .off
            menu.addItem(item)
        }
    }
    @objc private func selectAutoChat() {
        compareBoth = false; UserDefaults.standard.set(false, forKey: "chatCompareBoth")
        chatSettings.isAuto = true; autoRouteCaption = nil
        updateProviderControl(); pollServer()
    }
    @objc private func selectChatModel(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              let model = chatSettings.manual.models.first(where: { $0.id == id }),
              let selected = AIProvider(rawValue: model.provider) else { return }
        chatSettings.isAuto = false; chatProvider = selected
        chatSettings.manual.select(model: id, provider: model.provider)
        UserDefaults.standard.set(model.provider, forKey: "chatProvider")
        updateProviderControl(); pollServer()
    }
    @objc private func selectChatEffort(_ item: NSMenuItem) {
        guard let effort = item.representedObject as? String, !chatSettings.isAuto else { return }
        let parts = effort.split(separator: ":").map(String.init)
        chatSettings.manual.select(effort: parts.last ?? effort, provider: parts.count == 2 ? parts[0] : chatProvider.rawValue)
        updateDrawingSettings()
    }
    @objc private func selectDrawingModel(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              let model = drawingSettings.models.first(where: { $0.id == id }),
              let selected = AIProvider(rawValue: model.provider) else { return }
        drawingSettings.select(model: id, provider: model.provider)
        setProvider(selected); updateDrawingSettings()
    }
    @objc private func selectDrawingEffort(_ item: NSMenuItem) {
        guard let effort = item.representedObject as? String else { return }
        drawingSettings.select(effort: effort, provider: provider.rawValue)
        updateDrawingSettings()
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
    private var statusURL: URL { URL(string: "api/status?provider=\(compareBoth ? "both" : chatSettings.isAuto ? "auto" : chatProvider.rawValue)", relativeTo: baseURL)!.absoluteURL }
    private func checkServer(startIfNeeded: Bool, retries: Int = 12) {
        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], value["model"] != nil {
                    self.setConnection(value["authenticated"] as? Bool == true ? nil : self.compareBoth ? "Sign in to Codex and Claude for Both" : self.chatSettings.isAuto ? "Sign in to Codex or Claude for Auto" : self.chatProvider.signInRequired)
                    self.webView.load(URLRequest(url: baseURL.appendingPathComponent("overlay.html")))
                    self.startHealthMonitor()
                } else if startIfNeeded && error != nil {
                    self.launchServer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.checkServer(startIfNeeded: false, retries: retries) }
                } else if error != nil && retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.checkServer(startIfNeeded: false, retries: retries - 1) }
                } else {
                    self.setConnection(serverUnavailable)
                    self.showError("Local server unavailable. Run npm start in the Clip project.")
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
                if value["authenticated"] as? Bool != true { self.setConnection(self.compareBoth ? "Sign in to Codex and Claude for Both" : self.chatSettings.isAuto ? "Sign in to Codex or Claude for Auto" : self.chatProvider.signInRequired) }
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
    @objc private func sendOrCancel() { if selectionEditor.automaticRunning { cancelTextEdit() } else if busy { cancelRequest() } else { sendPrompt() } }
    @objc private func sendPrompt() {
        if selectionEditor.automaticRunning { cancelTextEdit(); return }
        let message = prompt.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { island.makeKey(); island.makeFirstResponder(prompt); return }
        guard message.count <= 6000 else { showError("Keep the question under 6,000 characters."); return }
        generate(message, mode: "auto")
    }
    @objc private func drawPrompt() {
        let message = prompt.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { island.makeKey(); island.makeFirstResponder(prompt); return }
        guard message.count <= 6000 else { showError("Keep the prompt under 6,000 characters."); return }
        generate(message, mode: "draw")
    }
    private func generate(_ message: String, mode: String = "chat") {
        guard !busy else { return }
        if compareBoth && mode != "draw" { selectionEditor.cancel() } else { selectionEditor.cancelAutomatic() }
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
        pendingComparison = compareBoth && mode != "draw"
        if pendingComparison { comparisonPanel.start() }
        pendingRequestMode = pendingComparison ? "chat" : mode
        screenshotIndicator.stringValue = attachedImage == nil ? "" : "Screenshot attached"
        var selectedSettings = mode == "draw" ? drawingSettings.request(for: provider.rawValue) : chatSettings.request(for: chatProvider.rawValue)
        selectedSettings["mode"] = mode
        if mode != "draw" && chatSettings.isAuto { autoRouteCaption = nil; updateDrawingSettings() }
        let comparing = pendingComparison
        let comparisonSettings = Dictionary(uniqueKeysWithValues: ["gpt", "claude"].map { p in (p, chatSettings.manual.request(for: p).filter { ["model", "reasoningEffort"].contains($0.key) }) })
        let automaticDrawing = mode == "auto" && !comparing ? drawingSettings.request(for: provider.rawValue) : nil
        let tokenRequest = URLRequest(url: baseURL.appendingPathComponent("api/session"), timeoutInterval: 10)
        requestTask = URLSession.shared.dataTask(with: tokenRequest) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self, self.requestGeneration == generation else { return }
                guard error == nil, let data, let tokenData = (try? JSONSerialization.jsonObject(with: data)) as? [String: String], let token = tokenData["token"] else {
                    self.finishRequest(); self.showError("Cannot connect to the local Codex server. Try reopening Clip."); return
                }
                self.prepareScreenContext(message: message, token: token, generation: generation) { [weak self] image in
                    guard let self, self.requestGeneration == generation else { return }
                    var request = URLRequest(url: baseURL.appendingPathComponent(comparing ? "api/compare" : "api/chat"), timeoutInterval: 135)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(token, forHTTPHeaderField: "X-Clippy-Session")
                    var body: [String: Any] = ["drawing": automaticDrawing as Any? ?? NSNull(), "message": message, "mode": selectedSettings["mode"]!, "tier": "fast", "provider": selectedSettings["provider"]!, "model": selectedSettings["model"]!, "reasoningEffort": selectedSettings["reasoningEffort"]!, "history": Array(self.history.suffix(12)), "previous": self.previous as Any? ?? NSNull(), "image": image as Any? ?? NSNull()]
                    if comparing { body = ["task": "chat", "message": message, "image": image as Any? ?? NSNull(), "settings": comparisonSettings] }
                    guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { self.finishRequest(); self.showError("Could not prepare the request."); return }
                    request.httpBody = encoded
                    self.requestTask = self.streamingSession.dataTask(with: request)
                    self.requestTask?.resume()
                }
            }
        }
        requestTask?.resume()
    }
    private func prepareScreenContext(message: String, token: String, generation: Int, completion: @escaping (String?) -> Void) {
        if let image = attachedImage { completion(image); return }
        setStatus("Checking screen context…")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4317/api/screen-context")!, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Clippy-Session")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["message": message, "hasImage": false])
        requestTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self, self.requestGeneration == generation else { return }
                let decision = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                guard (response as? HTTPURLResponse)?.statusCode == 200, decision?["capture"] as? Bool == true else { completion(nil); return }
                self.setStatus("Capturing screen…")
                self.takeScreenshot(automatic: true, isCurrent: { [weak self] in self?.requestGeneration == generation }) { [weak self] image in
                    guard let self, self.requestGeneration == generation else { return }
                    self.screenshotIndicator.stringValue = image == nil ? "Screenshot unavailable" : "Screenshot captured"
                    self.screenshotIndicator.setAccessibilityLabel(self.screenshotIndicator.stringValue)
                    completion(image)
                }
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
        case "comparison-status", "comparison-result", "comparison-error":
            comparisonPanel.receive(event)
        case "comparison-complete":
            comparisonPanel.receive(event); resultReceived = true
            prompt.stringValue = ""; attachedImage = nil; updateCaptureButton(); setStatus("Ready")
        case "presentation":
            if let mode = event["mode"] as? String, ["chat", "draw"].contains(mode) { pendingRequestMode = mode }
        case "route":
            if let name = event["name"] as? String, let effort = event["reasoningEffort"] as? String {
                autoRouteCaption = "Auto · \(name) · \(DrawingPreferences.effortTitle(effort))"
                updateDrawingSettings()
            }
        case "status": setStatus(event["message"] as? String ?? "Thinking…")
        case "preview":
            guard let result = event["result"] as? [String: Any] else { return }
            previewVisible = true
            render(result, preview: true)
            // Keep the Decisions-selected activity while visual parts stream.
        case "error":
            rollbackPreview()
            resultReceived = true
            showError(event["message"] as? String ?? "Codex could not finish. Try again.")
        case "result":
            guard let result = event["result"] as? [String: Any], let reply = result["reply"] as? String else { showError("Invalid visual response."); return }
            resultReceived = true
            previewVisible = false
            previous = result
            lastRequestMode = (event["mode"] as? String).flatMap { ["chat", "draw"].contains($0) ? $0 : nil } ?? pendingRequestMode
            history.append(["role": "user", "content": String(pendingMessage.prefix(4000))])
            history.append(["role": "assistant", "content": String(reply.prefix(4000))])
            history = Array(history.suffix(12))
            attachedImage = nil
            updateCaptureButton()
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
        if pendingComparison && !received { comparisonPanel.stop(error?.localizedDescription ?? "Comparison failed") }
        pendingComparison = false
        finishRequest()
        if !received { rollbackPreview() }
        if status >= 400 {
            let value = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            showError(value?["error"] as? String ?? "Local server returned error \(status).")
        } else if let error { showError(error.localizedDescription) }
        else if !received { showError("Codex ended without a visual. Try again.") }
    }
    private func finishRequest() {
        if pendingComparison && !resultReceived { comparisonPanel.stop("Request ended") }
        busy = false; requestTask = nil; sendButton.title = ""
        sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send")
        sendButton.toolTip = "Send · Return · automatically choose a visual or text answer"
        sendButton.setAccessibilityLabel("Send")
    }
    private func cancelRequest() {
        if pendingComparison { comparisonPanel.stop(); pendingComparison = false }
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
                if error != nil { self?.showError("Drawing renderer unavailable. Reopen Clip after starting the server.") }
            }
        }
        overlay.orderFrontRegardless()
        if !preview, !voiceRequested, let reply = result["reply"] as? String { showCaption(reply) }
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
            updateDrawingSettings()
            if connectionProblem == drawingUnavailable { setConnection(nil) }
            if let previous { render(previous) }
        case "followup": if let text = data["text"] as? String, !text.isEmpty, text.count <= 6000 { generate(text, mode: lastRequestMode) }
        case "closeOverlay": hideVisuals()
        case "dragOverlay": if let event = NSApp.currentEvent { overlay.performDrag(with: event) }
        case "dictate": startDictation()
        case "stopDictation": stopDictation(sendTranscript: true)
        case "speak": if let text = data["text"] as? String, text.count < 12000 { speak(text) }
        case "stopSpeaking": speech.stopSpeaking(at: .immediate)
        case "voiceState":
            guard data["generation"] as? Int == voiceGeneration else { return }
            guard let state = data["state"] as? String else { return }
            let text = data["message"] as? String ?? ""
            guard text.utf16.count <= 64000 else { return }
            if state == "ended" || state == "error" {
                voiceRequested = false; updateTalkButton()
                if state == "error" { showError(text) } else { setStatus(text.isEmpty ? "Ready" : text) }
            } else if voiceRequested {
                if state == "transcript" { showCaption(text, live: true) }
                else if state == "transcript-start" { captionDismissed = false; captions.orderOut(nil) }
                else if state == "transcript-cleared" { captions.orderOut(nil) }
                else { setStatus(String(text.prefix(1500))) }
            }
        case "voiceCaptureScreen":
            guard voiceRequested, data["generation"] as? Int == voiceGeneration,
                  let id = data["id"] as? String, !id.isEmpty, id.count <= 100 else { return }
            let generation = voiceGeneration
            takeScreenshot(automatic: true, isCurrent: { [weak self] in self?.voiceRequested == true && self?.voiceGeneration == generation }) { [weak self] image in
                guard let self, self.voiceRequested, self.voiceGeneration == generation else { return }
                self.screenshotIndicator.stringValue = image == nil ? "Screenshot unavailable" : "Screenshot captured"
                self.screenshotIndicator.setAccessibilityLabel(self.screenshotIndicator.stringValue)
                self.webView.callAsyncJavaScript("window.clippyVoice.finishScreenCapture(id, image, error)", arguments: ["id": id, "image": image as Any? ?? NSNull(), "error": image == nil ? "Screen capture unavailable. Check Screen Recording access." : NSNull()], in: nil, in: .page) { _ in }
            }
        case "voicePreview":
            if voiceRequested, data["generation"] as? Int == voiceGeneration { overlay.orderFrontRegardless() }
        case "voiceVisual":
            if voiceRequested, data["generation"] as? Int == voiceGeneration, let result = data["result"] as? [String: Any], result["scene"] != nil, result["diagram"] != nil {
                previous = result; lastRequestMode = "draw"; render(result)
            }
        default: break
        }
    }
    @objc private func toggleRealtimeVoice() {
        if voiceRequested { stopRealtimeVoice(); return }
        guard overlayReady else { showError("Wait for the drawing view to finish loading, then try Talk."); return }
        cancelRequest(); selectionEditor.cancel(); stopDictation(sendTranscript: false); speech.stopSpeaking(at: .immediate)
        voiceRequested = true; voiceGeneration += 1
        screenshotIndicator.stringValue = ""
        overlay.orderFrontRegardless()
        let generation = voiceGeneration
        updateTalkButton(); setStatus("Connecting live voice…")
        updateDrawingSettings()
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.voiceRequested, self.voiceGeneration == generation else { return }
                guard granted else {
                    self.voiceRequested = false; self.updateTalkButton()
                    self.showError("Allow Clip microphone access in Privacy & Security to use Talk."); return
                }
                self.webView.evaluateJavaScript("window.clippyVoice.setMuted(\(!self.voiceEnabled)); window.clippyVoice.setProvider('\(self.provider.rawValue)'); window.clippyVoice.start(\(generation)); void 0;") { [weak self] _, error in
                    guard let self, self.voiceGeneration == generation else { return }
                    if error != nil { self.stopRealtimeVoice(); self.showError("Live voice could not start. Reopen Clip and try again.") }
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
        showCaption(text)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard let voice = voices.first(where: { $0.language == Locale.current.identifier.replacingOccurrences(of: "_", with: "-") }) ?? voices.first(where: { $0.language.hasPrefix("en") }) ?? voices.first else { return }
        let utterance = AVSpeechUtterance(string: replyCard.text)
        utterance.voice = voice
        speech.speak(utterance)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { if !busy { setStatus("Speaking") } }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { if !busy && currentStatus == "Speaking" { setStatus("Ready") } }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { if !busy && !recording && currentStatus == "Speaking" { setStatus("Ready") } }

    private func updateCaptureButton() {
        let attached = attachedImage != nil
        captureButton.title = ""
        captureButton.imagePosition = .imageOnly
        captureButton.contentTintColor = attached ? .systemBlue : NSColor(white: 0.92, alpha: 1)
        captureButton.toolTip = attached ? "Screenshot attached · click to remove" : "Attach one screenshot to your next question"
        captureButton.setAccessibilityLabel(attached ? "Remove screenshot" : "Attach screenshot")
    }
    @objc private func captureScreen() {
        guard !busy, !captureInProgress else { return }
        if attachedImage != nil { attachedImage = nil; updateCaptureButton(); screenshotIndicator.stringValue = ""; setStatus("Screen removed"); return }
        takeScreenshot(automatic: false, isCurrent: { true }) { [weak self] image in
            guard let self else { return }
            guard let image else {
                self.screenshotIndicator.stringValue = "Screenshot unavailable"
                self.screenshotIndicator.setAccessibilityLabel("Screenshot unavailable")
                return
            }
            self.attachedImage = image
            self.screenshotIndicator.stringValue = "Screenshot captured"
            self.screenshotIndicator.setAccessibilityLabel("Screenshot captured")
            self.updateCaptureButton()
            if self.voiceRequested {
                self.webView.callAsyncJavaScript("await window.clippyVoice.shareScreen(image)", arguments: ["image": image], in: nil, in: .page) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success: self.attachedImage = nil; self.updateCaptureButton(); self.setStatus("Screen shared · ask your question")
                    case .failure: self.showError("Screen attached for a typed question; live sharing failed.")
                    }
                }
            } else { self.setStatus("Screen attached · sent only with your next question") }
        }
    }
    private func takeScreenshot(automatic: Bool, isCurrent: @escaping () -> Bool, completion: @escaping (String?) -> Void) {
        guard !captureInProgress, isCurrent() else { completion(nil); return }
        guard CGPreflightScreenCaptureAccess() || (!automatic && CGRequestScreenCaptureAccess()) else {
            if !automatic { showError("Allow Screen Recording in System Settings, then reopen Clip to attach a screenshot.") }
            completion(nil); return
        }
        captureInProgress = true
        let restoreComparison = comparisonPanel.hideForCapture()
        let overlayVisible = overlay.isVisible, captionsVisible = captions.isVisible
        island.orderOut(nil); notchBridge.orderOut(nil); gooPanel.orderOut(nil); hideDwellRing(); overlay.orderOut(nil); captions.orderOut(nil)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-\(UUID().uuidString).png")
        let restore = { [weak self] in
            guard let self else { return }
            self.captureInProgress = false
            self.setExpanded(self.expanded, animated: false)
            if isCurrent() {
                restoreComparison()
                if overlayVisible { self.overlay.orderFrontRegardless() }
                if captionsVisible { self.captions.orderFrontRegardless() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, isCurrent() else { restore(); completion(nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-t", "png", "-D", "1", target.path]
                process.standardError = FileHandle.nullDevice
                var bytes: Data?
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
                    process.waitUntilExit()
                    if process.terminationStatus == 0 { bytes = try Data(contentsOf: target) }
                } catch { }
                try? FileManager.default.removeItem(at: target)
                DispatchQueue.main.async {
                    restore()
                    guard isCurrent(), let bytes, let image = NSImage(data: bytes), let bitmap = self.thumbnail(image) else { completion(nil); return }
                    completion("data:image/png;base64," + bitmap.base64EncodedString())
                }
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

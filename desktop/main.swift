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
private let signInRequired = "Sign in with codex login"

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class IslandView: NSView {
    var onExpand: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onExpand?() }
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
    private var overlay: FloatingPanel!
    private var webView: WKWebView!
    private var captions: FloatingPanel!
    private var captionText: NSTextField!
    private var statusItem: NSStatusItem!
    private var statusLabel: NSTextField!
    private var activityMark: ActivityMark!
    private var signalHost: NSView!
    private let statusLine = CALayer()
    private let sensingLine = CAGradientLayer()
    private let sensingGlow = CAGradientLayer()
    private var signalPoint: CGFloat = 0.5
    private var pointerOnIsland = false
    private var gooPanel: FloatingPanel!
    private let gooFill = CAShapeLayer()
    private let gooInnerMask = CAShapeLayer()
    private let gooRimMask = CAShapeLayer()
    private let gooInnerGlow = CAGradientLayer()
    private let gooRimGlow = CAGradientLayer()
    private var wake = Spring(stiffness: 150, damping: 17)
    private var tipX = Spring(stiffness: 210, damping: 20)
    private var tipY = Spring(stiffness: 210, damping: 20)
    private var tether = GooTether()
    private var droplet: GooDroplet?
    private var wakeEnds: (rest: IslandLayout, awake: IslandLayout)?
    private var wakeRegion = NSRect.zero
    private var frameTimer: Timer?
    private var lastFrame: CFTimeInterval = 0
    private var lastPointerCheck: CFTimeInterval = 0
    private var collapseButton: NSButton!
    private var outsideClickMonitor: Any?
    private var prompt: NSTextField!
    private var expandedControls = [NSView]()
    private var sendButton: NSButton!
    private var micButton: NSButton!
    private var talkButton: NSButton!
    private var voiceRequested = false
    private var voiceGeneration = 0
    private var captureButton: NSButton!
    private var voiceButton: NSButton!
    private var tierPicker: NSPopUpButton!
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
    private lazy var selectionEditor = SelectionEditor { [weak self] text in self?.setStatus(text) }
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
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type != .keyDown {
                if self.expanded && event.window !== self.island { self.setExpanded(false) }
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
            guard let self, self.expanded, !self.island.frame.contains(NSEvent.mouseLocation) else { return }
            self.setExpanded(false)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        island.orderFrontRegardless()
        checkServer(startIfNeeded: true)
    }

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
        b.contentTintColor = NSColor(white: 0.76, alpha: 1)
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        b.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
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
        island.contentView = islandView
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
        sensingGlow.type = .radial
        sensingGlow.colors = [signalGreen.withAlphaComponent(0.26).cgColor, signalGreen.withAlphaComponent(0).cgColor]
        sensingGlow.opacity = 0
        sensingLine.startPoint = CGPoint(x: 0, y: 0.5)
        sensingLine.endPoint = CGPoint(x: 1, y: 0.5)
        sensingLine.colors = [signalGreen.withAlphaComponent(0), signalGreen.withAlphaComponent(0.6), NSColor(calibratedRed: 0.8, green: 1, blue: 0.86, alpha: 1), signalGreen.withAlphaComponent(0.6), signalGreen.withAlphaComponent(0)].map(\.cgColor)
        sensingLine.cornerRadius = 1
        sensingLine.shadowColor = signalGreen.cgColor
        sensingLine.shadowOffset = .zero
        sensingLine.shadowRadius = 5
        sensingLine.shadowOpacity = 1
        sensingLine.opacity = 0
        statusLine.backgroundColor = coral.cgColor
        statusLine.shadowColor = coral.cgColor
        statusLine.shadowOffset = .zero
        statusLine.shadowRadius = 4
        statusLine.shadowOpacity = 0.8
        for layer in [sensingGlow, sensingLine, statusLine] { signalHost.layer?.addSublayer(layer) }
        islandView.addSubview(signalHost, positioned: .below, relativeTo: statusLabel)
        buildGoo()
        prompt = NSTextField(frame: NSRect(x: 16, y: 54, width: 320, height: 42))
        prompt.placeholderString = "Ask me anything…"
        prompt.setAccessibilityLabel("Ask Clippy")
        prompt.font = .systemFont(ofSize: 14)
        prompt.textColor = .white
        prompt.backgroundColor = NSColor(white: 0.09, alpha: 1)
        prompt.bezelStyle = .roundedBezel
        prompt.target = self
        prompt.action = #selector(sendPrompt)
        islandView.addSubview(prompt)
        expandedControls.append(prompt)
        collapseButton = button("Collapse island", frame: NSRect(x: 352, y: 108, width: 32, height: 24), action: #selector(collapseIsland), symbol: "chevron.up", iconOnly: true)
        collapseButton.toolTip = "Make smaller · Esc or ⌃⌥Space"
        collapseButton.layer?.backgroundColor = NSColor.clear.cgColor
        captureButton = button("Screen", frame: NSRect(x: 16, y: 14, width: 98, height: 26), action: #selector(captureScreen), symbol: "rectangle.dashed")
        captureButton.toolTip = "Attach one screenshot to your next question"
        micButton = NSButton(title: "Dictate", target: self, action: #selector(toggleDictation))
        talkButton = button("Talk", frame: NSRect(x: 122, y: 14, width: 64, height: 26), action: #selector(toggleRealtimeVoice), symbol: "waveform")
        talkButton.toolTip = "Live AI voice · separately billed API usage · click End to stop the microphone"
        voiceButton = button("Voice on", frame: NSRect(x: 194, y: 14, width: 30, height: 26), action: #selector(toggleVoice), symbol: "speaker.wave.2", iconOnly: true)
        voiceButton.contentTintColor = coral
        voiceButton.toolTip = "Spoken replies on · click to mute"
        sendButton = button("Send", frame: NSRect(x: 346, y: 57, width: 38, height: 36), action: #selector(sendOrCancel), symbol: "arrow.up", iconOnly: true)
        sendButton.layer?.backgroundColor = coral.cgColor
        sendButton.contentTintColor = .black
        sendButton.toolTip = "Send · Return"
        tierPicker = NSPopUpButton(frame: NSRect(x: 238, y: 14, width: 90, height: 26))
        tierPicker.addItems(withTitles: ["Standard", "Fast"])
        tierPicker.selectItem(at: 1)
        tierPicker.font = .systemFont(ofSize: 11)
        tierPicker.toolTip = "GPT-6.1 Terra · Low reasoning. Fast uses more Codex allowance."
        islandView.addSubview(tierPicker)
        expandedControls.append(tierPicker)
        _ = button("More options", frame: NSRect(x: 352, y: 14, width: 32, height: 26), action: #selector(showIslandOptions(_:)), symbol: "ellipsis", iconOnly: true)
        setExpanded(false)
    }
    // Liquid can reach past the island, so it has its own click-through panel below it.
    // Inside the island's window it would block clicks on the menu bar.
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
        gooInnerMask.fillColor = NSColor.white.cgColor
        gooRimMask.fillColor = nil
        gooRimMask.strokeColor = NSColor.white.cgColor
        gooRimMask.lineWidth = 2
        gooRimMask.shadowColor = NSColor.white.cgColor
        gooRimMask.shadowOffset = .zero
        gooRimMask.shadowRadius = 5
        gooRimMask.shadowOpacity = 1
        gooInnerGlow.type = .radial
        gooInnerGlow.colors = [signalGreen.withAlphaComponent(0.45).cgColor, signalGreen.withAlphaComponent(0).cgColor]
        gooInnerGlow.mask = gooInnerMask
        gooRimGlow.type = .radial
        gooRimGlow.colors = [signalGreen.cgColor, signalGreen.withAlphaComponent(0).cgColor]
        gooRimGlow.mask = gooRimMask
        for layer in [gooFill, gooInnerGlow, gooRimGlow] { host.layer?.addSublayer(layer) }
    }
    @objc private func collapseIsland() { setExpanded(false) }
    @objc private func showIslandOptions(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [("New conversation", #selector(newConversation)), ("Dictate on-device", #selector(toggleDictation)), ("Hide drawing", #selector(hideVisuals)), ("Show last drawing", #selector(showLastVisual)), ("Enable text editing…", #selector(enableTextEditing)), ("Cancel text edit", #selector(cancelTextEdit))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Proofread selection     ⌃⌥D", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Rewrite selection          ⌃D", action: nil, keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSPoint(x: sender.frame.minX, y: sender.frame.minY), in: islandView)
    }
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
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastPointerCheck, 0.1))
        lastPointerCheck = now
        let pointer = NSEvent.mouseLocation
        // The pointer can rest on the screen's top edge, which a rect excludes.
        let region = (pointerOnIsland ? island.frame : wakeRegion).insetBy(dx: 0, dy: -1)
        let inside = island.isVisible && region.contains(pointer)
        if wakeEnds?.rest.isNotched == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let outline = IslandOutline(rect: island.frame)
            if tether.update(inside: inside, distance: outline.distance(to: pointer), pressed: NSEvent.pressedMouseButtons != 0, dt: dt) { separateGoo() }
        } else { tether.attached = inside }
        guard tether.attached != pointerOnIsland else { return }
        pointerOnIsland = tether.attached
        if pointerOnIsland {
            let anchor = IslandOutline(rect: island.frame)
            let start = anchor.point(at: anchor.nearest(to: pointer))
            tipX.jump(to: start.x); tipY.jump(to: start.y)
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
            setStatus("Shortcut unavailable. Click the island to open it.")
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
    private func setExpanded(_ value: Bool, focus: Bool = false) {
        expanded = value
        let layout = layoutIsland()
        if let bridge = layout.notchBridge {
            notchBridge.setFrame(bridge, display: true)
            notchBridge.orderFrontRegardless()
            notchBridge.order(.below, relativeTo: island.windowNumber)
        } else {
            notchBridge.orderOut(nil)
        }
        for control in expandedControls { control.isHidden = !value }
        island.orderFrontRegardless()
        if layout.isNotched && !value {
            gooPanel.orderFrontRegardless()
            gooPanel.order(.below, relativeTo: island.windowNumber)
        } else { gooPanel.orderOut(nil) }
        if value && focus { island.makeKey(); island.makeFirstResponder(prompt) }
        if !value { island.resignKey() }
    }
    private var talking: Bool { voiceRequested || recording || currentStatus == "Speaking" }
    // Resting: a green line. Audio live: the waveform. Anything else to say: text and line.
    @discardableResult private func layoutIsland() -> IslandLayout {
        let content: IslandContent = talking ? .audio : currentStatus == "Ready" ? .idle : .status(textWidth: ceil(statusLabel.cell?.cellSize.width ?? 52))
        let awake = pointerOnIsland && content == .idle && !expanded
        let screen = island?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let makeLayout = { [expanded] (hovered: Bool) in
            IslandLayout(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                         leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea,
                         expanded: expanded, content: content, hovered: hovered)
        }
        let layout = makeLayout(awake)
        islandView.layer?.cornerRadius = layout.cornerRadius
        islandView.layer?.maskedCorners = layout.isNotched && !expanded
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        islandView.layer?.backgroundColor = (layout.isNotched ? .black : NSColor(white: 0.025, alpha: 1)).cgColor
        islandView.layer?.borderWidth = layout.isNotched ? 0 : 0.5
        statusLabel.frame = layout.statusFrame
        activityMark.frame = layout.activityFrame
        signalHost.layer?.maskedCorners = islandView.layer?.maskedCorners ?? []
        if case .status = content { statusLabel.isHidden = false } else { statusLabel.isHidden = !expanded }
        activityMark.isHidden = content != .audio
        islandView.toolTip = expanded ? nil : "\(currentStatus) · Click to open · ⌃⌥Space"
        islandView.setAccessibilityLabel("Clippy: \(currentStatus)")
        wake.target = awake ? 1 : 0
        if content == .idle && !expanded {
            let rest = makeLayout(false)
            wakeEnds = (rest, makeLayout(true))
            wakeRegion = rest.wakeArea.offsetBy(dx: rest.frame.minX, dy: rest.frame.minY)
            gooPanel.setFrame(rest.frame.insetBy(dx: -220, dy: 0).union(rest.frame.offsetBy(dx: 0, dy: -150)), display: false)
            if awake || wake.value > 0 || droplet != nil || frameTimer != nil {
                startFrames()
                applyWake()
                return layout
            }
        } else {
            // Text or the composer takes over from any liquid still in motion.
            stopFrames()
            wakeRegion = .zero
            wake.jump(to: 0); tether.attached = false; pointerOnIsland = false; droplet = nil
        }
        updateSignal(content: content, layout: layout)
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
        if layout.isNotched && !expanded {
            gooPanel.setFrame(layout.frame.insetBy(dx: -220, dy: 0).union(layout.frame.offsetBy(dx: 0, dy: -150)), display: false)
            drawGoo(outline: IslandOutline(rect: layout.frame), tip: nil)
        }
        return layout
    }
    // The resting line, breathing while idle. The spring takes over from here while awake.
    private func updateSignal(content: IslandContent, layout: IslandLayout) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(reduceMotion)
        CATransaction.setAnimationDuration(expanded ? 0.18 : 0.26)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        signalHost.layer?.cornerRadius = layout.cornerRadius
        statusLine.frame = layout.lineFrame
        statusLine.cornerRadius = min(layout.lineFrame.width, layout.lineFrame.height) / 2
        statusLine.opacity = content == .audio ? 0 : 1
        sensingLine.opacity = 0
        sensingGlow.opacity = 0
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
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { wake.jump(to: wake.target) } else { wake.step(dt) }
        applyWake()
        stepGoo(dt)
        if wake.isSettled, wake.value == 0, droplet == nil, tipX.isSettled, tipY.isSettled {
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
        let bead = smoothstep(0, 0.5, t), spread = smoothstep(0.3, 1, t)
        let restLine = rest.lineFrame.offsetBy(dx: rest.frame.minX - frame.minX, dy: rest.frame.minY - frame.minY)
        let awakeLine = awake.lineFrame.offsetBy(dx: awake.frame.minX - frame.minX, dy: awake.frame.minY - frame.minY)
        let width = mix(restLine.width, 6, bead), height = mix(restLine.height, awakeLine.height, bead)
        let lean = max(min((NSEvent.mouseLocation.x - frame.midX) / max(frame.width, 1), 0.5), -0.5) * 0.25
        signalPoint += (0.5 + lean - signalPoint) * 0.12
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = mix(rest.cornerRadius, awake.cornerRadius, min(t, 1))
        islandView.layer?.cornerRadius = radius
        signalHost.layer?.cornerRadius = radius
        statusLine.frame = NSRect(x: mix(restLine.midX, awakeLine.midX, bead) - width / 2, y: mix(restLine.midY, awakeLine.midY, bead) - height / 2, width: width, height: height)
        statusLine.cornerRadius = min(width, height) / 2
        statusLine.opacity = Float(1 - smoothstep(0.45, 0.75, t))
        let lineWidth = mix(8, awakeLine.width, spread)
        sensingLine.frame = NSRect(x: awakeLine.midX - lineWidth / 2, y: awakeLine.minY, width: lineWidth, height: awakeLine.height)
        sensingLine.opacity = Float(smoothstep(0.4, 0.75, t))
        sensingLine.locations = [0, signalPoint * 0.4, signalPoint, signalPoint + (1 - signalPoint) * 0.6, 1].map { NSNumber(value: Double($0)) }
        sensingGlow.frame = NSRect(origin: .zero, size: frame.size)
        sensingGlow.opacity = Float(spread)
        sensingGlow.startPoint = CGPoint(x: signalPoint, y: 0.1)
        sensingGlow.endPoint = CGPoint(x: signalPoint + 0.22, y: 1)
        CATransaction.commit()
    }
    private func stepGoo(_ dt: CGFloat) {
        guard wakeEnds?.rest.isNotched == true else { return }
        let outline = IslandOutline(rect: island.frame)
        let pointer = NSEvent.mouseLocation
        let target: CGPoint
        if pointerOnIsland {
            // The blob reaches most of the way, then the pointer pulls away from it.
            let anchor = outline.point(at: outline.nearest(to: pointer))
            let gap = outline.rect.contains(pointer) ? 0 : hypot(pointer.x - anchor.x, pointer.y - anchor.y)
            let reach = min(gap * 0.8, 70) / max(gap, 1)
            target = CGPoint(x: anchor.x + (pointer.x - anchor.x) * reach, y: anchor.y + (pointer.y - anchor.y) * reach)
            tipX.stiffness = 210; tipY.stiffness = 210; tipX.damping = 20; tipY.damping = 20
        } else {
            target = outline.point(at: outline.nearest(to: CGPoint(x: tipX.value, y: tipY.value)))
            tipX.stiffness = 340; tipY.stiffness = 340; tipX.damping = 26; tipY.damping = 26
        }
        tipX.target = target.x; tipY.target = target.y
        tipX.step(dt); tipY.step(dt)
        if var drop = droplet {
            drop.center.x += drop.velocity.x * dt; drop.center.y += drop.velocity.y * dt
            drop.radius -= 28 * dt
            droplet = drop.radius > 0.5 ? drop : nil
        }
        drawGoo(outline: outline, tip: CGPoint(x: tipX.value, y: tipY.value))
    }
    private func separateGoo() {
        guard let bulb = GooShape.bulb(outline: IslandOutline(rect: island.frame), tip: CGPoint(x: tipX.value, y: tipY.value)) else { return }
        droplet = GooDroplet(center: bulb.center, radius: bulb.radius * 0.7, velocity: CGPoint(x: bulb.direction.x * 45, y: bulb.direction.y * 45))
    }
    private func drawGoo(outline: IslandOutline, tip: CGPoint?) {
        let bounds = gooPanel.frame
        let toPanel = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        let liquid = CGMutablePath()
        if let tip, let blob = GooShape.blob(outline: outline, tip: tip) { liquid.addPath(blob, transform: toPanel) }
        if let droplet {
            liquid.addEllipse(in: CGRect(x: droplet.center.x - droplet.radius, y: droplet.center.y - droplet.radius, width: droplet.radius * 2, height: droplet.radius * 2), transform: toPanel)
        }
        let fill = CGMutablePath()
        fill.addPath(liquid)
        fill.addPath(GooShape.shoulders(rect: outline.rect), transform: toPanel)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let local = CGRect(origin: .zero, size: bounds.size)
        for layer in [gooFill, gooInnerGlow, gooRimGlow] { layer.frame = local }
        gooInnerMask.frame = local; gooRimMask.frame = local
        gooFill.path = fill
        gooInnerMask.path = liquid
        gooRimMask.path = liquid
        let focus = (tip ?? .zero).applying(toPanel)
        let unit = CGPoint(x: focus.x / max(local.width, 1), y: focus.y / max(local.height, 1))
        gooInnerGlow.startPoint = unit
        gooInnerGlow.endPoint = CGPoint(x: unit.x + 26 / max(local.width, 1), y: unit.y + 26 / max(local.height, 1))
        gooRimGlow.startPoint = unit
        gooRimGlow.endPoint = CGPoint(x: unit.x + 48 / max(local.width, 1), y: unit.y + 48 / max(local.height, 1))
        CATransaction.commit()
    }
    @objc private func reposition() { setExpanded(expanded); positionOverlay() }
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
        voiceButton.contentTintColor = voiceEnabled ? coral : NSColor(white: 0.6, alpha: 1)
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

    private func checkServer(startIfNeeded: Bool, retries: Int = 12) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], value["model"] != nil {
                    self.setConnection(value["authenticated"] as? Bool == true ? nil : signInRequired)
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
        var request = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], value["model"] != nil else {
                    self.setConnection(serverUnavailable); return
                }
                if value["authenticated"] as? Bool != true { self.setConnection(signInRequired) }
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
                let body: [String: Any] = ["message": message, "tier": ["standard", "fast"][self.tierPicker.indexOfSelectedItem], "history": Array(self.history.suffix(12)), "previous": self.previous as Any? ?? NSNull(), "image": self.attachedImage as Any? ?? NSNull()]
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
                self.webView.evaluateJavaScript("window.clippyVoice.setMuted(\(!self.voiceEnabled)); window.clippyVoice.start(\(generation)); void 0;") { [weak self] _, error in
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
        island.orderOut(nil); notchBridge.orderOut(nil); gooPanel.orderOut(nil); overlay.orderOut(nil); captions.orderOut(nil)
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
        healthTimer?.invalidate(); settleTimer?.invalidate(); frameTimer?.invalidate()
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

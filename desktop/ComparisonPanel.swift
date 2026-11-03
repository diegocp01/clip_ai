import AppKit

private final class ComparisonWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Both always produces copyable alternatives; it never pastes over the selection.
final class ComparisonPanel: NSObject, NSWindowDelegate {
    var onCancel: (() -> Void)?
    private var panel: NSPanel?
    private var statuses: [String: NSTextField] = [:]
    private var bodies: [String: NSTextView] = [:]
    private var copies: [String: NSButton] = [:]
    private var answers: [String: String] = [:]
    private var pending = Set<String>()
    private var stopButton: NSButton!
    private func build() {
        guard panel == nil else { return }
        let window = ComparisonWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 300), styleMask: [.borderless, .closable], backing: .buffered, defer: false)
        window.title = "Codex + Claude"
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        let glass = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 300))
        window.contentView = glass
        stopButton = NSButton(title: "Stop", target: self, action: #selector(cancel))
        stopButton.frame = NSRect(x: 772, y: 272, width: 58, height: 26)
        stopButton.isBordered = false; stopButton.font = .systemFont(ofSize: 11)
        stopButton.autoresizingMask = [.minXMargin, .minYMargin]; glass.addSubview(stopButton)
        let stack = NSStackView(); stack.orientation = .horizontal; stack.distribution = .fillEqually; stack.spacing = 14
        stack.frame = NSRect(x: 0, y: 0, width: 840, height: 266)
        stack.autoresizingMask = [.width, .height]; glass.addSubview(stack)
        for (index, provider) in ["gpt", "claude"].enumerated() {
            let name = provider == "gpt" ? "Codex" : "Claude"
            let column = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 413, height: 266))
            column.material = .hudWindow; column.blendingMode = .behindWindow; column.state = .active
            column.wantsLayer = true
            column.layer?.cornerRadius = 20
            column.layer?.masksToBounds = true
            column.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
            column.layer?.borderWidth = 0.75
            let heading = NSTextField(labelWithString: name)
            heading.font = .systemFont(ofSize: 12, weight: .medium)
            heading.frame = NSRect(x: 20, y: 230, width: 300, height: 18); heading.autoresizingMask = [.width, .minYMargin]
            column.addSubview(heading)
            let status = NSTextField(labelWithString: "Waiting…")
            status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor
            status.frame = NSRect(x: 20, y: 208, width: 373, height: 14); status.autoresizingMask = [.width, .minYMargin]
            status.lineBreakMode = .byTruncatingTail; column.addSubview(status); statuses[provider] = status
            let scroll = NSScrollView(frame: NSRect(x: 16, y: 42, width: 381, height: 154))
            scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autoresizingMask = [.width, .height]
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.drawsBackground = false
            text.font = .systemFont(ofSize: 14); text.textColor = .labelColor
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
            text.defaultParagraphStyle = paragraph
            text.textContainerInset = NSSize(width: 4, height: 8)
            text.autoresizingMask = [.width]; text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
            text.setAccessibilityLabel("\(name) answer")
            scroll.documentView = text; column.addSubview(scroll); bodies[provider] = text
            let copy = NSButton(title: "Copy \(name)", target: self, action: #selector(copyAnswer(_:)))
            copy.isBordered = false; copy.font = .systemFont(ofSize: 11, weight: .medium)
            copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil); copy.imagePosition = .imageLeading
            copy.setAccessibilityLabel("Copy \(name)")
            copy.tag = index; copy.frame = NSRect(x: 20, y: 9, width: 130, height: 26)
            column.addSubview(copy); copies[provider] = copy
            stack.addArrangedSubview(column)
        }
        panel = window
        window.center()
    }
    func hideForCapture() -> () -> Void {
        let visible = panel?.isVisible == true
        panel?.orderOut(nil)
        return { [weak self] in if visible { self?.panel?.orderFrontRegardless() } }
    }
    func start(editing: Bool = false) {
        build(); answers = [:]; pending = Set(["gpt", "claude"])
        for provider in pending { bodies[provider]?.string = ""; statuses[provider]?.stringValue = "Waiting…"; copies[provider]?.isEnabled = false }
        panel?.title = editing ? "Compare edits · Codex + Claude" : "Compare answers · Codex + Claude"
        stopButton.isEnabled = true; stopButton.isHidden = false
        if editing { panel?.orderFrontRegardless() } else { panel?.makeKeyAndOrderFront(nil) }
    }
    func receive(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        if type == "comparison-complete" { stop("No answer returned"); return }
        guard let provider = event["provider"] as? String, pending.contains(provider) else { return }
        if type == "comparison-status" { statuses[provider]?.stringValue = event["message"] as? String ?? "Working…" }
        if type == "comparison-result", let text = event["text"] as? String {
            answers[provider] = text; bodies[provider]?.string = text
            statuses[provider]?.stringValue = [event["model"] as? String, event["reasoningEffort"] as? String].compactMap { $0 }.joined(separator: " · ")
            copies[provider]?.isEnabled = true; pending.remove(provider)
        }
        if type == "comparison-error" {
            statuses[provider]?.stringValue = "Unavailable"
            bodies[provider]?.string = event["message"] as? String ?? "Request failed"
            pending.remove(provider)
        }
        stopButton.isEnabled = !pending.isEmpty; stopButton.isHidden = pending.isEmpty
        fitAnswers()
    }
    private func fitAnswers() {
        guard let panel else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let textHeight = answers.values.map { ($0 as NSString).boundingRect(with: NSSize(width: 369, height: 100000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph]).height }.max() ?? 80
        let height = min(480, max(pending.isEmpty ? 200 : 240, ceil(textHeight) + 146))
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
    }
    var isVisible: Bool { panel?.isVisible == true }
    func dismiss() { panel?.close() }
    func stop(_ reason: String = "Cancelled") {
        for provider in pending { statuses[provider]?.stringValue = reason }
        pending.removeAll(); stopButton?.isEnabled = false; stopButton?.isHidden = true
    }
    @objc private func cancel() { onCancel?(); stop() }
    @objc private func copyAnswer(_ sender: NSButton) {
        let provider = sender.tag == 0 ? "gpt" : "claude"
        guard let text = answers[provider] else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        statuses[provider]?.stringValue = "Copied"
    }
    func windowWillClose(_ notification: Notification) { if !pending.isEmpty { cancel() } }
}

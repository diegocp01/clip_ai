import AppKit

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
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex + Claude"
        window.minSize = NSSize(width: 620, height: 340)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        window.contentView = glass
        let hint = NSTextField(labelWithString: "Same request · independent answers · copy the version you prefer")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 24, y: 481, width: 730, height: 18)
        hint.autoresizingMask = [.width, .minYMargin]; glass.addSubview(hint)
        stopButton = NSButton(title: "Stop", target: self, action: #selector(cancel))
        stopButton.frame = NSRect(x: 802, y: 475, width: 74, height: 28)
        stopButton.autoresizingMask = [.minXMargin, .minYMargin]; glass.addSubview(stopButton)
        let stack = NSStackView(); stack.orientation = .horizontal; stack.distribution = .fillEqually; stack.spacing = 20
        stack.frame = NSRect(x: 24, y: 24, width: 852, height: 434)
        stack.autoresizingMask = [.width, .height]; glass.addSubview(stack)
        for (index, provider) in ["gpt", "claude"].enumerated() {
            let name = provider == "gpt" ? "Codex" : "Claude"
            let column = NSView(frame: NSRect(x: 0, y: 0, width: 416, height: 434))
            let heading = NSTextField(labelWithString: name)
            heading.font = .systemFont(ofSize: 20, weight: .semibold)
            heading.frame = NSRect(x: 0, y: 398, width: 300, height: 28); heading.autoresizingMask = [.width, .minYMargin]
            column.addSubview(heading)
            let status = NSTextField(labelWithString: "Waiting…")
            status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
            status.frame = NSRect(x: 0, y: 373, width: 416, height: 18); status.autoresizingMask = [.width, .minYMargin]
            status.lineBreakMode = .byTruncatingTail; column.addSubview(status); statuses[provider] = status
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: 416, height: 315))
            scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autoresizingMask = [.width, .height]
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.drawsBackground = false
            text.font = .systemFont(ofSize: 15); text.textColor = .labelColor
            text.textContainerInset = NSSize(width: 4, height: 8)
            text.autoresizingMask = [.width]; text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
            text.setAccessibilityLabel("\(name) answer")
            scroll.documentView = text; column.addSubview(scroll); bodies[provider] = text
            let copy = NSButton(title: "Copy \(name)", target: self, action: #selector(copyAnswer(_:)))
            copy.tag = index; copy.frame = NSRect(x: 0, y: 0, width: 130, height: 30)
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
        stopButton.isEnabled = true
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
        stopButton.isEnabled = !pending.isEmpty
    }
    func stop(_ reason: String = "Cancelled") {
        for provider in pending { statuses[provider]?.stringValue = reason }
        pending.removeAll(); stopButton?.isEnabled = false
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

import AppKit
import ApplicationServices
import Carbon

// Only the selection is sent to the selected model. No screenshot or document context is read.
final class SelectionEditor: NSObject {
    private struct Selection {
        let pid: pid_t
        let element: AXUIElement?
        let range: CFRange?
        let text: String
    }
    private let onStatus: (String) -> Void
    private let provider: () -> String
    private var generation = 0
    private var task: Task<Void, Never>?
    private var resultPanel: NSPanel?
    private var resultText = ""
    private var clipboardBusy = false
    init(provider: @escaping () -> String, onStatus: @escaping (String) -> Void) { self.provider = provider; self.onStatus = onStatus }

    func requestAccess() {
        if AXIsProcessTrusted() { onStatus("Text editing ready · ⌃⌥D / ⌃D"); return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        onStatus("Enable Clippy in Accessibility, then press the shortcut again")
    }

    func cancel() {
        generation += 1
        task?.cancel(); task = nil
    }
    func start(_ action: String) {
        guard !clipboardBusy else { onStatus("Finishing the previous edit…"); return }
        cancel()
        let current = generation
        guard AXIsProcessTrusted() else {
            requestAccess()
            return
        }
        guard !IsSecureEventInputEnabled(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            onStatus("Select text in another app first"); return
        }
        let pid = app.processIdentifier
        let provider = self.provider()
        onStatus("\(action == "proofread" ? "Proofreading" : "Rewriting") · \(provider == "claude" ? "Claude" : "Sol high")…")
        // Let the physical shortcut's modifiers go before any Copy fallback.
        afterModifiersReleased { [weak self] in
            guard let self, self.generation == current else { return }
            self.capture(pid: pid) { [self] selection in
                guard self.generation == current else { return }
                guard let selection, !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.onStatus("No selected text found. Select text, then try again."); return
                }
                guard selection.text.utf16.count <= 12000 else {
                    self.onStatus("Select at most 12,000 characters"); return
                }
                self.task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let base = URL(string: "http://127.0.0.1:4317")!
                        let (tokenBytes, tokenResponse) = try await URLSession.shared.data(from: base.appendingPathComponent("api/session"))
                        guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200,
                              let object = try JSONSerialization.jsonObject(with: tokenBytes) as? [String: String], let token = object["token"] else {
                            throw NSError(domain: "Clippy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local server unavailable"])
                        }
                        try Task.checkCancellation()
                        var request = URLRequest(url: base.appendingPathComponent("api/edit"), timeoutInterval: 135)
                        request.httpMethod = "POST"
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue(token, forHTTPHeaderField: "X-Clippy-Session")
                        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": selection.text, "action": action, "provider": provider])
                        let (data, response) = try await URLSession.shared.data(for: request)
                        try Task.checkCancellation()
                        guard self.generation == current else { return }
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                            throw NSError(domain: "Clippy", code: 2, userInfo: [NSLocalizedDescriptionKey: value?["error"] as? String ?? "Editing request failed"])
                        }
                        var output: String?
                        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                            if event["type"] as? String == "error" {
                                throw NSError(domain: "Clippy", code: 3, userInfo: [NSLocalizedDescriptionKey: event["message"] as? String ?? "Editing failed"])
                            }
                            if event["type"] as? String == "result", let result = event["result"] as? [String: Any] { output = result["text"] as? String }
                        }
                        guard let output, !output.isEmpty, output.utf16.count <= 24000 else {
                            throw NSError(domain: "Clippy", code: 4, userInfo: [NSLocalizedDescriptionKey: "No edited text returned"])
                        }
                        self.replace(selection, with: output, generation: current)
                    } catch {
                        if !Task.isCancelled && self.generation == current { self.onStatus("Edit failed: \(error.localizedDescription)") }
                    }
                }
            }
        }
    }
    private func focusedElement(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func selectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }
    private func capture(pid: pid_t, completion: @escaping (Selection?) -> Void) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !IsSecureEventInputEnabled() else { completion(nil); return }
        let element = focusedElement(pid)
        if let element {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
            if role as? String == kAXSecureTextFieldSubrole as String { completion(nil); return }
            if let text = selectedText(element) {
                // An exposed empty selection is authoritative: never grab the whole field.
                completion(text.isEmpty ? nil : Selection(pid: pid, element: element, range: selectedRange(element), text: text))
                return
            }
        }
        // Some editors copy a whole line with no selection. Require a positive
        // selection range before using Copy when AXSelectedText is unavailable.
        guard let element, let range = selectedRange(element), range.length > 0 else { completion(nil); return }
        copySelection(pid: pid) { [weak self] text in
            guard let self, let text, !text.isEmpty else { completion(nil); return }
            completion(Selection(pid: pid, element: element, range: self.selectedRange(element), text: text))
        }
    }
    private func matches(_ old: Selection, _ fresh: Selection) -> Bool {
        guard old.pid == fresh.pid, old.text == fresh.text else { return false }
        if let element = old.element { guard let other = fresh.element, CFEqual(element, other) else { return false } }
        if let range = old.range { guard let other = fresh.range, range.location == other.location, range.length == other.length else { return false } }
        return true
    }
    private func replace(_ original: Selection, with text: String, generation current: Int) {
        guard generation == current else { return }
        guard original.text != text else { onStatus("No changes needed"); return }
        afterModifiersReleased { [weak self] in
            guard let self, self.generation == current else { return }
            self.capture(pid: original.pid) { fresh in
                guard self.generation == current else { return }
                guard let fresh, self.matches(original, fresh) else {
                    self.showResult(text, reason: "Selection changed. Your text was left untouched."); return
                }
                // Use normal Paste for native Undo and broad editor compatibility.
                // Recheck focus immediately before dispatch; never activate a stale app.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == original.pid else {
                    self.showResult(text, reason: "You switched apps. Your text was left untouched."); return
                }
                let clipboard = ClipboardSnapshot()
                self.clipboardBusy = true
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let change = NSPasteboard.general.changeCount
                self.commandKey(9, pid: original.pid) // Command-V, never Return/Submit.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    clipboard.restore(ifUnchanged: change)
                    self.clipboardBusy = false
                    guard self.generation == current else { return }
                    if let element = original.element, let range = original.range,
                       let inserted = self.textAt(element, location: range.location, length: text.utf16.count) {
                        if inserted == text { self.onStatus("Edited · ⌘Z to undo") }
                        else { self.showResult(text, reason: "The app did not confirm the replacement. Check your field before copying.") }
                    } else { self.onStatus("Replacement sent · ⌘Z to undo") }
                }
            }
        }
    }
    private func commandKey(_ key: CGKeyCode, pid: pid_t) {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
    }
    private func textAt(_ element: AXUIElement, location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success else { return nil }
        return value as? String
    }
    private func afterModifiersReleased(_ completion: @escaping () -> Void, attempts: Int = 40) {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty { completion(); return }
        guard attempts > 0 else { onStatus("Release the shortcut keys, then try again"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.afterModifiersReleased(completion, attempts: attempts - 1) }
    }
    private func copySelection(pid: pid_t, completion: @escaping (String?) -> Void) {
        clipboardBusy = true
        let clipboard = ClipboardSnapshot()
        let marker = "clippy-selection-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(marker, forType: .string)
        let initial = NSPasteboard.general.changeCount
        commandKey(8, pid: pid) // Command-C fallback for apps without AXSelectedText.
        func read(_ remaining: Int) {
            let board = NSPasteboard.general
            if board.changeCount == initial && remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { read(remaining - 1) }; return
            }
            let count = board.changeCount
            let text = board.string(forType: .string)
            clipboard.restore(ifUnchanged: count)
            self.clipboardBusy = false
            completion(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && text != marker ? text : nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { read(15) }
    }
    private func showResult(_ text: String, reason: String) {
        resultText = text
        onStatus("Edit ready · selection changed")
        resultPanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 330), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Clippy · edited text"
        panel.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: reason)
        label.frame = NSRect(x: 18, y: 282, width: 484, height: 32)
        let scroll = NSScrollView(frame: NSRect(x: 18, y: 54, width: 484, height: 218))
        scroll.hasVerticalScroller = true
        let editor = NSTextView(frame: scroll.bounds)
        editor.string = text; editor.isEditable = false; editor.isSelectable = true
        editor.font = .systemFont(ofSize: 15)
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        let copy = NSButton(title: "Copy result", target: self, action: #selector(copyResult))
        copy.bezelStyle = .rounded; copy.frame = NSRect(x: 380, y: 14, width: 122, height: 28)
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(scroll); panel.contentView?.addSubview(copy)
        panel.center(); panel.orderFrontRegardless(); resultPanel = panel
    }
    @objc private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
        onStatus("Edited text copied")
    }
}

private struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    init() {
        items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var saved = [NSPasteboard.PasteboardType: Data]()
            for type in item.types { if let data = item.data(forType: type) { saved[type] = data } }
            return saved
        }
    }
    func restore(ifUnchanged count: Int) {
        let board = NSPasteboard.general
        guard board.changeCount == count else { return }
        board.clearContents()
        let restored = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}

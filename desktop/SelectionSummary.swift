import AppKit
import Carbon
import CryptoKit

enum SelectionSummary {
    struct Snapshot {
        let pid: pid_t
        let element: AXUIElement
        let range: CFRange?
        let text: String
        var fingerprint: String {
            let identity = "\(pid)|\(CFHash(element))|\(range?.location ?? -1)|\(range?.length ?? -1)|\(text)"
            return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }
    static func label(for count: Int) -> String? {
        count > 0 ? "\(count) \(count == 1 ? "word" : "words") | selected text" : nil
    }

    /// Read only the focused app's exposed selection. Never synthesize Copy,
    /// inspect the clipboard or request permission. The snapshot is scoped to this edit.
    static func readSelection(pid: pid_t, diagnostic: (String) -> Void = { _ in }) -> Snapshot? {
        guard pid != ProcessInfo.processInfo.processIdentifier else { diagnostic("Clip has focus"); return nil }
        guard AXIsProcessTrusted() else { diagnostic("Accessibility access unavailable"); return nil }
        guard !IsSecureEventInputEnabled() else { diagnostic("Secure input active"); return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusedResult == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { diagnostic("No focused field (\(focusedResult.rawValue))"); return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        var subrole: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard [.success, .attributeUnsupported, .noValue].contains(subroleResult) else { diagnostic("Field unavailable (\(subroleResult.rawValue))"); return nil }
        guard subrole as? String != kAXSecureTextFieldSubrole as String else { diagnostic("Secure field"); return nil }
        var value: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard selectedResult == .success, let text = value as? String, !text.isEmpty, text.utf16.count <= 1_000_000,
              !IsSecureEventInputEnabled() else { diagnostic("No exposed selection (\(selectedResult.rawValue))"); return nil }
        var rangeValue: CFTypeRef?
        var range: CFRange?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            let ax = rangeValue as! AXValue
            var value = CFRange()
            if AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &value) { range = value }
        }
        return Snapshot(pid: pid, element: element, range: range, text: text)
    }
}

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
    static func readSelection(pid: pid_t) -> Snapshot? {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        var subrole: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subroleResult == .success || subroleResult == .attributeUnsupported else { return nil }
        guard subrole as? String != kAXSecureTextFieldSubrole as String else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty, text.utf16.count <= 1_000_000,
              !IsSecureEventInputEnabled() else { return nil }
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

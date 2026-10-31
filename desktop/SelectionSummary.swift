import AppKit
import Carbon

enum SelectionSummary {
    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }
    static func label(for count: Int) -> String? {
        count > 0 ? "\(count) \(count == 1 ? "word" : "words") | selected text" : nil
    }

    /// Read only the focused app's exposed selection. Never synthesize Copy,
    /// inspect the clipboard, request permission, or retain the selected text.
    static func readWordCount(pid: pid_t) -> Int? {
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
        let count = wordCount(text)
        return count > 0 ? count : nil
    }
}

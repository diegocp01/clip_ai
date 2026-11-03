import AppKit

enum ReplyCardLayout {
    static let gap: CGFloat = 12
    static func frame(size: NSSize, under composer: NSRect, visibleFrame: NSRect) -> NSRect {
        let width = min(size.width, visibleFrame.width - 32)
        let height = min(size.height, max(64, composer.minY - gap - visibleFrame.minY - 16))
        let x = min(max(composer.midX - width / 2, visibleFrame.minX + 16), visibleFrame.maxX - width - 16)
        return NSRect(x: x, y: max(visibleFrame.minY + 16, composer.minY - gap - height), width: width, height: height)
    }

    /// A response title is metadata, not a second answer or a drawing.
    static func hasVisual(_ result: [String: Any]) -> Bool {
        let scene = result["scene"] as? [String: Any]
        let diagram = result["diagram"] as? [String: Any]
        return [scene?["objects"], diagram?["nodes"], result["cards"], result["annotations"], result["sections"]]
            .contains { ($0 as? [Any])?.isEmpty == false }
    }

    static func size(text: String, available: NSSize, canContinue: Bool = false) -> NSSize {
        let font = NSFont.systemFont(ofSize: 15)
        let naturalWidth = (text as NSString).size(withAttributes: [.font: font]).width + 92
        let width = min(640, max(240, min(naturalWidth, available.width - 48)))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let rect = (text as NSString).boundingRect(with: NSSize(width: width - 92, height: 100000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph])
        return NSSize(width: width, height: min(max(100, available.height * 0.38), max(64, ceil(rect.height) + 40) + (canContinue ? 32 : 0)))
    }
}

final class ReplyCard: NSVisualEffectView {
    var onContinue: (() -> Void)?
    private(set) var text = ""
    private let continueButton = NSButton()
    private let copyButton = NSButton()
    private let scroll = NSScrollView()
    private let body = NSTextView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow; blendingMode = .behindWindow; state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true; layer?.cornerRadius = 22; layer?.masksToBounds = true
        layer?.borderWidth = 0.75; layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        for (button, symbol, label, action) in [(copyButton, "doc.on.doc", "Copy reply", #selector(copyReply))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly; button.isBordered = false
            button.contentTintColor = NSColor.white.withAlphaComponent(0.45)
            button.target = self; button.action = action; button.toolTip = label; button.setAccessibilityLabel(label)
            addSubview(button)
        }
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        body.isEditable = false; body.isSelectable = true; body.isRichText = false; body.drawsBackground = false
        body.font = .systemFont(ofSize: 15); body.textColor = .labelColor
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        body.defaultParagraphStyle = paragraph
        body.textContainerInset = NSSize(width: 2, height: 3)
        body.isVerticallyResizable = true; body.isHorizontallyResizable = false
        body.autoresizingMask = [.width]; body.textContainer?.widthTracksTextView = true
        body.setAccessibilityLabel("Reply text")
        scroll.documentView = body; addSubview(scroll)
        continueButton.title = "Continue"
        continueButton.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        continueButton.imagePosition = .imageLeading; continueButton.isBordered = false
        continueButton.font = .systemFont(ofSize: 11, weight: .medium)
        continueButton.contentTintColor = NSColor.white.withAlphaComponent(0.78)
        continueButton.toolTip = "Continue in voice · explain this visual with the red guide cursor"
        continueButton.setAccessibilityLabel("Continue in voice with this visual")
        continueButton.target = self; continueButton.action = #selector(continueInVoice)
        continueButton.isHidden = true; addSubview(continueButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        copyButton.frame = NSRect(x: bounds.width - 38, y: bounds.height - 40, width: 24, height: 24)
        let footer: CGFloat = continueButton.isHidden ? 0 : 32
        continueButton.frame = NSRect(x: 18, y: 10, width: 100, height: 24)
        scroll.frame = NSRect(x: 20, y: 17 + footer, width: bounds.width - 58, height: max(30, bounds.height - 34 - footer))
        body.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, body.frame.height)))
    }
    func show(_ value: String, live: Bool, canContinue: Bool = false) {
        let continuing = live && !text.isEmpty && value.hasPrefix(text)
        let atBottom = scroll.contentView.bounds.maxY >= body.bounds.maxY - 28
        text = value; copyButton.toolTip = "Copy reply"
        continueButton.isHidden = !canContinue
        body.string = value; copyButton.isEnabled = !value.isEmpty
        needsLayout = true; layoutSubtreeIfNeeded()
        if continuing && atBottom { body.scrollToEndOfDocument(nil) }
        else if !continuing { body.scrollToBeginningOfDocument(nil) }
    }
    @objc private func continueInVoice() { onContinue?() }
    @objc private func copyReply() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        copyButton.toolTip = "Copied"
    }
}

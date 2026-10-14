import AppKit
import SwiftUI

@MainActor
final class SuggestionOverlay {
    private let panel: NSPanel
    private let inlinePanel: NSPanel
    private let ghost = GhostTextView()

    init() {
        panel = Self.makePanel()
        panel.hasShadow = true
        inlinePanel = Self.makePanel()
        inlinePanel.hasShadow = false
        inlinePanel.contentView = ghost
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        return panel
    }

    /// Draws the continuation as gray text directly after the caret, in the field's own
    /// font, scaled to the caret's on-screen line height. Returns the prefix actually
    /// shown: only whole Tab-acceptance chunks that fit inside the field, so what the
    /// user sees is exactly what Tab and grave accept. Empty means nothing fits.
    func showInline(_ suggestion: String, at caret: CGRect, metrics: InlineMetrics) -> String {
        panel.orderOut(nil)
        let lineHeight = caret.height
        guard lineHeight > 2, let primaryScreen = NSScreen.screens.first else { inlinePanel.orderOut(nil); return "" }
        let font = Self.font(for: metrics, lineHeight: lineHeight)
        let base = metrics.color.flatMap { NSColor(cgColor: $0) } ?? .labelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: base.withAlphaComponent(0.45)]
        let fieldRight = metrics.fieldFrame.map { $0.maxX - 4 }
        func width(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: attributes).width) }
        func fit(_ available: CGFloat?, trimLeading: Bool) -> String {
            var shown = ""
            var remaining = Substring(suggestion)
            while true {
                let chunk = PredictionPrompt.nextWord(String(remaining), trailingSpace: false, punctuation: true)
                guard !chunk.isEmpty, remaining.hasPrefix(chunk) else { break }
                let candidate = shown + chunk
                let drawn = trimLeading ? String(candidate.drop(while: \.isWhitespace)) : candidate
                if let available, width(drawn) > available { break }
                shown = candidate
                remaining = remaining.dropFirst(chunk.count)
            }
            return shown
        }
        var origin = CGPoint(x: caret.maxX, y: caret.minY)
        var shown = fit(fieldRight.map { $0 - caret.maxX }, trimLeading: false)
        var drawn = shown
        // No room left on this line: the app would wrap, so draw on the next visual line.
        if shown.isEmpty, let fieldRight, let lineStart = metrics.lineStartX {
            shown = fit(fieldRight - lineStart, trimLeading: true)
            drawn = String(shown.drop(while: \.isWhitespace))
            origin = CGPoint(x: lineStart, y: caret.maxY)
        }
        guard !drawn.isEmpty else { inlinePanel.orderOut(nil); return "" }
        ghost.text = NSAttributedString(string: drawn, attributes: attributes)
        ghost.lineHeight = lineHeight
        let size = CGSize(width: width(drawn) + 2, height: lineHeight)
        // AX uses a top-left origin on the primary display; AppKit uses a bottom-left origin.
        let frame = CGRect(x: origin.x, y: primaryScreen.frame.maxY - origin.y - lineHeight,
                           width: size.width, height: size.height)
        inlinePanel.setFrame(frame, display: true)
        ghost.needsDisplay = true
        inlinePanel.orderFrontRegardless()
        return shown
    }

    /// The field's reported font, scaled so its line height matches the caret's
    /// on-screen line (window zoom and Retina scaling change pixels, not AX points).
    private static func font(for metrics: InlineMetrics, lineHeight: CGFloat) -> NSFont {
        let layout = NSLayoutManager()
        if let size = metrics.fontSize, size > 0 {
            let reported = metrics.fontName.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
            let scale = lineHeight / layout.defaultLineHeight(for: reported)
            return (0.6...3).contains(scale) ? reported.withSize(size * scale) : reported
        }
        let reference = NSFont.systemFont(ofSize: 13)
        return reference.withSize(13 * lineHeight / layout.defaultLineHeight(for: reference))
    }

    func show(_ suggestion: String, at caret: CGRect, hint: String) {
        inlinePanel.orderOut(nil)
        let display = String(suggestion.prefix(150))
        let height: CGFloat = 45
        // Measure the whole pill, including the hint. Only a suggestion wider than the
        // cap is truncated; an estimate from the suggestion alone hid short words.
        let natural = NSHostingView(rootView: pill(display, hint: hint, width: nil, height: height).fixedSize()).fittingSize.width
        let width = min(560, max(180, ceil(natural)))
        panel.contentView = NSHostingView(rootView: pill(display, hint: hint, width: width, height: height))

        let screens = NSScreen.screens
        guard let primaryScreen = screens.first else { return }
        // AX uses a top-left origin on the primary display; AppKit uses a bottom-left origin.
        let caretPoint = CGPoint(x: caret.midX, y: primaryScreen.frame.maxY - caret.midY)
        let screen = screens.first { $0.frame.contains(caretPoint) } ?? primaryScreen
        let frame = screen.visibleFrame
        let position = CGPoint(x: caret.maxX + 5, y: primaryScreen.frame.maxY - caret.maxY - height - 5)
        let x = min(max(frame.minX + 6, position.x), frame.maxX - width - 6)
        let y = min(max(frame.minY + 6, position.y), frame.maxY - height - 6)
        panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    private func pill(_ display: String, hint: String, width: CGFloat?, height: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text(display)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(hint)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.65, green: 0.83, blue: 0.81))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(red: 0.11, green: 0.16, blue: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(red: 0.26, green: 0.45, blue: 0.44), lineWidth: 1))
    }

    func hide() {
        panel.orderOut(nil)
        inlinePanel.orderOut(nil)
    }
}

private final class GhostTextView: NSView {
    var text = NSAttributedString()
    var lineHeight: CGFloat = 0
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let natural = text.size().height
        // Center the glyph line in the caret's line box; extra line spacing splits evenly.
        text.draw(at: CGPoint(x: 0, y: max(0, (lineHeight - natural) / 2)))
    }
}

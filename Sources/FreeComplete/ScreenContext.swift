import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

struct ScreenContextKey: Equatable {
    let pid: pid_t
    let window: AXUIElement
    let title: String
    let column: ClosedRange<Int>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && CFEqual(lhs.window, rhs.window)
            && lhs.title == rhs.title && lhs.column == rhs.column
    }
}

struct ScreenTranscriptCache {
    static let freshFor: TimeInterval = 3
    let key: ScreenContextKey
    let date: Date
    let text: String

    func isFresh(for key: ScreenContextKey, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return self.key == key && age >= 0 && age < Self.freshFor
    }
}

/// Opt-in screen reference text. Captures only the window that holds the focused field,
/// cropped to the field's column (the conversation or document the user is replying
/// to), OCRs it accurately in the background, and keeps a cleaned transcript ordered top
/// to bottom. Other apps, the menu bar and the desktop are never in the image. Requests
/// read the latest transcript and never wait for OCR, so typing latency is unchanged.
@MainActor
final class ScreenContext {

    private var cached: ScreenTranscriptCache?
    private var refreshing: Task<Void, Never>?
    private var refreshingKey: ScreenContextKey?
    private var refreshSerial: UInt64 = 0
    private nonisolated static let budget = 1_200

    /// Latest transcript for this field and when it was captured, or nil. Starts a
    /// background refresh when stale.
    func transcript(pid: pid_t, element: AXUIElement, caret: CGRect, field: CGRect?) -> (text: String, capturedAt: Date)? {
        guard CGPreflightScreenCaptureAccess(),
              let key = Self.key(pid: pid, element: element, caret: caret, field: field) else {
            clearCache()
            return nil
        }
        let current = cached
        let stale = current?.isFresh(for: key, now: Date()) != true
        if stale, refreshing == nil || refreshingKey != key {
            refreshing?.cancel()
            refreshSerial &+= 1
            let serial = refreshSerial
            refreshingKey = key
            refreshing = Task { @MainActor [weak self] in
                let capture = await Self.capture(key: key, caret: caret, field: field)
                guard let self, !Task.isCancelled, self.refreshSerial == serial else { return }
                defer {
                    self.refreshing = nil
                    self.refreshingKey = nil
                }
                guard Self.key(pid: pid, element: element, caret: caret, field: field) == key else {
                    self.cached = nil
                    return
                }
                if let capture {
                    self.cached = ScreenTranscriptCache(key: key, date: capture.capturedAt, text: capture.text)
                }
            }
        }
        guard let current, current.isFresh(for: key, now: Date()), !current.text.isEmpty else { return nil }
        return (current.text, current.date)
    }

    func clearCache() {
        refreshSerial &+= 1
        refreshingKey = nil
        refreshing?.cancel()
        refreshing = nil
        cached = nil
    }

    private static func key(pid: pid_t, element: AXUIElement, caret: CGRect, field: CGRect?) -> ScreenContextKey? {
        func windowAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let focused = windowAttribute(application, kAXFocusedWindowAttribute),
              let window = windowAttribute(element, kAXWindowAttribute), CFEqual(focused, window) else { return nil }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else { return nil }
        let column = field ?? caret
        return ScreenContextKey(pid: pid, window: window, title: title,
            column: Int(column.minX)...Int(max(column.minX + 1, column.maxX)))
    }

    private static func capture(key: ScreenContextKey, caret: CGRect, field: CGRect?) async -> (text: String, capturedAt: Date)? {
        do {
            let available = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            let point = CGPoint(x: caret.midX, y: caret.midY)
            // Require an unambiguous window matching the focused AX window's title,
            // owner and caret. Decline ambiguous windows rather than OCR another one.
            let matches = available.windows.filter {
                $0.owningApplication?.processID == key.pid && $0.windowLayer == 0
                    && ($0.title ?? "") == key.title && $0.frame.contains(point)
            }
            guard matches.count == 1, let window = matches.first else { return nil }
            let frame = window.frame
            let columnRect = field ?? caret
            let margin: CGFloat = 40
            let left = max(frame.minX, columnRect.minX - margin)
            let right = min(frame.maxX, max(columnRect.maxX, caret.maxX) + margin)
            guard right - left > 20 else { return nil }
            // Window-local crop of the window's full height around the field column.
            let source = CGRect(x: left - frame.minX, y: 0, width: right - left, height: frame.height)
            let config = SCStreamConfiguration()
            config.sourceRect = source
            let pixelScale = min(2.0, 2_400 / max(source.width, source.height))
            config.width = max(1, Int(source.width * pixelScale))
            config.height = max(1, Int(source.height * pixelScale))
            config.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let capturedAt = Date()
            try Task.checkCancellation()
            // The field's own text is already the writing; only its surroundings add context.
            let fieldInCrop = field.map {
                CGRect(x: ($0.minX - left) / source.width, y: ($0.minY - frame.minY) / source.height,
                       width: $0.width / source.width, height: $0.height / source.height)
            }
            let caretY = (caret.midY - frame.minY) / source.height
            let transcription = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try Self.transcribe(image, excludingTopLeft: fieldInCrop, caretY: caretY)
            }
            return try await withTaskCancellationHandler {
                let text = try await transcription.value
                try Task.checkCancellation()
                return (text, capturedAt)
            } onCancel: { transcription.cancel() }
        } catch {
            return nil
        }
    }

    private struct Fragment {
        let text: String
        let minX: CGFloat
        let top: CGFloat      // top-left normalized coordinates
        let bottom: CGFloat
    }

    private nonisolated static let trailingTime = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:[01]?\d|2[0-3]):[0-5]\d(?:\s*[AaPp]\.?[Mm]\.?)?\s*$"#)

    /// Accurate OCR, then cleanup: drop low-confidence, numeric-only and timestamp noise,
    /// skip the field itself, rebuild visual lines, and keep the lines nearest the caret.
    nonisolated static func transcribe(_ image: CGImage, excludingTopLeft field: CGRect?,
                                       caretY: CGFloat) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: image).perform([request])
        var fragments: [Fragment] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { continue }
            let box = observation.boundingBox  // bottom-left normalized
            let top = 1 - box.maxY
            let bottom = 1 - box.minY
            if let field, field.contains(CGPoint(x: box.midX, y: (top + bottom) / 2)) { continue }
            var text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(text.startIndex..., in: text)
            text = trailingTime.stringByReplacingMatches(in: text, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.contains(where: \.isLetter) else { continue }
            fragments.append(Fragment(text: text, minX: box.minX, top: top, bottom: bottom))
        }
        // Group fragments into visual lines: same line when vertical centers are close.
        fragments.sort { $0.top < $1.top }
        var lines: [[Fragment]] = []
        for fragment in fragments {
            let center = (fragment.top + fragment.bottom) / 2
            if let last = lines.last?.first, abs((last.top + last.bottom) / 2 - center) < 0.01 {
                lines[lines.count - 1].append(fragment)
            } else {
                lines.append([fragment])
            }
        }
        let rendered = lines.map { line -> (text: String, center: CGFloat) in
            let text = line.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: " ")
            let center = line.map { ($0.top + $0.bottom) / 2 }.reduce(0, +) / CGFloat(line.count)
            return (text, center)
        }
        // Budget goes to the lines closest to the caret (the message being answered),
        // then the kept lines return to reading order.
        var kept = Set<Int>()
        var used = 0
        for index in rendered.indices.sorted(by: { abs(rendered[$0].center - caretY) < abs(rendered[$1].center - caretY) }) {
            let cost = rendered[index].text.count + 1
            if used + cost > budget { continue }
            kept.insert(index)
            used += cost
        }
        return rendered.indices.filter(kept.contains).map { rendered[$0].text }.joined(separator: "\n")
    }
}

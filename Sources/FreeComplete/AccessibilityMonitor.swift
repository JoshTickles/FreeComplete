import AppKit
import ApplicationServices
import Carbon

struct TextSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let appID: String
    let appName: String
    let siteDomains: [String]
    let siteDomain: String?
    let isWebContent: Bool
    let before: String
    let after: String
    let selected: String
    let range: CFRange
    let caret: CGRect

    var fingerprint: String { "\(pid):\(siteDomains):\(siteDomain ?? ""):\(isWebContent):\(range.location):\(range.length):\(before):\(selected):\(after)" }
}

/// What the focused field reports about how its text looks at the caret. Every
/// value is optional: apps expose different subsets, and callers fall back.
struct InlineMetrics {
    let fontName: String?
    let fontSize: CGFloat?
    let color: CGColor?
    /// Field frame in AX (top-left origin) screen coordinates.
    let fieldFrame: CGRect?
    /// Left edge of the caret's visual line, in AX screen coordinates.
    let lineStartX: CGFloat?
}

@MainActor
protocol TextObserver: AnyObject {
    func textDidChange(_ snapshot: TextSnapshot?)
    func invalidateSuggestion()
    func hasAcceptableSuggestion() -> Bool
    func acceptSuggestion(full: Bool) -> Bool
    func dismissSuggestion() -> Bool
    func requestAlternatives() -> Bool
    func hasSelectableAlternative(_ index: Int) -> Bool
    func selectAlternative(_ index: Int) -> Bool
    func requestRewrite(correction: Bool) -> Bool
}

@MainActor
final class AccessibilityMonitor {
    weak var delegate: TextObserver?
    private var tap: CFMachPort?
    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var observedApp: AXUIElement?
    private var currentPID: pid_t = 0
    private var refreshTask: Task<Void, Never>?
    private var activatedToken: NSObjectProtocol?
    private var focusedSnapshot: TextSnapshot?

    var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    func start() -> Bool {
        guard isTrusted else { return false }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        activatedToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.watchFrontmostApp() }
        }
        watchFrontmostApp()
        installTap()
        guard tap != nil else { stop(); return false }
        return true
    }

    func stop() {
        refreshTask?.cancel()
        if let token = activatedToken { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        activatedToken = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        self.tap = nil
        removeObserver()
        focusedSnapshot = nil
        delegate?.textDidChange(nil)
    }

    func scheduleRefresh(force: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            // Read as soon as the app has applied the key; Chromium and Electron can publish
            // the edit a beat later, so a second read catches it (unchanged text is ignored).
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled else { return }
            self?.refresh(force: force)
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refresh(force: false)
        }
    }

    private func watchFrontmostApp() {
        removeObserver()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            focusedSnapshot = nil
            delegate?.textDidChange(nil)
            return
        }
        currentPID = app.processIdentifier
        let application = AXUIElementCreateApplication(currentPID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        observedApp = application
        // Electron apps (Slack, Ferdium, Discord, VS Code…) expose no text fields until an
        // assistive client asks with Electron's documented AXManualAccessibility switch.
        // Other apps answer "unsupported". The tree then builds asynchronously.
        let enabledElectronTree = AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        var created: AXObserver?
        if AXObserverCreate(currentPID, { _, _, _, userData in
            guard let userData else { return }
            let monitor = Unmanaged<AccessibilityMonitor>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { monitor.refreshAfterNotification() }
        }, &created) == .success, let created {
            observer = created
            let source = AXObserverGetRunLoopSource(created)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            AXObserverAddNotification(created, application, kAXFocusedUIElementChangedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
            AXObserverAddNotification(created, application, kAXFocusedWindowChangedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
        refresh()
        if enabledElectronTree {
            let pid = currentPID
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.currentPID == pid else { return }
                self.refresh()
            }
        }
    }

    private func refreshAfterNotification() {
        refresh()
    }

    private func removeObserver() {
        if let observer {
            if let observedElement {
                AXObserverRemoveNotification(observer, observedElement, kAXValueChangedNotification as CFString)
                AXObserverRemoveNotification(observer, observedElement, kAXSelectedTextChangedNotification as CFString)
                AXObserverRemoveNotification(observer, observedElement, kAXUIElementDestroyedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedElement = nil
        observedApp = nil
        currentPID = 0
    }

    private func refresh(force: Bool = false) {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier == currentPID,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let appID = app.bundleIdentifier, let application = observedApp else {
            focusedSnapshot = nil
            delegate?.textDidChange(nil)
            return
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            Trace.log("read \(appID): no focused element")
            focusedSnapshot = nil
            delegate?.textDidChange(nil)
            return
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        if observedElement == nil || !CFEqual(observedElement, element) {
            if let observer, let observedElement {
                AXObserverRemoveNotification(observer, observedElement, kAXValueChangedNotification as CFString)
                AXObserverRemoveNotification(observer, observedElement, kAXSelectedTextChangedNotification as CFString)
                AXObserverRemoveNotification(observer, observedElement, kAXUIElementDestroyedNotification as CFString)
            }
            observedElement = element
            if let observer {
                for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification,
                             kAXUIElementDestroyedNotification] {
                    AXObserverAddNotification(observer, element, name as CFString,
                                              Unmanaged.passUnretained(self).toOpaque())
                }
            }
        }
        let snapshot = read(element: element, pid: currentPID, appID: appID, appName: app.localizedName ?? appID)
        if force || snapshot?.fingerprint != focusedSnapshot?.fingerprint {
            focusedSnapshot = snapshot
            delegate?.textDidChange(snapshot)
        }
    }

    private func read(element: AXUIElement, pid: pid_t, appID: String, appName: String) -> TextSnapshot? {
        func fail(_ reason: String) -> TextSnapshot? {
            Trace.log("read \(appID): \(reason)")
            return nil
        }
        guard !IsSecureEventInputEnabled() else { return fail("secure input active") }
        let role = stringAttribute(kAXRoleAttribute, on: element) ?? "none"
        guard [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) else {
            // Rich web editors (contenteditable in browsers, Electron and WebKit apps) focus
            // a group or the web area. They expose their text only through text markers.
            if let root = editableRoot(of: element) {
                return markerSnapshot(root: root, focused: element, pid: pid, appID: appID, appName: appName)
                    ?? fail("editable \(role) without readable text markers")
            }
            return fail("focused role \(role) is not a text field")
        }
        var subrole: CFTypeRef?
        let subroleStatus = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subroleStatus == .success || subroleStatus == .noValue || subroleStatus == .attributeUnsupported,
              (subrole as? String) != (kAXSecureTextFieldSubrole as String) else { return fail("secure field") }
        var rangeRef: CFTypeRef?
        let rangeStatus = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard rangeStatus == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return fail("no selected range (AXError \(rangeStatus.rawValue))")
        }
        let rangeValue = rangeRef as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0,
              range.length >= 0 else { return fail("invalid selected range") }
        var countRef: CFTypeRef?
        let countStatus = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef)
        guard countStatus == .success, let count = countRef as? Int, count >= 0, range.location <= count,
              range.length <= count - range.location else {
            return fail("character count unusable (AXError \(countStatus.rawValue), caret \(range.location))")
        }
        let beforeStart = max(0, range.location - 1200)
        guard let before = text(in: CFRange(location: beforeStart, length: range.location - beforeStart), on: element) else {
            return fail("cannot read text before caret (caret \(range.location) of \(count))")
        }
        let selected = range.length > 0 ? text(in: range, on: element) : ""
        guard let selected, selected.utf16.count == range.length else { return fail("cannot read selection") }
        let afterLength = min(180, count - range.location - range.length)
        let after = text(in: CFRange(location: range.location + range.length, length: afterLength), on: element) ?? ""
        guard let caret = caretRect(on: element, at: range.location, count: count, previous: before.last)
                ?? markerCaret(on: element) else {
            return fail("no caret position (caret \(range.location) of \(count))")
        }
        let site = siteContext(on: element)
        return TextSnapshot(element: element, pid: pid, appID: appID, appName: appName,
                            siteDomains: site.domains, siteDomain: site.domain, isWebContent: site.web,
                            before: before, after: after, selected: selected, range: range, caret: caret)
    }

    private func elementAttribute(_ name: String, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The outermost editable element containing the focus, when the focus is inside an editor.
    private func editableRoot(of element: AXUIElement) -> AXUIElement? {
        elementAttribute("AXHighestEditableAncestor", on: element) ?? elementAttribute("AXEditableAncestor", on: element)
    }

    private func markerParameter(_ name: String, _ parameter: CFTypeRef, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success
        else { return nil }
        return value
    }

    private func selectionMarkers(_ elements: [AXUIElement]) -> AXTextMarkerRange? {
        for element in elements {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() {
                return (value as! AXTextMarkerRange)
            }
        }
        return nil
    }

    private func markerRect(_ range: AXTextMarkerRange, on element: AXUIElement) -> CGRect? {
        guard let value = markerParameter("AXBoundsForTextMarkerRange", range, on: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.isFinite,
              rect.height > 2, rect.height < 100 else { return nil }
        return rect
    }

    /// Caret from text markers: the right edge of the character before the caret, else the
    /// collapsed selection. Chromium fields can provide this when range bounds fail.
    private func markerCaret(on element: AXUIElement, root: AXUIElement? = nil) -> CGRect? {
        let owner = root ?? element
        guard let selection = selectionMarkers([element, owner]) else { return nil }
        let caret = AXTextMarkerRangeCopyStartMarker(selection)
        if let previous = markerParameter("AXPreviousTextMarkerForTextMarker", caret, on: owner),
           CFGetTypeID(previous) == AXTextMarkerGetTypeID(),
           var rect = markerRect(AXTextMarkerRangeCreate(nil, previous as! AXTextMarker, caret), on: owner),
           rect.width < 300 {
            rect.origin.x = rect.maxX
            rect.size.width = 0
            return rect
        }
        if var rect = markerRect(AXTextMarkerRangeCreate(nil, caret, caret), on: owner) ?? markerRect(selection, on: owner),
           rect.width < 300 {
            rect.size.width = 0
            return rect
        }
        return nil
    }

    private func markerString(_ range: AXTextMarkerRange, on element: AXUIElement) -> String? {
        markerParameter("AXStringForTextMarkerRange", range, on: element) as? String
    }

    /// Reads a rich editor through text markers. The editor root stands in for the field:
    /// offsets count UTF-16 units from its start, so the same edit checks still apply.
    private func markerSnapshot(root: AXUIElement, focused: AXUIElement, pid: pid_t,
                                appID: String, appName: String) -> TextSnapshot? {
        AXUIElementSetMessagingTimeout(root, 0.25)
        guard let selection = selectionMarkers([focused, root]),
              let whole = markerParameter("AXTextMarkerRangeForUIElement", root, on: root),
              CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID() else { return nil }
        let wholeRange = whole as! AXTextMarkerRange
        let start = AXTextMarkerRangeCopyStartMarker(selection)
        let end = AXTextMarkerRangeCopyEndMarker(selection)
        guard let fullBefore = markerString(AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyStartMarker(wholeRange), start), on: root),
              let selected = markerString(selection, on: root),
              let caret = markerCaret(on: focused, root: root) else { return nil }
        let fullAfter = markerString(AXTextMarkerRangeCreate(nil, end, AXTextMarkerRangeCopyEndMarker(wholeRange)), on: root) ?? ""
        let before = String(decoding: fullBefore.utf16.suffix(1_200), as: UTF16.self)
        let site = siteContext(on: root)
        return TextSnapshot(element: root, pid: pid, appID: appID, appName: appName,
                            siteDomains: site.domains, siteDomain: site.domain, isWebContent: site.web,
                            before: before, after: String(fullAfter.prefix(180)), selected: selected,
                            range: CFRange(location: fullBefore.utf16.count, length: selected.utf16.count), caret: caret)
    }

    private func stringAttribute(_ name: String, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func siteContext(on element: AXUIElement) -> (domains: [String], domain: String?, web: Bool) {
        var ancestor = element
        var domains: [String] = []
        var web = false
        for _ in 0..<48 {
            AXUIElementSetMessagingTimeout(ancestor, 0.25)
            let role = stringAttribute(kAXRoleAttribute, on: ancestor)
            if role == "AXWebArea" { web = true }
            for name in [kAXURLAttribute, kAXDocumentAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(ancestor, name as CFString, &value) == .success,
                   let value {
                    let document = (value as? URL)?.absoluteString ?? (value as? String)
                    if let document, let domain = SiteDomain.fromDocumentURL(document) {
                        web = true
                        if domains.last != domain { domains.append(domain) }
                    }
                }
            }
            if role == (kAXApplicationRole as String) {
                return (domains, domains.last, web)
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ancestor, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID(),
                  !CFEqual(parent, ancestor) else {
                // An incomplete chain cannot establish that an observed host is the outermost site.
                return (domains, nil, true)
            }
            ancestor = parent as! AXUIElement
        }
        // A deep web tree may hide an outer page beyond the cap.
        return (domains, nil, true)
    }

    private func text(in range: CFRange, on element: AXUIElement) -> String? {
        var query = range
        guard let parameter = AXValueCreate(.cfRange, &query) else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                      parameter, &value) == .success {
            guard let text = value as? String, text.utf16.count == range.length else { return nil }
            return text
        }
        // Some editors expose only AXValue. Keep the fallback bounded after reading.
        guard range.location >= 0, range.length >= 0,
              let whole = stringAttribute(kAXValueAttribute, on: element),
              range.location <= (whole as NSString).length,
              range.length <= (whole as NSString).length - range.location else { return nil }
        return (whole as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }
    /// Caret rectangle in AX screen coordinates. Uses the glyph before the caret when it
    /// is an ordinary character. After a newline (whose box spans the whole line) or at
    /// the start of a field, it uses the zero-length range at the caret, then the glyph
    /// after it.
    private func caretRect(on element: AXUIElement, at location: Int, count: Int, previous: Character?) -> CGRect? {
        func bounds(_ location: Int, _ length: Int) -> CGRect? {
            var range = CFRange(location: location, length: length)
            guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                             parameter, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.isFinite,
                  rect.height > 2, rect.height < 100 else { return nil }
            return rect
        }
        if let previous, !previous.isNewline, location > 0,
           var rect = bounds(location - 1, 1), rect.width < 300 {
            rect.origin.x = rect.maxX
            rect.size.width = 0
            return rect
        }
        if var rect = bounds(location, 0) {
            rect.size.width = 0
            return rect
        }
        if location < count, var rect = bounds(location, 1), rect.width < 300 {
            rect.size.width = 0
            return rect
        }
        return nil
    }

    func inlineMetrics(for snapshot: TextSnapshot) -> InlineMetrics {
        let element = snapshot.element
        let location = snapshot.range.location
        var fontName: String?
        var fontSize: CGFloat?
        var color: CGColor?
        if location > 0, let value = parameterized(kAXAttributedStringForRangeParameterizedAttribute,
                                                    range: CFRange(location: location - 1, length: 1), on: element),
           CFGetTypeID(value) == CFAttributedStringGetTypeID() {
            let string = value as! NSAttributedString
            if string.length > 0 {
                let attributes = string.attributes(at: 0, effectiveRange: nil)
                // AX text-attribute keys from AXTextAttributedString.h.
                if let font = attributes[NSAttributedString.Key("AXFont")] as? [String: Any] {
                    fontName = font["AXFontName"] as? String
                    fontSize = (font["AXFontSize"] as? NSNumber).map { CGFloat($0.doubleValue) }
                }
                if let raw = attributes[NSAttributedString.Key("AXForegroundColor")],
                   CFGetTypeID(raw as CFTypeRef) == CGColor.typeID {
                    color = (raw as! CGColor)
                }
            }
        }
        var fieldFrame: CGRect?
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let positionRef, let sizeRef,
           CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            var origin = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
               AXValueGetValue(sizeRef as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 {
                fieldFrame = CGRect(origin: origin, size: size)
            }
        }
        // The visual line can start mid-paragraph when the field soft-wraps.
        var lineStartX: CGFloat?
        let index = max(0, location - 1)
        var lineRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXLineForIndexParameterizedAttribute as CFString,
                                                      NSNumber(value: index), &lineRef) == .success,
           let line = lineRef as? Int,
           let lineRangeRef = parameterizedLine(kAXRangeForLineParameterizedAttribute, line: line, on: element),
           CFGetTypeID(lineRangeRef) == AXValueGetTypeID() {
            var lineRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(lineRangeRef as! AXValue, .cfRange, &lineRange), lineRange.length > 0,
               let boundsRef = parameterized(kAXBoundsForRangeParameterizedAttribute,
                                             range: CFRange(location: lineRange.location, length: 1), on: element),
               CFGetTypeID(boundsRef) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.isFinite { lineStartX = rect.minX }
            }
        }
        return InlineMetrics(fontName: fontName, fontSize: fontSize, color: color,
                             fieldFrame: fieldFrame, lineStartX: lineStartX)
    }

    private func parameterized(_ name: String, range: CFRange, on element: AXUIElement) -> CFTypeRef? {
        var query = range
        guard let parameter = AXValueCreate(.cfRange, &query) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success
        else { return nil }
        return value
    }

    private func parameterizedLine(_ name: String, line: Int, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, NSNumber(value: line), &value) == .success
        else { return nil }
        return value
    }

    /// Marks keystrokes FreeComplete types itself, so its own key handler lets them pass.
    static let syntheticEventTag: Int64 = 0x4643_4D50

    func insert(_ text: String, matching snapshot: TextSnapshot) -> Bool {
        let application = AXUIElementCreateApplication(snapshot.pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var focused: CFTypeRef?
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == snapshot.appID,
              AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        // A rich editor's focus can be a child of the editor root the snapshot was read from.
        guard CFEqual(element, snapshot.element) || editableRoot(of: element).map({ CFEqual($0, snapshot.element) }) == true,
              let current = read(element: element, pid: snapshot.pid, appID: snapshot.appID, appName: snapshot.appName),
              current.fingerprint == snapshot.fingerprint else {
            Trace.log("insert refused: field changed since the suggestion")
            return false
        }
        // Web and Electron editors often report success for an Accessibility insert
        // without changing their content, so type there. Native fields take AX directly.
        if !snapshot.isWebContent,
           AXUIElementSetAttributeValue(snapshot.element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            Trace.log("inserted via Accessibility \(text.debugDescription)")
        } else {
            type(text, to: snapshot.pid)
            Trace.log("inserted by typing \(text.debugDescription)")
        }
        scheduleRefresh(force: true)
        return true
    }

    private func type(_ text: String, to pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            // Never split a surrogate pair across events.
            var end = min(index + 16, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[index..<end])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
                event.postToPid(pid)
            }
            index = end
        }
    }

    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, kind, event, userData in
            guard let userData else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<AccessibilityMonitor>.fromOpaque(userData).takeUnretainedValue()
            if kind == .tapDisabledByTimeout || kind == .tapDisabledByUserInput {
                monitor.delegate?.invalidateSuggestion()
                monitor.scheduleRefresh(force: true)
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return monitor.handle(event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func handle(_ event: CGEvent) -> Bool {
        // Keys FreeComplete types to insert a suggestion must not cancel the rest of it.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag { return false }
        if IsSecureEventInputEnabled() {
            delegate?.invalidateSuggestion()
            scheduleRefresh()
            return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let focusedSnapshot,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focusedSnapshot.pid,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == focusedSnapshot.appID else {
            if code == 48 { Trace.log("Tab passed through: no readable text field in the front app") }
            delegate?.invalidateSuggestion()
            scheduleRefresh(force: true)
            return false
        }
        let flags = event.flags
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        if code == 48 && modifiers.isEmpty && !flags.contains(.maskShift) {
            if delegate?.hasAcceptableSuggestion() == true {
                Trace.log("Tab accepted")
                acceptLater(full: false)
                return true
            }
            Trace.log("Tab passed through: no suggestion visible")
        }
        // Use the emitted character for layout-dependent printable shortcuts.
        var character: UniChar = 0
        var length = 0
        if modifiers.isEmpty {
            withUnsafeMutablePointer(to: &character) {
                event.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &length, unicodeString: $0)
            }
        }
        if length == 1 && character == 96 && delegate?.hasAcceptableSuggestion() == true {
            acceptLater(full: true)
            return true
        }
        if modifiers == [.maskControl, .maskAlternate] && code == 1,
           delegate?.requestRewrite(correction: false) == true { return true }
        if modifiers == [.maskControl, .maskAlternate] && code == 8,
           delegate?.requestRewrite(correction: true) == true { return true }
        if code == 53 && modifiers.isEmpty && !flags.contains(.maskShift),
           delegate?.dismissSuggestion() == true { return true }
        if code == 50 && modifiers == [.maskControl, .maskAlternate],
           delegate?.requestAlternatives() == true { return true }
        if length == 1 && (49...51).contains(character) {
            let index = Int(character - 49)
            if delegate?.hasSelectableAlternative(index) == true {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = self.delegate?.selectAlternative(index)
                    self.scheduleRefresh(force: true)
                }
                return true
            }
        }
        // Any event that reaches the application invalidates in-flight and visible completions.
        delegate?.invalidateSuggestion()
        scheduleRefresh()
        return false
    }

    private func acceptLater(full: Bool) {
        // AX site traversal and insertion must not run inside the event-tap deadline.
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = self.delegate?.acceptSuggestion(full: full)
            self.scheduleRefresh(force: true)
        }
    }
}

private extension CGRect {
    var isFinite: Bool { origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite }
}

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
            try? await Task.sleep(for: .milliseconds(190))
            guard !Task.isCancelled else { return }
            self?.refresh(force: force)
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
        guard !IsSecureEventInputEnabled() else { return nil }
        guard let role = stringAttribute(kAXRoleAttribute, on: element),
              [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) else { return nil }
        var subrole: CFTypeRef?
        let subroleStatus = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subroleStatus == .success || subroleStatus == .noValue || subroleStatus == .attributeUnsupported,
              (subrole as? String) != (kAXSecureTextFieldSubrole as String) else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        let rangeValue = rangeRef as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0,
              range.length >= 0 else { return nil }
        var countRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
              let count = countRef as? Int, count >= 0, range.location <= count,
              range.length <= count - range.location else { return nil }
        let beforeStart = max(0, range.location - 1200)
        guard let before = text(in: CFRange(location: beforeStart, length: range.location - beforeStart), on: element) else { return nil }
        let selected = range.length > 0 ? text(in: range, on: element) : ""
        guard let selected, selected.utf16.count == range.length else { return nil }
        let afterLength = min(180, count - range.location - range.length)
        let after = text(in: CFRange(location: range.location + range.length, length: afterLength), on: element) ?? ""
        guard let caret = caretRect(on: element, at: range.location, count: count) else { return nil }
        let site = siteContext(on: element)
        return TextSnapshot(element: element, pid: pid, appID: appID, appName: appName,
                            siteDomains: site.domains, siteDomain: site.domain, isWebContent: site.web,
                            before: before, after: after, selected: selected, range: range, caret: caret)
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
    private func caretRect(on element: AXUIElement, at location: Int, count: Int) -> CGRect? {
        var range = CFRange(location: min(location, max(0, count - 1)), length: count > 0 ? 1 : 0)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rectValue = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(rectValue, .cgRect, &rect), rect.isFinite, rect.width < 300, rect.height < 100 else { return nil }
        if location == count { rect.origin.x = rect.maxX }
        return rect
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

    func insert(_ text: String, matching snapshot: TextSnapshot) -> Bool {
        let application = AXUIElementCreateApplication(snapshot.pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var focused: CFTypeRef?
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == snapshot.appID,
              AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
              CFEqual(focused, snapshot.element) else { return false }
        guard let current = read(element: snapshot.element, pid: snapshot.pid, appID: snapshot.appID,
                                 appName: snapshot.appName), current.fingerprint == snapshot.fingerprint,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == snapshot.appID else { return false }
        let result = AXUIElementSetAttributeValue(snapshot.element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard result == .success else { return false }
        scheduleRefresh(force: true)
        return true
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
        if IsSecureEventInputEnabled() {
            delegate?.invalidateSuggestion()
            scheduleRefresh()
            return false
        }
        guard let focusedSnapshot,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focusedSnapshot.pid,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == focusedSnapshot.appID else {
            delegate?.invalidateSuggestion()
            scheduleRefresh(force: true)
            return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        if code == 48 && modifiers.isEmpty && !flags.contains(.maskShift),
           delegate?.hasAcceptableSuggestion() == true {
            acceptLater(full: false)
            return true
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

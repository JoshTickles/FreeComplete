import AppKit
import ApplicationServices
import Carbon
import Combine

struct AppRule: Codable, Identifiable, Equatable {
    var id: String
    var enabled: Bool = true
    var recordWriting: Bool = true
    var instructions: String = ""
    var configured: Bool? = nil

    /// Password managers and terminals start with suggestions, learning and screen
    /// capture off: their fields hold secrets or commands, not prose. A rule the user
    /// saves for one of these apps overrides the default.
    static let sensitiveAppIDs: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.Passwords", "com.dashlane.Dashlane", "com.lastpass.LastPass",
        "com.callpod.keepermac.lite", "me.proton.pass.electron", "org.keepassxc.keepassxc",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm"
    ]

    static func base(for id: String) -> AppRule {
        let sensitive = sensitiveAppIDs.contains(id)
        return AppRule(id: id, enabled: !sensitive, recordWriting: !sensitive)
    }
}

struct DomainRule: Codable, Identifiable, Equatable {
    var id: String
    var enabled: Bool = true
    var recordWriting: Bool = true
    var instructions: String = ""
    var configured: Bool? = nil
}

/// Screen text the model received for a suggestion, kept so the user can see it.
struct ScreenUse: Equatable {
    let app: String
    let capturedAt: Date
    let text: String
}

private struct Continuation {
    let text: String
    let screen: ScreenUse?
}

private struct PendingRemainder {
    let source: TextSnapshot
    let expectedBefore: String
    let expectedLocation: Int
    let text: String
    let expiresAt: Date
    let screen: ScreenUse?

    func matches(_ next: TextSnapshot) -> Bool {
        Date() < expiresAt && next.pid == source.pid && CFEqual(next.element, source.element)
            && next.siteDomains == source.siteDomains && next.siteDomain == source.siteDomain
            && next.isWebContent == source.isWebContent
            && next.before == expectedBefore && next.after == source.after
            && next.range.location == expectedLocation && next.range.length == 0
    }
}

/// The continuation after a whole visible suggestion, generated while it is on screen.
private struct Prefetch {
    let source: TextSnapshot
    let expectedBefore: String
    var result: Continuation?
    var task: Task<Void, Never>?
    /// Set when the whole visible suggestion is accepted: until then a further Tab
    /// belongs to this result. Bounded so a result that never shows cannot hold Tab.
    var armedUntil: Date?

    func matches(_ next: TextSnapshot) -> Bool {
        next.pid == source.pid && CFEqual(next.element, source.element)
            && next.siteDomains == source.siteDomains && next.siteDomain == source.siteDomain
            && next.isWebContent == source.isWebContent
            && next.before == expectedBefore && next.after == source.after && next.range.length == 0
    }
}

@MainActor
final class AppModel: ObservableObject, TextObserver {
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); refreshCurrent(); preloadModel() } }
    @Published var screenContextEnabled: Bool {
        didSet { defaults.set(screenContextEnabled, forKey: "screenContext"); if !screenContextEnabled { screen.clearCache() } }
    }
    @Published var clipboardContextEnabled: Bool { didSet { defaults.set(clipboardContextEnabled, forKey: "clipboardContext") } }
    @Published var learningEnabled: Bool { didSet { defaults.set(learningEnabled, forKey: "learning"); if !learningEnabled { pendingRecording?.cancel() } } }
    @Published var recordAllWriting: Bool { didSet { defaults.set(recordAllWriting, forKey: "recordAllWriting"); if !recordAllWriting { pendingRecording?.cancel() } } }
    @Published var globalInstructions: String { didSet { defaults.set(globalInstructions, forKey: "instructions") } }
    @Published var appRules: [AppRule] { didSet { saveRules() } }
    @Published var domainRules: [DomainRule] {
        didSet {
            siteRules = domainRules.map { (domain: $0.id, enabled: $0.enabled, recordWriting: $0.recordWriting) }
            saveDomainRules()
        }
    }
    @Published var vocabularyStrength: Int { didSet { defaults.set(vocabularyStrength, forKey: "vocabularyStrength") } }
    @Published var maxWords: Int { didSet { defaults.set(maxWords, forKey: "maxWords") } }
    @Published var trailingSpace: Bool { didSet { defaults.set(trailingSpace, forKey: "trailingSpace") } }
    @Published private(set) var status = "Waiting for Accessibility permission"
    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var acceptedWords: Int
    /// Every Tab, grave, alternative or rewrite the user accepted.
    @Published private(set) var acceptedCompletions: Int
    @Published private(set) var lastApp = "No text field active"
    @Published private(set) var suggestionPreview = ""
    /// Screen text behind the suggestion currently on screen, if any.
    @Published private(set) var suggestionScreen: ScreenUse?
    /// Most recent screen text that reached the model.
    @Published private(set) var lastScreenUse: ScreenUse?
    @Published private(set) var demoOutput = ""
    @Published private(set) var demoBusy = false

    private let defaults = UserDefaults.standard
    private let monitor = AccessibilityMonitor()
    private let inference = LocalInference()
    private let overlay = SuggestionOverlay()
    private let screen = ScreenContext()
    private let history = PersonalizationStore()
    private var pending: Task<Void, Never>?
    private var generationSerial: UInt64 = 0
    private var pendingGeneration: UInt64?
    private var pendingRecording: Task<Void, Never>?
    private var snapshot: TextSnapshot?
    private var suggestion = ""
    private var pendingRemainder: PendingRemainder?
    private var prefetch: Prefetch?
    /// Tab/grave presses that arrived before the next part of the suggestion was on screen.
    private var queuedAccepts: [Bool] = []
    private var pauseUntil: Date = .distantPast
    private var alternativeChoices: [String] = []
    @Published private var observedAppIDs = Set<String>()
    @Published private var observedDomains = Set<String>()
    private var siteRules: [(domain: String, enabled: Bool, recordWriting: Bool)] = []
    private var monitoring = false

    init() {
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        screenContextEnabled = defaults.bool(forKey: "screenContext")
        clipboardContextEnabled = defaults.bool(forKey: "clipboardContext")
        learningEnabled = defaults.bool(forKey: "learning")
        recordAllWriting = defaults.bool(forKey: "recordAllWriting")
        globalInstructions = defaults.string(forKey: "instructions") ?? ""
        vocabularyStrength = max(0, min(3, defaults.object(forKey: "vocabularyStrength") as? Int ?? 2))
        maxWords = max(1, min(12, defaults.integer(forKey: "maxWords") == 0 ? 4 : defaults.integer(forKey: "maxWords")))
        trailingSpace = defaults.bool(forKey: "trailingSpace")
        acceptedWords = defaults.integer(forKey: "acceptedWords")
        acceptedCompletions = defaults.integer(forKey: "acceptedCompletions")
        accessibilityGranted = monitor.isTrusted
        let oldAppRules = defaults.data(forKey: "appRules").flatMap { try? JSONDecoder().decode([AppRule].self, from: $0) } ?? []
        appRules = oldAppRules.filter {
            $0.configured == true || !$0.enabled || !$0.recordWriting || !$0.instructions.isEmpty
        }.map {
            var configured = $0
            configured.configured = true
            return configured
        }
        let oldDomainRules = defaults.data(forKey: "domainRules").flatMap {
            try? JSONDecoder().decode([DomainRule].self, from: $0)
        } ?? []
        domainRules = oldDomainRules.filter {
            $0.configured == true || !$0.enabled || !$0.recordWriting || !$0.instructions.isEmpty
        }.map {
            var configured = $0
            configured.configured = true
            return configured
        }
        if appRules != oldAppRules { saveRules() }
        if domainRules != oldDomainRules { saveDomainRules() }
        siteRules = domainRules.map { (domain: $0.id, enabled: $0.enabled, recordWriting: $0.recordWriting) }
        monitor.delegate = self
        if accessibilityGranted {
            monitoring = monitor.start()
            status = monitoring ? "Ready" : "Keyboard interception unavailable"
            preloadModel()
        }
    }

    var screenGranted: Bool { CGPreflightScreenCaptureAccess() }
    var learnedCount: Int { history.count }
    var runtimeStatus: String { inference.state }

    var historyError: String? { history.lastError }
    var displayedAppRules: [AppRule] {
        Array(Set(appRules.map(\.id)).union(observedAppIDs)).sorted()
            .map(rule(for:))
    }

    /// The saved rule for an app, or its default (off for password managers and terminals).
    func rule(for appID: String) -> AppRule {
        appRules.first(where: { $0.id == appID }) ?? AppRule.base(for: appID)
    }

    var displayedDomainRules: [DomainRule] {
        Array(Set(domainRules.map(\.id)).union(observedDomains)).sorted()
            .map { id in domainRules.first(where: { $0.id == id }) ?? DomainRule(id: id) }
    }

    func hasAppRule(_ id: String) -> Bool { appRules.contains { $0.id == id } }
    func hasDomainRule(_ id: String) -> Bool { domainRules.contains { $0.id == id } }

    func domainAllowsSuggestions(_ domain: String) -> Bool {
        !domainRules.contains { !$0.enabled && SiteDomain.matches(host: domain, rule: $0.id) }
    }

    func domainAllowsRecording(_ domain: String) -> Bool {
        domainAllowsSuggestions(domain)
            && !domainRules.contains { !$0.recordWriting && SiteDomain.matches(host: domain, rule: $0.id) }
    }

    func hasDisabledParentDomain(_ domain: String) -> Bool {
        domainRules.contains { $0.id != domain && !$0.enabled && SiteDomain.matches(host: domain, rule: $0.id) }
    }

    func hasExcludedParentDomain(_ domain: String) -> Bool {
        domainRules.contains {
            $0.id != domain && (!$0.enabled || !$0.recordWriting)
                && SiteDomain.matches(host: domain, rule: $0.id)
        }
    }

    func demoComplete(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            demoOutput = ""
            return
        }
        demoBusy = true
        demoOutput = ""
        defer { demoBusy = false }
        let context = PredictionContext(before: text, after: "", appName: "FreeComplete demo",
                                        appID: "app.freecomplete.demo", visibleText: nil, clipboard: nil,
                                        siteDomain: nil)
        let options = PredictionOptions(globalInstructions: globalInstructions, appInstructions: "",
                                        domainInstructions: "", vocabularyStrength: 0,
                                        vocabulary: "", maxWords: maxWords)
        do {
            let raw = try await inference.generate(
                prompt: PredictionPrompt.make(context: context, options: options, kind: .continuation),
                maxTokens: maxWords, maxWords: maxWords, kind: .continuation)
            demoOutput = PredictionPrompt.clean(raw, maxWords: maxWords)
        } catch {
            if !(error is CancellationError) { status = "Local model: \(error.localizedDescription)" }
        }
        objectWillChange.send()
    }

    func clearDemo() { demoOutput = "" }
    func checkPermission() {
        let granted = monitor.isTrusted
        if accessibilityGranted != granted { accessibilityGranted = granted }
        if granted && !monitoring {
            monitoring = monitor.start()
            status = monitoring ? "Ready" : "Keyboard interception unavailable"
            preloadModel()
        } else if !granted && monitoring {
            monitor.stop()
            monitoring = false
            status = "Allow Accessibility in System Settings to use autocomplete"
        } else if !granted && status != "Allow Accessibility in System Settings to use autocomplete" {
            status = "Allow Accessibility in System Settings to use autocomplete"
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestScreenAccess() {
        if screenContextEnabled && !screenGranted { _ = CGRequestScreenCaptureAccess() }
    }

    func clearLearning() {
        history.clear()
        objectWillChange.send()
    }

    func stop() {
        pending?.cancel()
        pendingGeneration = nil
        pendingRemainder = nil
        cancelPrefetch()
        pendingRecording?.cancel()
        monitor.stop()
        overlay.hide()
        inference.stop()
    }

    func setRule(_ rule: AppRule) {
        var configured = rule
        configured.configured = true
        if let index = appRules.firstIndex(where: { $0.id == rule.id }) { appRules[index] = configured }
        else { appRules.append(configured) }
        refreshCurrent()
    }

    func removeRule(id: String) {
        appRules.removeAll { $0.id == id }
        refreshCurrent()
    }
    func setDomainRule(_ rule: DomainRule) {
        var configured = rule
        configured.configured = true
        if let index = domainRules.firstIndex(where: { $0.id == rule.id }) { domainRules[index] = configured }
        else { domainRules.append(configured) }
        refreshCurrent()
    }

    func addDomain(_ input: String) -> Bool {
        guard let domain = SiteDomain.fromUserInput(input) else { return false }
        if let index = domainRules.firstIndex(where: { $0.id == domain }) {
            domainRules[index].configured = true
        } else {
            domainRules.append(DomainRule(id: domain, configured: true))
        }
        refreshCurrent()
        return true
    }

    func removeDomainRule(id: String) {
        domainRules.removeAll { $0.id == id }
        refreshCurrent()
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(appRules) { defaults.set(data, forKey: "appRules") }
    }
    private func saveDomainRules() {
        if let data = try? JSONEncoder().encode(domainRules) { defaults.set(data, forKey: "domainRules") }
    }

    private func matchingDomainRule(_ domain: String?) -> DomainRule? {
        guard let domain else { return nil }
        return domainRules.filter {
            SiteDomain.matches(host: domain, rule: $0.id)
        }.max { $0.id.count < $1.id.count }
    }

    private func sitePolicy(for snapshot: TextSnapshot) -> (suggest: Bool, record: Bool) {
        SitePolicy.evaluate(
            hosts: snapshot.siteDomains,
            unknownWeb: snapshot.isWebContent && snapshot.siteDomain == nil,
            rules: siteRules
        )
    }

    private func allows(_ snapshot: TextSnapshot) -> Bool {
        !IsSecureEventInputEnabled() && enabled
            && rule(for: snapshot.appID).enabled
            && sitePolicy(for: snapshot).suggest
    }

    private func permitsRecording(_ snapshot: TextSnapshot) -> Bool {
        allows(snapshot) && learningEnabled
            && rule(for: snapshot.appID).recordWriting
            && sitePolicy(for: snapshot).record
    }

    private func recordMonitored(_ snapshot: TextSnapshot) {
        guard recordAllWriting, permitsRecording(snapshot), snapshot.selected.isEmpty,
              snapshot.before.utf16.count >= 40 else { return }
        queueRecording(text: String(snapshot.before.suffix(200)), for: snapshot, monitored: true)
    }

    private func queueRecording(text: String, for snapshot: TextSnapshot, monitored: Bool) {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, (!monitored || self.recordAllWriting), self.permitsRecording(snapshot) else { return }
            self.history.recordWriting(text: text, appID: snapshot.appID, domain: snapshot.siteDomain)
            if let error = self.history.lastError { self.status = error }
            self.objectWillChange.send()
        }
    }

    private func options(for snapshot: TextSnapshot, maxWords: Int, vocabulary: Bool) -> PredictionOptions {
        PredictionOptions(globalInstructions: globalInstructions,
                          appInstructions: rule(for: snapshot.appID).instructions,
                          domainInstructions: matchingDomainRule(snapshot.siteDomain)?.instructions ?? "",
                          vocabularyStrength: vocabulary && learningEnabled ? vocabularyStrength : 0,
                          vocabulary: vocabulary && learningEnabled
                              ? history.vocabulary(appID: snapshot.appID, domain: snapshot.siteDomain) : "",
                          maxWords: maxWords)
    }

    private func context(for snapshot: TextSnapshot, before: String? = nil, visible: String? = nil,
                         clipboard: String? = nil) -> PredictionContext {
        PredictionContext(before: before ?? snapshot.before, after: snapshot.after,
                          appName: snapshot.appName, appID: snapshot.appID,
                          visibleText: visible, clipboard: clipboard, siteDomain: snapshot.siteDomain)
    }

    private func refreshCurrent() {
        invalidateSuggestion()
        monitor.scheduleRefresh(force: true)
    }

    private func beginGeneration() -> UInt64 {
        pending?.cancel()
        generationSerial &+= 1
        pendingGeneration = generationSerial
        return generationSerial
    }

    func invalidateSuggestion() {
        pending?.cancel()
        pendingGeneration = nil
        pendingRemainder = nil
        queuedAccepts.removeAll()
        cancelPrefetch()
        clearSuggestion()
    }

    func textDidChange(_ newSnapshot: TextSnapshot?) {
        // AX notifications and the forced post-insert refresh both report the same edit.
        // A repeat for unchanged text must not clear or restart the visible suggestion.
        if let newSnapshot, let previous = snapshot, previous.fingerprint == newSnapshot.fingerprint,
           !suggestion.isEmpty || pendingGeneration != nil || prefetch?.matches(newSnapshot) == true {
            snapshot = newSnapshot
            return
        }
        pending?.cancel()
        pendingGeneration = nil
        pendingRecording?.cancel()
        clearSuggestion()
        let previous = snapshot
        snapshot = newSnapshot
        guard let newSnapshot else {
            pendingRemainder = nil
            cancelPrefetch()
            if let previous { recordMonitored(previous) }
            lastApp = "No text field active"
            if IsSecureEventInputEnabled() { status = "Secure Input active; completions paused" }
            return
        }
        if let remainder = pendingRemainder {
            pendingRemainder = nil
            if remainder.matches(newSnapshot), allows(newSnapshot) {
                showContinuation(remainder.text, for: newSnapshot, prefetchNext: false, screen: remainder.screen)
                return
            }
        }
        if let previous, (previous.pid != newSnapshot.pid || !CFEqual(previous.element, newSnapshot.element)) {
            recordMonitored(previous)
        }
        lastApp = newSnapshot.appName
        observedAppIDs.insert(newSnapshot.appID)
        observedDomains.formUnion(newSnapshot.siteDomains)
        if recordAllWriting, permitsRecording(newSnapshot), newSnapshot.selected.isEmpty,
           newSnapshot.before.utf16.count >= 40 {
            let marker = newSnapshot.fingerprint
            pendingRecording = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1_200))
                guard let self, !Task.isCancelled, self.snapshot?.fingerprint == marker else { return }
                self.recordMonitored(newSnapshot)
            }
        }
        // The user accepted the whole suggestion: the next one was generated while they read it.
        if let prefetch, prefetch.matches(newSnapshot) {
            if let result = prefetch.result, eligible(newSnapshot) {
                self.prefetch = nil
                if !result.text.isEmpty {
                    showContinuation(result.text, for: newSnapshot, prefetchNext: true, screen: result.screen)
                }
            }
            return
        }
        cancelPrefetch()
        queuedAccepts.removeAll()
        guard eligible(newSnapshot) else { return }
        let marker = newSnapshot.fingerprint
        let generation = beginGeneration()
        pending = Task { @MainActor [weak self] in
            defer { if self?.pendingGeneration == generation { self?.pendingGeneration = nil } }
            // Short pause so fast typing does not queue a request per keystroke.
            try? await Task.sleep(for: .milliseconds(90))
            guard let self, !Task.isCancelled, self.allows(newSnapshot) else { return }
            do {
                let result = try await self.continuation(for: newSnapshot, before: newSnapshot.before)
                guard !Task.isCancelled, self.snapshot?.fingerprint == marker,
                      self.allows(newSnapshot), !result.text.isEmpty else { return }
                self.showContinuation(result.text, for: newSnapshot, prefetchNext: true, screen: result.screen)
                self.status = "Ready"
            } catch {
                if !Task.isCancelled, !(error is CancellationError) { self.status = "Local model: \(error.localizedDescription)" }
            }
        }
    }

    private func eligible(_ snapshot: TextSnapshot) -> Bool {
        allows(snapshot) && Date() >= pauseUntil && snapshot.selected.isEmpty
            && snapshot.before.utf16.count >= 8
            // Suggest only at the end of a line. Text later on the same line makes any
            // insertion a mid-sentence rewrite; Cotypist also shows nothing there.
            && snapshot.after.prefix(while: { !$0.isNewline }).allSatisfy(\.isWhitespace)
    }

    private func continuation(for snapshot: TextSnapshot, before: String) async throws -> Continuation {
        let excludedApps = Set((Set(appRules.map(\.id)).union(AppRule.sensitiveAppIDs))
            .filter { !rule(for: $0).enabled || !rule(for: $0).recordWriting })
        let captured = screenContextEnabled && !domainRules.contains(where: { !$0.enabled || !$0.recordWriting })
            ? screen.transcript(caret: snapshot.caret, field: monitor.inlineMetrics(for: snapshot).fieldFrame,
                                excluding: excludedApps) : nil
        let screenUse = captured.map { ScreenUse(app: snapshot.appName, capturedAt: $0.capturedAt, text: $0.text) }
        try Task.checkCancellation()
        var clipboardText: String?
        if clipboardContextEnabled {
            let clipboard = NSPasteboard.general
            let concealed = clipboard.types?.contains(where: {
                $0.rawValue == "org.nspasteboard.ConcealedType" || $0.rawValue == "org.nspasteboard.TransientType"
            }) == true
            clipboardText = concealed ? nil : clipboard.string(forType: .string).map { String($0.prefix(800)) }
        }
        let context = context(for: snapshot, before: before, visible: screenUse?.text, clipboard: clipboardText)
        let options = options(for: snapshot, maxWords: maxWords, vocabulary: true)
        let raw = try await inference.generate(
            prompt: PredictionPrompt.make(context: context, options: options, kind: .continuation),
            maxTokens: maxWords, maxWords: maxWords, kind: .continuation)
        return Continuation(text: PredictionPrompt.clean(raw, maxWords: maxWords), screen: screenUse)
    }

    /// Shows a continuation inline. Only the words that fit are offered, so Tab and
    /// grave accept exactly what is visible. Then, while the user reads it, generate
    /// what follows the whole suggestion so accepting it continues without a wait.
    private func showContinuation(_ text: String, for snapshot: TextSnapshot, prefetchNext: Bool, screen: ScreenUse?) {
        let shown = overlay.showInline(text, at: snapshot.caret, metrics: monitor.inlineMetrics(for: snapshot))
        guard !shown.isEmpty else { clearSuggestion(); return }
        suggestion = shown
        suggestionPreview = shown
        suggestionScreen = screen
        if let screen { lastScreenUse = screen }
        if prefetchNext { startPrefetch(after: shown, from: snapshot) }
        // Tabs pressed before this suggestion appeared are applied now, in order.
        if !queuedAccepts.isEmpty {
            let full = queuedAccepts.removeFirst()
            Task { @MainActor [weak self] in _ = self?.acceptSuggestion(full: full) }
        }
    }

    private func startPrefetch(after shown: String, from snapshot: TextSnapshot) {
        cancelPrefetch()
        let full = snapshot.before + shown
        let expected = String(decoding: full.utf16.suffix(1_200), as: UTF16.self)
        var next = Prefetch(source: snapshot, expectedBefore: expected)
        next.task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = (try? await self.continuation(for: snapshot, before: full)) ?? Continuation(text: "", screen: nil)
            guard !Task.isCancelled, self.prefetch?.expectedBefore == expected else { return }
            self.prefetch?.result = result
            self.prefetch?.task = nil
            if result.text.isEmpty { self.queuedAccepts.removeAll() }
            // Accepted before the prefetch finished: show it the moment it is ready.
            if let current = self.snapshot, self.prefetch?.matches(current) == true,
               self.suggestion.isEmpty, self.pendingRemainder == nil, self.eligible(current) {
                self.prefetch = nil
                if !result.text.isEmpty {
                    self.showContinuation(result.text, for: current, prefetchNext: true, screen: result.screen)
                }
            }
        }
        prefetch = next
    }

    private func cancelPrefetch() {
        prefetch?.task?.cancel()
        prefetch = nil
    }

    func acceptSuggestion(full: Bool) -> Bool {
        if !alternativeChoices.isEmpty { return selectAlternative(0) }
        // The next part is still on its way (the field has not reported the last insert,
        // or the continuation is still generating). Keep the key instead of letting it
        // type a literal tab; it is applied as soon as the text appears.
        if pendingRemainder != nil || awaitingPrefetch() {
            guard queuedAccepts.count < 8 else { return true }
            queuedAccepts.append(full)
            return true
        }
        guard let snapshot, !suggestion.isEmpty, allows(snapshot) else { return false }
        let accepted = snapshot.selected.isEmpty && !full
            ? PredictionPrompt.nextWord(suggestion, trailingSpace: trailingSpace, punctuation: true) : suggestion
        let remainder = !full && suggestion.hasPrefix(accepted)
            ? String(suggestion.dropFirst(accepted.count)) : ""
        guard !accepted.isEmpty, monitor.insert(accepted, matching: snapshot) else {
            clearSuggestion()
            return false
        }
        recordAcceptance(accepted)
        if permitsRecording(snapshot), snapshot.before.utf16.count >= 40 {
            queueRecording(text: String(snapshot.before.suffix(120)) + String(accepted.prefix(80)),
                           for: snapshot, monitored: false)
        }
        pending?.cancel()
        pendingGeneration = nil
        let usedScreen = suggestionScreen
        clearSuggestion()
        if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingRemainder = PendingRemainder(
                source: snapshot,
                expectedBefore: String(decoding: (snapshot.before + accepted).utf16.suffix(1_200), as: UTF16.self),
                expectedLocation: snapshot.range.location + accepted.utf16.count,
                text: remainder,
                expiresAt: Date().addingTimeInterval(2),
                screen: usedScreen
            )
        } else {
            prefetch?.armedUntil = Date().addingTimeInterval(1.5)
        }
        return true
    }

    func dismissSuggestion() -> Bool {
        guard !suggestion.isEmpty || !alternativeChoices.isEmpty || pendingRemainder != nil
                || pendingGeneration != nil else { return false }
        invalidateSuggestion()
        cancelPrefetch()
        pauseUntil = Date().addingTimeInterval(2.5)
        return true
    }

    /// Load the model before the first keystroke, so typing never waits ~20 s for it.
    private func preloadModel() {
        guard enabled, monitoring else { return }
        Task { @MainActor [weak self] in await self?.inference.prepare() }
    }

    func hasAcceptableSuggestion() -> Bool {
        if let remainder = pendingRemainder {
            return Date() < remainder.expiresAt && allows(remainder.source)
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == remainder.source.pid
        }
        if awaitingPrefetch() { return true }
        guard let snapshot, !suggestion.isEmpty || !alternativeChoices.isEmpty else { return false }
        return allows(snapshot) && NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid
    }

    /// True right after the whole suggestion was accepted while its continuation is
    /// still pending or not yet shown. An empty continuation releases Tab again.
    private func awaitingPrefetch() -> Bool {
        guard suggestion.isEmpty, let prefetch, let until = prefetch.armedUntil, Date() < until,
              allows(prefetch.source),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == prefetch.source.pid else { return false }
        return prefetch.result.map { !$0.text.isEmpty } ?? true
    }

    func requestAlternatives() -> Bool {
        guard let snapshot, allows(snapshot), snapshot.selected.isEmpty else { return false }
        pendingRemainder = nil
        let marker = snapshot.fingerprint
        let generation = beginGeneration()
        pending = Task { @MainActor [weak self] in
            defer { if self?.pendingGeneration == generation { self?.pendingGeneration = nil } }
            guard let self else { return }
            let context = self.context(for: snapshot)
            let options = self.options(for: snapshot, maxWords: 1, vocabulary: false)
            do {
                let raw = try await self.inference.generate(
                    prompt: PredictionPrompt.make(context: context, options: options, kind: .alternatives),
                    maxTokens: 44, maxWords: 1, kind: .alternatives)
                guard !Task.isCancelled, self.snapshot?.fingerprint == marker,
                      self.allows(snapshot) else { return }
                self.alternativeChoices = Array(raw.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                    guard let insertion = PredictionPrompt.alternative(String(line)) else {
                        return nil
                    }
                    return insertion
                }.prefix(3))
                if !self.alternativeChoices.isEmpty {
                    self.overlay.show(self.alternativeChoices.enumerated().map {
                        "\($0.offset + 1) \($0.element.trimmingCharacters(in: .whitespacesAndNewlines))"
                    }.joined(separator: "   "), at: snapshot.caret, hint: "1–3: choose")
                } else {
                    self.status = "No alternative words available"
                }
            } catch {
                if !Task.isCancelled, !(error is CancellationError) { self.status = "Alternatives unavailable: \(error.localizedDescription)" }
            }
        }
        return true
    }

    func hasSelectableAlternative(_ index: Int) -> Bool {
        alternativeChoices.indices.contains(index) && hasAcceptableSuggestion()
    }

    func selectAlternative(_ index: Int) -> Bool {
        guard alternativeChoices.indices.contains(index), let snapshot, allows(snapshot),
              monitor.insert(alternativeChoices[index], matching: snapshot) else { return false }
        recordAcceptance(alternativeChoices[index])
        pending?.cancel()
        pendingGeneration = nil
        clearSuggestion()
        return true
    }

    private func recordAcceptance(_ text: String) {
        acceptedCompletions += 1
        acceptedWords += text.split(whereSeparator: \.isWhitespace).count
        defaults.set(acceptedCompletions, forKey: "acceptedCompletions")
        defaults.set(acceptedWords, forKey: "acceptedWords")
    }

    func requestRewrite(correction: Bool) -> Bool {
        guard let snapshot, allows(snapshot), !snapshot.selected.isEmpty else { return false }
        guard correction || WritingWordBoundary.isSingleWord(snapshot.selected) else {
            status = "Select one word for a synonym"
            return false
        }
        clearSuggestion()
        let marker = snapshot.fingerprint
        let generation = beginGeneration()
        pending = Task { @MainActor [weak self] in
            defer { if self?.pendingGeneration == generation { self?.pendingGeneration = nil } }
            guard let self else { return }
            let context = self.context(for: snapshot)
            let options = self.options(for: snapshot, maxWords: 20, vocabulary: false)
            do {
                let raw = try await self.inference.generate(
                    prompt: PredictionPrompt.make(context: context, options: options,
                                                  kind: correction ? .correction(snapshot.selected) : .synonym(snapshot.selected)),
                    maxWords: 20,
                    kind: correction ? .correction(snapshot.selected) : .synonym(snapshot.selected))
                guard !Task.isCancelled, self.snapshot?.fingerprint == marker,
                      self.allows(snapshot) else { return }
                guard let replacement = PredictionPrompt.replacement(raw, selected: snapshot.selected) else {
                    self.status = "No replacement change available"
                    return
                }
                self.suggestion = replacement
                self.suggestionPreview = replacement
                self.overlay.show(replacement, at: snapshot.caret, hint: "Tab or `: replace selection")
            } catch {
                if !Task.isCancelled, !(error is CancellationError) { self.status = "Rewrite unavailable: \(error.localizedDescription)" }
            }
        }
        return true
    }


    private func clearSuggestion() {
        suggestion = ""
        suggestionPreview = ""
        suggestionScreen = nil
        alternativeChoices = []
        overlay.hide()
    }
}

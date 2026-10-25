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

/// A suggestion held across a keystroke, in case the key types its next characters.
private struct TypeThrough {
    let source: TextSnapshot
    let text: String
    let screen: ScreenUse?
    let prefetch: Prefetch?
}

/// The next continuation, either prefetched or requested after an accepted insertion.
private final class Prefetch {
    let source: TextSnapshot
    let expectedBefore: String
    var result: Continuation?
    var task: Task<Void, Never>?
    /// Set when the whole visible suggestion is accepted: until then a further Tab
    /// belongs to this result. Bounded so a result that never shows cannot hold Tab.
    var armedUntil: Date?

    init(source: TextSnapshot, expectedBefore: String) {
        self.source = source
        self.expectedBefore = expectedBefore
    }

    func matches(_ next: TextSnapshot) -> Bool {
        next.pid == source.pid && CFEqual(next.element, source.element)
            && next.siteDomains == source.siteDomains && next.siteDomain == source.siteDomain
            && next.isWebContent == source.isWebContent
            && next.before == expectedBefore && next.after == source.after && next.range.length == 0
    }
}

@MainActor
final class AppModel: ObservableObject, TextObserver {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "enabled"); reconcileMonitoring() }
    }
    @Published var powerMode: PowerMode {
        didSet {
            defaults.set(powerMode.rawValue, forKey: "powerMode")
            applyPowerPolicy(SystemPowerMonitor.current())
        }
    }
    @Published private(set) var effectivePowerDescription: String
    @Published var typingWordsPerMinute: Double {
        didSet {
            let normalized = typingWordsPerMinute.isFinite ? min(200, max(10, typingWordsPerMinute)) : 40
            if typingWordsPerMinute != normalized { typingWordsPerMinute = normalized }
            defaults.set(normalized, forKey: "typingWordsPerMinute")
        }
    }
    @Published private(set) var savings: SavingsStatistics
    @Published private(set) var savingsError: String?
    @Published var screenContextEnabled: Bool {
        didSet { defaults.set(screenContextEnabled, forKey: "screenContext"); refreshCurrent() }
    }
    @Published var clipboardContextEnabled: Bool {
        didSet { defaults.set(clipboardContextEnabled, forKey: "clipboardContext"); refreshCurrent() }
    }
    @Published var learningEnabled: Bool {
        didSet { defaults.set(learningEnabled, forKey: "learning"); refreshCurrent() }
    }
    @Published var recordAllWriting: Bool {
        didSet { defaults.set(recordAllWriting, forKey: "recordAllWriting"); refreshCurrent() }
    }
    @Published var globalInstructions: String {
        didSet { defaults.set(globalInstructions, forKey: "instructions"); refreshCurrent() }
    }
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
    @Published private(set) var lastApp = "No text field active"
    @Published private(set) var suggestionPreview = ""
    /// Screen text behind the suggestion currently on screen, if any.
    @Published private(set) var suggestionScreen: ScreenUse?
    /// Most recent screen text that reached the model.
    @Published private(set) var lastScreenUse: ScreenUse?
    @Published private(set) var demoOutput = ""
    @Published private(set) var demoBusy = false
    @Published private(set) var demoError: String?

    private let defaults = UserDefaults.standard
    private let monitor = AccessibilityMonitor()
    private let inference = LocalInference()
    private let overlay = SuggestionOverlay()
    private let screen = ScreenContext()
    private let powerMonitor = SystemPowerMonitor()
    private var powerPolicy: PowerPolicy
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var sleeping = false
    private var sessionActive = true
    private var terminated = false
    private var preloadTask: Task<Void, Never>?
    private var demoTask: Task<String, Error>?
    private var demoSerial: UInt64 = 0
    private var pendingAccept: Task<Void, Never>?
    private let acceptanceDeadline = AcceptanceDeadline()
    private var recordingSerial: UInt64 = 0
    private var recordingTasks: [UInt64: Task<Void, Never>] = [:]
    private let history = PersonalizationStore()
    private var pending: Task<Void, Never>?
    private var generationSerial: UInt64 = 0
    private var pendingGeneration: UInt64?
    private var pendingRecording: Task<Void, Never>?
    private var snapshot: TextSnapshot?
    private var suggestion = ""
    private var pendingRemainder: PendingRemainder?
    private var prefetch: Prefetch?
    private var typeThrough: TypeThrough?
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
        let initialMode = defaults.string(forKey: "powerMode").flatMap(PowerMode.init(rawValue:)) ?? .automatic
        let initialPolicy = PowerPolicy.resolve(mode: initialMode, environment: SystemPowerMonitor.current())
        powerMode = initialMode
        powerPolicy = initialPolicy
        effectivePowerDescription = initialPolicy.description
        let storedSpeed = defaults.object(forKey: "typingWordsPerMinute") as? Double ?? 40
        typingWordsPerMinute = storedSpeed.isFinite ? min(200, max(10, storedSpeed)) : 40
        if let stored = defaults.object(forKey: "savingsStatistics") {
            do {
                guard let data = stored as? Data else { throw CocoaError(.coderReadCorrupt) }
                savings = try JSONDecoder().decode(SavingsStatistics.self, from: data)
            } catch {
                savings = SavingsStatistics()
                savingsError = "Saved statistics could not be read. They have been preserved; reset statistics to start again."
            }
        } else {
            savings = SavingsStatistics()
        }
        screenContextEnabled = defaults.bool(forKey: "screenContext")
        clipboardContextEnabled = defaults.bool(forKey: "clipboardContext")
        learningEnabled = defaults.bool(forKey: "learning")
        recordAllWriting = defaults.bool(forKey: "recordAllWriting")
        globalInstructions = defaults.string(forKey: "instructions") ?? ""
        vocabularyStrength = max(0, min(3, defaults.object(forKey: "vocabularyStrength") as? Int ?? 2))
        maxWords = max(1, min(12, defaults.integer(forKey: "maxWords") == 0 ? 4 : defaults.integer(forKey: "maxWords")))
        trailingSpace = defaults.bool(forKey: "trailingSpace")
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
        inference.onStateWillChange = { [weak self] in self?.objectWillChange.send() }
        inference.configureIdleUnload(after: powerPolicy.idleUnloadDelay)
        powerMonitor.onChange = { [weak self] environment in self?.applyPowerPolicy(environment) }
        powerMonitor.start()
        observeLifecycle()
        reconcileMonitoring()
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
        clearDemo()
        guard !terminated, !sleeping, sessionActive,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let serial = demoSerial
        let wordLimit = maxWords
        demoBusy = true
        defer {
            if demoSerial == serial {
                demoBusy = false
                demoTask = nil
            }
        }
        let context = PredictionContext(before: text, after: "", appName: "FreeComplete demo",
                                        appID: "app.freecomplete.demo", visibleText: nil, clipboard: nil,
                                        siteDomain: nil)
        let options = PredictionOptions(globalInstructions: globalInstructions, appInstructions: "",
                                        domainInstructions: "", vocabularyStrength: 0,
                                        vocabulary: "", maxWords: wordLimit)
        let request = Task { @MainActor [inference] in
            try await inference.generate(
                prompt: PredictionPrompt.make(context: context, options: options, kind: .continuation),
                maxTokens: wordLimit, maxWords: wordLimit, kind: .continuation)
        }
        demoTask = request
        do {
            let raw = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: { request.cancel() }
            guard demoSerial == serial, !Task.isCancelled else { return }
            demoOutput = PredictionPrompt.clean(raw, maxWords: wordLimit)
            if demoOutput.isEmpty { demoError = "No continuation returned. Try a longer sentence." }
        } catch {
            guard demoSerial == serial, !Task.isCancelled, !(error is CancellationError) else { return }
            demoError = error.localizedDescription
        }
    }

    func clearDemo() {
        demoSerial &+= 1
        demoTask?.cancel()
        demoTask = nil
        demoBusy = false
        demoOutput = ""
        demoError = nil
    }

    func checkPermission() {
        let granted = monitor.isTrusted
        if accessibilityGranted != granted {
            accessibilityGranted = granted
            reconcileMonitoring()
        } else if granted, enabled, !monitoring, !sleeping, sessionActive, !terminated {
            reconcileMonitoring()
        }
    }

    private var operational: Bool {
        enabled && accessibilityGranted && monitoring && !sleeping && sessionActive && !terminated
    }

    private func reconcileMonitoring() {
        let wasMonitoring = monitoring
        monitoring = false
        resetTransientState()
        if wasMonitoring { monitor.stop() }
        guard !terminated, !sleeping, sessionActive, enabled, accessibilityGranted else {
            inference.unload()
            if !enabled { status = "Completions paused" }
            else if sleeping || !sessionActive { status = "Completions suspended" }
            else { status = "Allow Accessibility in System Settings to use autocomplete" }
            return
        }
        monitoring = monitor.start()
        status = monitoring ? "Ready" : "Keyboard interception unavailable"
        if monitoring { monitor.scheduleRefresh(force: true) }
        preloadModel()
    }

    private func observeLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, !self.terminated else { return }
                    switch note.name {
                    case NSWorkspace.willSleepNotification: self.sleeping = true
                    case NSWorkspace.didWakeNotification: self.sleeping = false
                    case NSWorkspace.sessionDidResignActiveNotification: self.sessionActive = false
                    case NSWorkspace.sessionDidBecomeActiveNotification: self.sessionActive = true
                    default: return
                    }
                    self.accessibilityGranted = self.monitor.isTrusted
                    self.applyPowerPolicy(SystemPowerMonitor.current())
                    self.reconcileMonitoring()
                }
            })
        }
    }

    private func applyPowerPolicy(_ environment: PowerEnvironment) {
        let next = PowerPolicy.resolve(mode: powerMode, environment: environment)
        guard next != powerPolicy else { return }
        powerPolicy = next
        effectivePowerDescription = next.description
        inference.configureIdleUnload(after: next.idleUnloadDelay)
        resetTransientState()
        if operational { monitor.scheduleRefresh(force: true) }
        preloadModel()
    }

    private func resetTransientState() {
        invalidateSuggestion()
        preloadTask?.cancel()
        preloadTask = nil
        clearDemo()
        screen.clearCache()
        lastScreenUse = nil
        snapshot = nil
        pauseUntil = .distantPast
        lastApp = "No text field active"
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestScreenAccess() {
        if screenContextEnabled && !screenGranted { _ = CGRequestScreenCaptureAccess() }
    }

    func clearLearning() {
        refreshCurrent()
        history.clear()
        objectWillChange.send()
    }

    func stop() {
        terminated = true
        monitoring = false
        resetTransientState()
        monitor.stop()
        powerMonitor.stop()
        for observer in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        lifecycleObservers.removeAll()
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
        !IsSecureEventInputEnabled() && operational
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
        recordingSerial &+= 1
        let serial = recordingSerial
        recordingTasks[serial] = Task { @MainActor [weak self] in
            defer { self?.recordingTasks[serial] = nil }
            await Task.yield()
            guard let self, !Task.isCancelled, (!monitored || self.recordAllWriting),
                  self.permitsRecording(snapshot) else { return }
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
        clearDemo()
        screen.clearCache()
        lastScreenUse = nil
        if operational { monitor.scheduleRefresh(force: true) }
    }

    private func beginGeneration() -> UInt64 {
        pending?.cancel()
        generationSerial &+= 1
        pendingGeneration = generationSerial
        return generationSerial
    }

    /// Focus, geometry, privacy and policy changes never retain a hidden suggestion.
    func invalidateSuggestion() {
        invalidateSuggestion(preservingTypedThrough: false)
    }

    /// Only an actual text-edit key may carry a visible continuation across its edit.
    func textWillChange() {
        invalidateSuggestion(preservingTypedThrough: true)
    }

    private func invalidateSuggestion(preservingTypedThrough: Bool) {
        pending?.cancel()
        pending = nil
        pendingGeneration = nil
        pendingRemainder = nil
        pendingAccept?.cancel()
        pendingAccept = nil
        acceptanceDeadline.cancel()
        queuedAccepts.removeAll()
        cancelRecording()
        if !preservingTypedThrough || !suggestion.isEmpty { dropTypeThrough() }
        if preservingTypedThrough, let snapshot, snapshot.selected.isEmpty, !suggestion.isEmpty {
            typeThrough = TypeThrough(source: snapshot, text: suggestion, screen: suggestionScreen, prefetch: prefetch)
            prefetch = nil
        } else {
            cancelPrefetch()
        }
        clearSuggestion()
    }

    private func cancelRecording() {
        pendingRecording?.cancel()
        pendingRecording = nil
        for task in recordingTasks.values { task.cancel() }
        recordingTasks.removeAll()
    }

    private func dropTypeThrough() {
        typeThrough?.prefetch?.task?.cancel()
        typeThrough = nil
    }

    /// When the user types exactly the next characters of the suggestion, the rest is still
    /// valid: show it at once instead of generating again.
    private func continueTypedThrough(_ next: TextSnapshot) -> Bool {
        guard let held = typeThrough else { return false }
        typeThrough = nil
        let source = held.source
        let delta = next.range.location - source.range.location
        guard next.pid == source.pid, CFEqual(next.element, source.element), delta > 0,
              next.after == source.after, next.siteDomain == source.siteDomain,
              next.siteDomains == source.siteDomains, next.isWebContent == source.isWebContent,
              next.range.length == 0, ineligibility(next) == nil else {
            held.prefetch?.task?.cancel()
            return false
        }
        let typed = String(decoding: next.before.utf16.suffix(delta), as: UTF16.self)
        guard held.text.hasPrefix(typed), (source.before + typed).hasSuffix(next.before) else {
            held.prefetch?.task?.cancel()
            return false
        }
        let rest = String(held.text.dropFirst(typed.count))
        guard rest.contains(where: { $0.isLetter || $0.isNumber }) else {
            held.prefetch?.task?.cancel()
            return false
        }
        prefetch = held.prefetch?.result?.text.isEmpty == true ? nil : held.prefetch
        Trace.log("typed through \(typed.debugDescription), still showing \(rest.debugDescription)")
        showContinuation(rest, for: next, prefetchNext: prefetch == nil, screen: held.screen)
        return true
    }

    func textDidChange(_ newSnapshot: TextSnapshot?) {
        guard operational else {
            invalidateSuggestion()
            snapshot = nil
            return
        }
        if let previous = snapshot, let newSnapshot,
           previous.pid != newSnapshot.pid || !CFEqual(previous.element, newSnapshot.element)
            || previous.siteDomains != newSnapshot.siteDomains || previous.siteDomain != newSnapshot.siteDomain
            || previous.isWebContent != newSnapshot.isWebContent
            || (previous.matchesContent(newSnapshot) && previous.caret != newSnapshot.caret) {
            invalidateSuggestion()
            screen.clearCache()
            lastScreenUse = nil
        }
        // Some apps publish the pre-insert value once before the real edit. Do not
        // abandon a confirmed key's bounded continuation ownership on that repeat.
        if let newSnapshot, let remainder = pendingRemainder,
           Date() < remainder.expiresAt, remainder.source.matchesContent(newSnapshot),
           remainder.source.caret == newSnapshot.caret { return }
        if let newSnapshot, let next = prefetch, let deadline = next.armedUntil,
           Date() < deadline, next.source.matchesContent(newSnapshot),
           next.source.caret == newSnapshot.caret { return }
        // AX notifications and the forced post-insert refresh both report the same edit.
        // A repeat for unchanged text must not clear or restart the visible suggestion.
        if let newSnapshot, let previous = snapshot, previous.matchesContent(newSnapshot),
           previous.caret == newSnapshot.caret,
           !suggestion.isEmpty || pendingGeneration != nil || prefetch?.matches(newSnapshot) == true {
            snapshot = newSnapshot
            return
        }
        pending?.cancel()
        pendingGeneration = nil
        pendingAccept?.cancel()
        pendingAccept = nil
        cancelRecording()
        clearSuggestion()
        let previous = snapshot
        snapshot = newSnapshot
        guard let newSnapshot else {
            invalidateSuggestion()
            screen.clearCache()
            lastScreenUse = nil
            lastApp = "No text field active"
            if IsSecureEventInputEnabled() { status = "Secure Input active; completions paused" }
            return
        }
        if let remainder = pendingRemainder {
            pendingRemainder = nil
            scheduleAcceptanceDeadline()
            if remainder.matches(newSnapshot), allows(newSnapshot) {
                showContinuation(remainder.text, for: newSnapshot, prefetchNext: false, screen: remainder.screen)
                return
            }
        }
        if continueTypedThrough(newSnapshot) { return }
        if let previous, (previous.pid != newSnapshot.pid || !CFEqual(previous.element, newSnapshot.element)) {
            recordMonitored(previous)
        }
        lastApp = newSnapshot.appName
        Trace.log("field \(newSnapshot.appID) before=\(Trace.tail(newSnapshot.before)) after-line-empty=\(newSnapshot.after.prefix(while: { !$0.isNewline }).allSatisfy(\.isWhitespace)) caret=\(Int(newSnapshot.caret.minX)),\(Int(newSnapshot.caret.minY)) h\(Int(newSnapshot.caret.height))")
        observedAppIDs.insert(newSnapshot.appID)
        observedDomains.formUnion(newSnapshot.siteDomains)
        if recordAllWriting, permitsRecording(newSnapshot), newSnapshot.selected.isEmpty,
           newSnapshot.before.utf16.count >= 40 {
            pendingRecording = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1_200))
                guard let self, !Task.isCancelled, self.snapshot?.matchesContent(newSnapshot) == true else { return }
                self.recordMonitored(newSnapshot)
            }
        }
        // Performance may already have this result. Saver starts it only after the
        // accepted insertion is observed, retaining bounded ownership of rapid Tabs.
        if let prefetch, prefetch.matches(newSnapshot), eligible(newSnapshot) {
            if let deadline = prefetch.armedUntil, Date() >= deadline { queuedAccepts.removeAll() }
            if let result = prefetch.result {
                self.prefetch = nil
                if !result.text.isEmpty {
                    showContinuation(result.text, for: newSnapshot, prefetchNext: true, screen: result.screen)
                    return
                }
            } else {
                if prefetch.task == nil {
                    generateNextContinuation(prefetch, for: newSnapshot, before: newSnapshot.before)
                }
                return
            }
        }
        cancelPrefetch()
        queuedAccepts.removeAll()
        if let reason = ineligibility(newSnapshot) {
            Trace.log("skip: \(reason)")
            return
        }
        let debounce = powerPolicy.debounce
        let generation = beginGeneration()
        pending = Task { @MainActor [weak self] in
            defer { if self?.pendingGeneration == generation { self?.pendingGeneration = nil } }
            // A brief pause so a burst of keys does not start a search per keystroke; a
            // newer key cancels this one between search rounds anyway.
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled, self.allows(newSnapshot) else { return }
            let started = Date()
            do {
                let result = try await self.continuation(for: newSnapshot, before: newSnapshot.before)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                guard !Task.isCancelled, self.snapshot?.matchesContent(newSnapshot) == true, self.allows(newSnapshot) else {
                    Trace.log("generated \(ms) ms but text changed meanwhile")
                    return
                }
                guard !result.text.isEmpty else {
                    Trace.log("generated \(ms) ms: empty")
                    return
                }
                Trace.log("generated \(ms) ms: \(result.text.debugDescription) screen=\(result.screen != nil)")
                self.showContinuation(result.text, for: newSnapshot, prefetchNext: true, screen: result.screen)
                self.status = "Ready"
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    Trace.log("generation failed: \(error.localizedDescription)")
                    self.status = "Local model: \(error.localizedDescription)"
                }
            }
        }
    }

    private func eligible(_ snapshot: TextSnapshot) -> Bool { ineligibility(snapshot) == nil }

    /// Why no suggestion is generated for this field state, or nil when one should be.
    private func ineligibility(_ snapshot: TextSnapshot) -> String? {
        if !enabled { return "completions paused" }
        if !operational { return "autocomplete unavailable" }
        if !rule(for: snapshot.appID).enabled { return "app \(snapshot.appID) is off" }
        if IsSecureEventInputEnabled() { return "secure input" }
        if !sitePolicy(for: snapshot).suggest { return "website excluded or unknown" }
        if Date() < pauseUntil { return "dismissed with Esc" }
        if !snapshot.selected.isEmpty { return "text selected" }
        if snapshot.before.utf16.count < 8 { return "fewer than 8 characters before caret" }
        // Suggest only at the end of a line. Text later on the same line makes any
        // insertion a mid-sentence rewrite; Cotypist also shows nothing there.
        if !snapshot.after.prefix(while: { !$0.isNewline }).allSatisfy(\.isWhitespace) {
            return "text after caret on this line: \(Trace.tail(String(snapshot.after.prefix(16))))"
        }
        return nil
    }



    private func continuation(for snapshot: TextSnapshot, before: String) async throws -> Continuation {
        // Only the focused window is captured, so other apps never appear. An app whose
        // recording is off is not captured at all.
        let captured = screenContextEnabled && rule(for: snapshot.appID).recordWriting
            && !domainRules.contains(where: { !$0.enabled || !$0.recordWriting })
            ? screen.transcript(pid: snapshot.pid, element: snapshot.element, caret: snapshot.caret,
                                field: monitor.inlineMetrics(for: snapshot).fieldFrame) : nil
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
        guard allows(snapshot), self.snapshot?.matchesContent(snapshot) == true else { return }
        let metrics = monitor.inlineMetrics(for: snapshot)
        let shown = overlay.showInline(text, at: snapshot.caret, metrics: metrics)
        guard !shown.isEmpty else {
            Trace.log("not shown: nothing fits (caret x \(Int(snapshot.caret.maxX)), h \(Int(snapshot.caret.height)), field \(metrics.fieldFrame.map { "\(Int($0.minX))…\(Int($0.maxX))" } ?? "unknown"))")
            clearSuggestion()
            return
        }
        Trace.log("shown \(shown.debugDescription) font=\(metrics.fontName ?? "?") \(metrics.fontSize.map { "\($0)" } ?? "?")")
        suggestion = shown
        suggestionPreview = shown
        suggestionScreen = screen
        if let screen { lastScreenUse = screen }
        if prefetchNext { startPrefetch(after: shown, from: snapshot) }
        scheduleAcceptanceDeadline()
        // Tabs pressed before this suggestion appeared are applied now, in order.
        if !queuedAccepts.isEmpty {
            let full = queuedAccepts.removeFirst()
            pendingAccept?.cancel()
            pendingAccept = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled, self.snapshot?.matchesContent(snapshot) == true,
                      self.suggestion == shown, self.allows(snapshot) else { return }
                self.pendingAccept = nil
                _ = self.acceptSuggestion(full: full)
            }
        }
    }

    private func startPrefetch(after shown: String, from snapshot: TextSnapshot) {
        cancelPrefetch()
        guard powerPolicy.prefetchesContinuation, allows(snapshot) else { return }
        let full = snapshot.before + shown
        let expected = String(decoding: full.utf16.suffix(1_200), as: UTF16.self)
        let next = Prefetch(source: snapshot, expectedBefore: expected)
        prefetch = next
        generateNextContinuation(next, for: snapshot, before: full)
    }

    private func generateNextContinuation(_ next: Prefetch, for snapshot: TextSnapshot, before: String) {
        next.task = Task { @MainActor [weak self, weak next] in
            guard let self, let next else { return }
            let result: Continuation
            var failure: Error?
            do {
                result = try await self.continuation(for: snapshot, before: before)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                failure = error
                result = Continuation(text: "", screen: nil)
            }
            guard !Task.isCancelled, self.allows(snapshot),
                  self.prefetch === next || self.typeThrough?.prefetch === next else { return }
            if let failure, next.armedUntil != nil || self.snapshot.map(next.matches) == true {
                self.status = "Local model: \(failure.localizedDescription)"
            }
            next.result = result
            next.task = nil
            if let deadline = next.armedUntil, Date() >= deadline { self.queuedAccepts.removeAll() }
            if result.text.isEmpty {
                if self.prefetch === next { self.prefetch = nil }
                self.queuedAccepts.removeAll()
                self.scheduleAcceptanceDeadline()
                return
            }
            // Keep the result on its identity even while a text-edit key holds it.
            if self.prefetch === next, let current = self.snapshot, next.matches(current),
               self.suggestion.isEmpty, self.pendingRemainder == nil, self.eligible(current) {
                self.prefetch = nil
                self.showContinuation(result.text, for: current, prefetchNext: true, screen: result.screen)
            }
        }
    }

    private func cancelPrefetch() {
        prefetch?.task?.cancel()
        prefetch = nil
    }

    func acceptSuggestion(full: Bool) -> Bool {
        guard operational else { return false }
        if !alternativeChoices.isEmpty { return selectAlternative(0) }
        // The next part is still on its way (the field has not reported the last insert,
        // or the continuation is still generating). Keep the key instead of letting it
        // type a literal tab; it is applied as soon as the text appears.
        if pendingRemainder != nil || awaitingPrefetch() {
            guard hasAcceptableSuggestion() else { invalidateSuggestion(); return false }
            guard queuedAccepts.count < 8 else { return true }
            queuedAccepts.append(full)
            scheduleAcceptanceDeadline()
            return true
        }
        guard let snapshot, !suggestion.isEmpty, allows(snapshot) else { return false }
        let accepted = snapshot.selected.isEmpty && !full
            ? PredictionPrompt.nextWord(suggestion, trailingSpace: trailingSpace, punctuation: true) : suggestion
        let remainder = !full && suggestion.hasPrefix(accepted)
            ? String(suggestion.dropFirst(accepted.count)) : ""
        guard !accepted.isEmpty, monitor.insert(accepted, matching: snapshot) else {
            invalidateSuggestion()
            return false
        }
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
        } else if snapshot.selected.isEmpty {
            let expected = String(decoding: (snapshot.before + accepted).utf16.suffix(1_200), as: UTF16.self)
            if prefetch?.expectedBefore != expected {
                cancelPrefetch()
                // No generation until textDidChange confirms the accepted insertion.
                prefetch = Prefetch(source: snapshot, expectedBefore: expected)
            }
            prefetch?.armedUntil = Date().addingTimeInterval(1.5)
        }
        scheduleAcceptanceDeadline()
        return true
    }

    func dismissSuggestion() -> Bool {
        guard !suggestion.isEmpty || !alternativeChoices.isEmpty || pendingRemainder != nil
                || pendingGeneration != nil || awaitingPrefetch() || !queuedAccepts.isEmpty else { return false }
        invalidateSuggestion()
        cancelPrefetch()
        pauseUntil = Date().addingTimeInterval(2.5)
        return true
    }

    private func scheduleAcceptanceDeadline() {
        acceptanceDeadline.cancel()
        guard let deadline = [pendingRemainder?.expiresAt, prefetch?.armedUntil].compactMap({ $0 }).min() else { return }
        acceptanceDeadline.schedule(at: deadline) { [weak self] in
            guard let self else { return }
            let now = Date()
            var expired = false
            if let remainder = self.pendingRemainder, now >= remainder.expiresAt {
                self.pendingRemainder = nil
                expired = true
            }
            if let next = self.prefetch, let until = next.armedUntil, now >= until {
                next.armedUntil = nil
                // A confirmed on-demand generation may still finish, but no longer
                // owns Tab. An unconfirmed insertion cannot start future work.
                if next.task == nil, next.result == nil { self.cancelPrefetch() }
                expired = true
            }
            if expired {
                self.pendingAccept?.cancel()
                self.pendingAccept = nil
                if !self.queuedAccepts.isEmpty {
                    self.status = "Continuation timed out; press Tab again when a suggestion appears"
                }
                self.queuedAccepts.removeAll()
            }
            self.scheduleAcceptanceDeadline()
        }
    }

    /// Performance can load ahead of typing; Battery Saver only loads on a request.
    private func preloadModel() {
        guard operational, powerPolicy.preloadsModel, preloadTask == nil else { return }
        preloadTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.inference.prepare()
            if !Task.isCancelled { self.preloadTask = nil }
        }
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
        invalidateSuggestion()
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
                guard !Task.isCancelled, self.snapshot?.matchesContent(snapshot) == true,
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
        pending?.cancel()
        pendingGeneration = nil
        clearSuggestion()
        return true
    }

    /// The monitor calls this only after the native field confirms the inserted text.
    func insertionConfirmed(text: String, replacingSelection: Bool) {
        guard savingsError == nil else { return }
        do {
            try savings.record(inserted: text, replacingSelection: replacingSelection, at: Date())
            persistSavings()
        } catch {
            savingsError = "Statistics could not be updated: \(error.localizedDescription) Existing totals have been preserved; reset statistics to start again."
        }
    }

    func resetSavings() {
        savings = SavingsStatistics(timeZone: .current)
        savingsError = nil
        persistSavings()
    }

    private func persistSavings() {
        do {
            let data = try JSONEncoder().encode(savings)
            defaults.set(data, forKey: "savingsStatistics")
        } catch {
            savingsError = "Statistics could not be saved: \(error.localizedDescription) Previously saved totals have been preserved; reset statistics to start again."
        }
    }

    func requestRewrite(correction: Bool) -> Bool {
        guard let snapshot, allows(snapshot), !snapshot.selected.isEmpty else { return false }
        guard correction || WritingWordBoundary.isSingleWord(snapshot.selected) else {
            status = "Select one word for a synonym"
            return false
        }
        invalidateSuggestion()
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
                guard !Task.isCancelled, self.snapshot?.matchesContent(snapshot) == true,
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

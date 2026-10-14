import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft = "The next step for this project is"
    @State private var selection = 0
    @State private var domainDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(.teal.gradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("FreeComplete").font(.title2.weight(.semibold))
                    Text("Private, on-device writing assistance").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Completions", isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .accessibilityLabel("Enable cross-app completions")
            }
            .padding(.horizontal, 24).padding(.vertical, 18)

            Divider()
            TabView(selection: $selection) {
                dashboard.tabItem { Label("Home", systemImage: "house") }.tag(0)
                writing.tabItem { Label("Writing", systemImage: "text.alignleft") }.tag(1)
                apps.tabItem { Label("Apps", systemImage: "square.grid.2x2") }.tag(2)
                privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }.tag(3)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .frame(minWidth: 680, minHeight: 540)
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Ready to write") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            statusSymbol(model.accessibilityGranted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.accessibilityGranted ? "Cross-app access enabled" : "Cross-app access needs Accessibility")
                                    .font(.headline)
                                Text(model.accessibilityGranted
                                     ? "Suggestions can appear beside supported text fields."
                                     : "The local test below works without this permission. Grant access only when you are ready.")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !model.accessibilityGranted {
                                Button("Open permission prompt") { model.requestAccessibility() }
                            }
                        }
                        Divider()
                        LabeledContent("Model", value: "Gemma 4 E2B base, Q4_K_M • fully local")
                        LabeledContent("Runtime", value: model.runtimeStatus)
                        LabeledContent("Last active app", value: model.lastApp)
                        LabeledContent("Menu bar", value: "FC • Open, Pause/Resume, Quit")
                        Text("If Ice hides the FC item, reopen this window from the Dock.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.status != "Ready" {
                            Text(model.status).font(.caption).foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }.padding(8)
                }

                if model.screenContextEnabled {
                    GroupBox("Screen context") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let use = model.lastScreenUse {
                                HStack {
                                    Image(systemName: model.suggestionScreen != nil ? "eye.fill" : "eye")
                                        .foregroundStyle(model.suggestionScreen != nil ? .teal : .secondary)
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Text("\(model.suggestionScreen != nil ? "Current suggestion uses" : "Last used") screen text from \(use.app), captured \(Self.age(use.capturedAt, now: context.date)) ago")
                                    }
                                }
                                Text("Exactly what the model saw:").font(.caption).foregroundStyle(.secondary)
                                ScrollView {
                                    Text(use.text)
                                        .font(.system(size: 12, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 160)
                                .padding(8)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            } else {
                                Text(model.screenGranted
                                     ? "No screen text used yet. Type in another app; the first capture is ready about a second after you start."
                                     : "Screen Recording permission is not granted, so no screen text is used.")
                                    .foregroundStyle(.secondary)
                            }
                            Text("The FC menu bar icon turns into an eye while the visible suggestion was built with screen text.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                }

                GroupBox("Try the real model") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Write the start of a sentence, then generate a continuation. This uses the same bundled model as cross-app suggestions.")
                            .foregroundStyle(.secondary)
                        TextEditor(text: $draft)
                            .font(.system(size: 15))
                            .frame(height: 96)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Local model test editor")
                        HStack {
                            Button(model.demoBusy ? "Generating…" : "Suggest continuation") {
                                Task { await model.demoComplete(draft) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.demoBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if !model.demoOutput.isEmpty {
                                Button("Insert suggestion") {
                                    draft += model.demoOutput
                                    model.clearDemo()
                                }
                            }
                            Spacer()
                            if model.demoBusy { ProgressView().controlSize(.small) }
                        }
                        if !model.demoOutput.isEmpty {
                            Text(model.demoOutput)
                                .font(.system(size: 15))
                                .foregroundStyle(.teal)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("Model suggestion")
                        }
                    }.padding(8)
                }
                Text(verbatim: "In other apps: Tab accepts one word, grave (`) accepts all, Esc dismisses, Control+Option+grave offers alternatives. Select text, then Control+Option+S for a synonym or Control+Option+C for correction.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 16)
        }
    }

    private static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
    }

    private var writing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Suggestion length") {
                    VStack(alignment: .leading, spacing: 10) {
                        Stepper("Up to \(model.maxWords) words", value: $model.maxWords, in: 1...12)
                        Toggle("Add a space after accepting one word", isOn: $model.trailingSpace)
                        Text(verbatim: "Tab accepts one word. Grave (`) accepts all. Control+Option+grave (`) offers three alternatives, then 1–3 or Tab selects one. Select text and use Control+Option+S or C for a synonym or correction.")
                            .foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Instructions for all apps") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Set language and tone for every suggestion. App instructions override these, and website instructions override both.")
                            .foregroundStyle(.secondary)
                        TextEditor(text: $model.globalInstructions)
                            .frame(height: 130)
                            .padding(8)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Global writing instructions")
                    }.padding(8)
                }
            }.padding(.vertical, 16)
        }
    }

    private var apps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("An app appears here after you focus one of its supported text fields. Disable suggestions or learning, and set its own writing instructions.")
                    .foregroundStyle(.secondary)
                if model.displayedAppRules.isEmpty {
                    ContentUnavailableView("No apps seen yet", systemImage: "square.grid.2x2",
                                           description: Text("Enable Accessibility, then focus a text field in another app."))
                }
                ForEach(model.displayedAppRules) { rule in
                    GroupBox(rule.id) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Suggest in this app", isOn: ruleBinding(rule, \.enabled))
                            Toggle("Learn from accepted writing in this app", isOn: ruleBinding(rule, \.recordWriting))
                                .disabled(!model.learningEnabled)
                            TextField("App-specific instructions", text: ruleBinding(rule, \.instructions), axis: .vertical)
                                .lineLimit(2...4)
                            if model.hasAppRule(rule.id) {
                                HStack {
                                    Spacer()
                                    Button("Remove settings") { model.removeRule(id: rule.id) }
                                }
                            }
                        }.padding(8)
                    }
                }
                Divider()
                Text("Websites")
                    .font(.headline)
                Text("Website settings use Accessibility URLs from the focused field and its ancestors. A disabled parent domain also disables its subdomains, including those with their own settings. If a web field's outer URL is unknown, configured exclusions still apply.")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("example.com", text: $domainDraft)
                        .textContentType(.URL)
                        .accessibilityLabel("Website domain")
                    Button("Add website") {
                        if model.addDomain(domainDraft) { domainDraft = "" }
                    }.disabled(domainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(model.displayedDomainRules) { rule in
                    GroupBox(rule.id) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Suggest on this website", isOn: domainEnabledBinding(rule))
                                .disabled(model.hasDisabledParentDomain(rule.id))
                            Toggle("Learn from accepted writing on this website", isOn: domainRecordingBinding(rule))
                                .disabled(!model.learningEnabled || !model.domainAllowsSuggestions(rule.id)
                                          || model.hasExcludedParentDomain(rule.id))
                            if model.hasDisabledParentDomain(rule.id) {
                                Text("Suggestions are disabled by a parent domain.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            TextField("Website-specific instructions", text: domainBinding(rule, \.instructions), axis: .vertical)
                                .lineLimit(2...4)
                            if model.hasDomainRule(rule.id) {
                                HStack {
                                    Spacer()
                                    Button("Remove settings") { model.removeDomainRule(id: rule.id) }
                                }
                            }
                        }.padding(8)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
        }
    }

    private var privacy: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Optional context") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Use visible screen text (OCR)", isOn: $model.screenContextEnabled)
                        Text("FreeComplete reads the screen column around the field you are typing in (for example, the conversation above a reply), processed locally on this Mac and not saved. Recognition runs in the background, so suggestions never wait for it. OCR is suspended while any website has an exclusion, because another visible browser window might show it. macOS Screen Recording permission is required.")
                            .foregroundStyle(.secondary)
                        if model.screenContextEnabled && !model.screenGranted {
                            Button("Open Screen Recording permission") { model.requestScreenAccess() }
                        }
                        Divider()
                        Toggle("Use clipboard text", isOn: $model.clipboardContextEnabled)
                        Text("Only the current clipboard text is passed to the local model when enabled; it is not stored.")
                            .foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Writing history") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Record writing for personalization", isOn: $model.learningEnabled)
                        Text("Off by default. When enabled, short samples from fields where you accept a completion are encrypted on this Mac with a Keychain key. Nothing is uploaded.")
                            .foregroundStyle(.secondary)
                        Toggle("Also record monitored writing without accepting a suggestion", isOn: $model.recordAllWriting)
                            .disabled(!model.learningEnabled)
                        Text("Optional, off by default. Saves short samples after you pause typing or leave a field. Text under 40 characters and fields excluded by app or website settings are skipped.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("Vocabulary influence: \(["Off", "Low", "Medium", "Strong"][model.vocabularyStrength])")
                            Slider(value: Binding(get: { Double(model.vocabularyStrength) },
                                                  set: { model.vocabularyStrength = Int($0.rounded()) }), in: 0...3, step: 1)
                                .accessibilityLabel("Learned vocabulary influence")
                        }
                        HStack {
                            Text("\(model.learnedCount) saved examples")
                            Spacer()
                            Button("Clear writing history") { model.clearLearning() }
                                .disabled(model.learnedCount == 0 && model.historyError == nil)
                        }
                        if let error = model.historyError {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }.padding(8)
                }
                Text("All inference runs in the bundled local server. The app does not require Ollama, an account, or a cloud API. Secure text fields and concealed clipboard items are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 16)
        }
    }

    private func ruleBinding<Value>(_ rule: AppRule, _ keyPath: WritableKeyPath<AppRule, Value>) -> Binding<Value> {
        Binding(get: {
            model.rule(for: rule.id)[keyPath: keyPath]
        }, set: { value in
            var changed = model.rule(for: rule.id)
            changed[keyPath: keyPath] = value
            model.setRule(changed)
        })
    }

    private func domainBinding<Value>(_ rule: DomainRule, _ keyPath: WritableKeyPath<DomainRule, Value>) -> Binding<Value> {
        Binding(get: {
            model.domainRules.first(where: { $0.id == rule.id })?[keyPath: keyPath] ?? rule[keyPath: keyPath]
        }, set: { value in
            var changed = model.domainRules.first(where: { $0.id == rule.id }) ?? rule
            changed[keyPath: keyPath] = value
            model.setDomainRule(changed)
        })
    }
    private func domainEnabledBinding(_ rule: DomainRule) -> Binding<Bool> {
        Binding(get: { model.domainAllowsSuggestions(rule.id) }, set: { value in
            var changed = model.domainRules.first(where: { $0.id == rule.id }) ?? rule
            changed.enabled = value
            model.setDomainRule(changed)
        })
    }

    private func domainRecordingBinding(_ rule: DomainRule) -> Binding<Bool> {
        Binding(get: { model.domainAllowsRecording(rule.id) }, set: { value in
            var changed = model.domainRules.first(where: { $0.id == rule.id }) ?? rule
            changed.recordWriting = value
            model.setDomainRule(changed)
        })
    }

    private func statusSymbol(_ granted: Bool) -> some View {
        Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield")
            .font(.title2)
            .foregroundStyle(granted ? .green : .orange)
            .frame(width: 34)
    }
}

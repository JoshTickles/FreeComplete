import AppKit
import Combine
import SwiftUI

@MainActor
final class FreeCompleteApp: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var permissionTimer: Timer?
    private var screenIndicator: AnyCancellable?
    private var acceptCounter: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "FreeComplete")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = "FC"
        statusItem.button?.toolTip = "FreeComplete: local writing assistance"
        let menu = NSMenu()
        let tally = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        tally.isEnabled = false
        menu.addItem(tally)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Open FreeComplete", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let toggle = NSMenuItem(title: "Pause or resume completions", action: #selector(toggleCompletions), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FreeComplete", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        // Show at a glance when the visible suggestion was built with screen text.
        screenIndicator = model.$suggestionScreen.map { $0 != nil }.removeDuplicates().sink { [weak self] usesScreen in
            guard let button = self?.statusItem.button else { return }
            button.image = NSImage(systemSymbolName: usesScreen ? "eye" : "text.cursor",
                                   accessibilityDescription: usesScreen ? "FreeComplete: using screen text" : "FreeComplete")
            button.toolTip = usesScreen ? "FreeComplete: this suggestion uses screen text"
                : "FreeComplete: local writing assistance"
        }
        // "FC 42": accepted completions so far; the menu also shows the word total.
        acceptCounter = model.$acceptedCompletions.combineLatest(model.$acceptedWords)
            .sink { [weak self] completions, words in
                self?.statusItem.button?.title = "FC \(completions.formatted())"
                tally.title = "\(completions.formatted()) completions accepted · \(words.formatted()) words"
            }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "FreeComplete"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.minSize = NSSize(width: 680, height: 540)
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        openSettings()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.checkPermission()
            }
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "FreeComplete")
        let open = NSMenuItem(title: "Open FreeComplete", action: #selector(openSettings), keyEquivalent: ",")
        open.target = self
        appMenu.addItem(open)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FreeComplete", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        mainMenu.addItem(appItem)
        mainMenu.setSubmenu(appMenu, for: appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(undo)
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        mainMenu.addItem(editItem)
        mainMenu.setSubmenu(editMenu, for: editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    @objc private func toggleCompletions() { model.enabled.toggle() }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        model.stop()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = FreeCompleteApp()
    app.delegate = delegate
    app.run()
}

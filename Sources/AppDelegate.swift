import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windows: [WallpaperWindow] = []
    private var statusItem: NSStatusItem!
    private let settings = Settings.shared
    private let engine = Engine.shared
    private var screensAsleep = false
    private var screenLocked = false
    private var housekeeping: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try Renderer.setUp()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Afterglow couldn't start the renderer"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        setUpStatusItem()
        rebuildWindows()
        engine.tap.start()
        observeSystem()

        // Drop the frame rate in ambient mode and keep the pause states fresh.
        housekeeping = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateRendering()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.tap.stop()
    }

    // MARK: Windows

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let w = WallpaperWindow(screen: screen)
            w.orderBack(nil)
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: w)
            return w
        }
        updateRendering()
    }

    @objc private func occlusionChanged() { updateRendering() }

    /// Stop drawing entirely when no one can see it: covered by full-screen apps, display asleep, or locked.
    private func updateRendering() {
        let suspended = screensAsleep || screenLocked
        let fps: Int
        if settings.paused {
            fps = 2
        } else if engine.isIdle {
            fps = min(settings.fps, 30)
        } else {
            fps = settings.fps
        }
        for w in windows {
            let visible = w.occlusionState.contains(.visible)
            w.metalView.isPaused = suspended || !visible
            if w.metalView.preferredFramesPerSecond != fps { w.metalView.preferredFramesPerSecond = fps }
        }
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildWindows()
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true
            self?.engine.tap.stop()
            self?.updateRendering()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = false
            self?.engine.tap.start()
            self?.updateRendering()
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
            self?.updateRendering()
        }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
            self?.updateRendering()
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Afterglow")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if let error = engine.tap.lastError {
            status = "Audio unavailable: \(error)"
        } else if engine.isIdle {
            status = "No sound · ambient mode"
        } else {
            status = "Reacting to system audio"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        menu.addItem(submenu("Style", Style.allCases.map { ($0.title, $0 == settings.style, $0.rawValue) }, #selector(pickStyle)))
        menu.addItem(submenu("Colors", Theme.allCases.map { ($0.title, $0 == settings.theme, $0.rawValue) }, #selector(pickTheme)))
        menu.addItem(submenu("Brightness", [40, 60, 80, 100].map { ("\($0)%", abs(settings.brightness * 100 - Float($0)) < 1, $0) }, #selector(pickBrightness)))
        menu.addItem(submenu("Sensitivity", [("Low", 70), ("Normal", 100), ("High", 140)].map { ($0.0, abs(settings.sensitivity * 100 - Float($0.1)) < 1, $0.1) }, #selector(pickSensitivity)))
        menu.addItem(submenu("Frame Rate", [30, 60, 120, 144].map { ("\($0) fps", settings.fps == $0, $0) }, #selector(pickFPS)))

        let cycle = NSMenuItem(title: "Rotate Styles Every 8 Min (OLED care)", action: #selector(toggleCycle), keyEquivalent: "")
        cycle.target = self
        cycle.state = settings.autoCycle ? .on : .off
        menu.addItem(cycle)

        menu.addItem(.separator())
        let pause = NSMenuItem(title: settings.paused ? "Resume" : "Pause (black screen)", action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        menu.addItem(pause)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Afterglow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func submenu(_ title: String, _ options: [(String, Bool, Int)], _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (name, selected, tag) in options {
            let option = NSMenuItem(title: name, action: action, keyEquivalent: "")
            option.target = self
            option.tag = tag
            option.state = selected ? .on : .off
            sub.addItem(option)
        }
        item.submenu = sub
        return item
    }

    @objc private func pickStyle(_ sender: NSMenuItem) { settings.style = Style(rawValue: sender.tag) ?? .halo }
    @objc private func pickTheme(_ sender: NSMenuItem) { settings.theme = Theme(rawValue: sender.tag) ?? .spectrum }
    @objc private func pickBrightness(_ sender: NSMenuItem) { settings.brightness = Float(sender.tag) / 100 }
    @objc private func pickSensitivity(_ sender: NSMenuItem) { settings.sensitivity = Float(sender.tag) / 100 }
    @objc private func pickFPS(_ sender: NSMenuItem) { settings.fps = sender.tag; updateRendering() }
    @objc private func toggleCycle() { settings.autoCycle.toggle() }
    @objc private func togglePause() { settings.paused.toggle(); updateRendering() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nTip: move Afterglow.app to /Applications first."
            alert.runModal()
        }
    }
}

import AppKit
import SwiftUI
import Carbon
import Combine

@main
enum RefoldTrackerApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: TrackerModel?
    private var item: NSStatusItem?
    private var panel: MenuBarPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var sizeObservation: NSKeyValueObservation?
    private var outsideMonitor: Any?
    private var localMouseMonitor: Any?
    private var escapeMonitor: Any?
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var pendingControlURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let database = try Database()
            let adapter = try RefoldAdapter()
            let model = try TrackerModel(database: database, initial: database.load(), adapter: adapter)
            self.model = model
            adapter.onOpenBrowser = { [weak self] in self?.closePanel() }
            // Keep the status item anchor stable when the title or tracking state changes.
            item = NSStatusBar.system.statusItem(withLength: 112)
            item?.button?.image = NSImage(systemSymbolName: "stopwatch", accessibilityDescription: "Refold Tracker")
            item?.button?.target = self
            item?.button?.action = #selector(togglePanel)
            setupPanel(model: model)
            pendingControlURLs.forEach(handleControlURL)
            pendingControlURLs.removeAll()
            subscription = model.$elapsedMs.combineLatest(model.$state).sink { [weak self] elapsed, state in
                self?.item?.button?.title = state.active == nil ? " Refold" : " " + durationText(elapsed)
                self?.item?.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                let paused = state.active?.pausedAt != nil
                self?.item?.button?.image = NSImage(systemSymbolName: paused ? "pause.circle" : "stopwatch",
                                                   accessibilityDescription: paused ? "Tracking paused" : "Refold Tracker")
                self?.item?.button?.image?.size = NSSize(width: 16, height: 16)
                self?.setTimerActive(state.active != nil && !paused)
            }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
                                                               name: NSWorkspace.willSleepNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                               name: NSWorkspace.didWakeNotification, object: nil)
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePanel() }
            }
            registerShortcut()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Refold Tracker could not start"
            alert.informativeText = error.localizedDescription + "\nYour data has not been reset."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func setTimerActive(_ active: Bool) {
        if !active {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak model] _ in
            MainActor.assumeIsolated { model?.tick() }
        }
        timer.tolerance = 0.2
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func setupPanel(model: TrackerModel) {
        let content = TrackerView(model: model)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        let host = NSHostingController(rootView: AnyView(content))
        host.sizingOptions = .preferredContentSize
        let panel = MenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 560),
                                 styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.contentViewController = host
        self.panel = panel
        self.hostingController = host
        sizeObservation = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updatePanelFrame() }
            }
        }
    }

    private func updatePanelFrame(under button: NSStatusBarButton? = nil) {
        guard let panel, let host = hostingController,
              let button = button ?? item?.button, let window = button.window,
              let screen = window.screen else { return }
        var size = host.preferredContentSize
        if size.width < 100 || size.height < 100 {
            size = NSSize(width: 390, height: 560)
        }
        let visible = screen.visibleFrame
        let width = size.width
        let height = min(size.height, visible.height - 40)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = anchor.midX - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        let y = max(anchor.minY - height - 6, visible.minY + 8)
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height), display: true)
        panel.invalidateShadow()
    }

    @objc private func togglePanel() {
        guard let button = item?.button else { return }
        if panel?.isVisible == true { closePanel() }
        else { showPanel(using: button) }
    }

    private func showPanel(using button: NSStatusBarButton? = nil) {
        guard let panel, let button = button ?? item?.button, !panel.isVisible else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        updatePanelFrame(under: button)
        // Activating while the Refold web window is open makes macOS switch to the
        // Space containing that window. Present the panel without key/app activation
        // in that case; the click inside it activates the app on the current Space.
        let browserOpen = model?.adapter.hasVisibleBrowserWindow == true
        if browserOpen {
            panel.orderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        installDismissMonitors()
    }

    private func closePanel() {
        guard let panel else { return }
        removeDismissMonitors()
        panel.orderOut(nil)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.closeIfClickOutside() }
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return event }
                if event.window === panel {
                    if !NSApp.isActive {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    if !panel.isKeyWindow {
                        panel.makeKey()
                    }
                    return event
                }
                if self.isPanelWindow(event.window, panel: panel) {
                    if !NSApp.isActive {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    return event
                }
                if let button = self.item?.button, event.window === button.window {
                    return event
                }
                self.closePanel()
                return event
            }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible,
                      event.window === panel, event.keyCode == 53 else { return event }
                self.closePanel()
                return nil
            }
        }
    }

    private func isPanelWindow(_ window: NSWindow?, panel: MenuBarPanel) -> Bool {
        guard let window else { return false }
        return window === panel || window.sheetParent === panel || window.parent === panel
    }

    private func removeDismissMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor); self.localMouseMonitor = nil }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
    }

    private func closeIfClickOutside() {
        guard let panel, panel.isVisible else { return }
        let location = NSEvent.mouseLocation
        if panel.frame.contains(location) { return }
        if let button = item?.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if rect.contains(location) { return }
        }
        closePanel()
    }
    @objc private func willSleep() { model?.willSleep() }
    @objc private func didWake() { model?.didWake() }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handleControlURL)
    }

    private func handleControlURL(_ url: URL) {
        guard url.scheme?.lowercased() == "refoldtracker",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty || url.path == "/",
              url.query == nil, url.fragment == nil,
              let command = url.host?.lowercased(), ["pause", "resume", "toggle"].contains(command) else { return }
        guard let model else {
            pendingControlURLs.append(url)
            return
        }
        if command == "pause" {
            model.pause()
        } else if command == "resume" {
            model.resume()
        } else if let active = model.state.active {
            if active.pausedAt == nil { model.pause() } else { model.resume() }
        } else {
            model.message = "No active session to pause or resume."
            showPanel()
        }
        NSLog("Handled Tinycast Refold command: %@", command)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.stop(shouldSync: false) != false else { return .terminateCancel }
        return .terminateNow
    }

    private func registerShortcut() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.togglePanel() }
            return noErr
        }, 1, &event, pointer, &eventHandler)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey),
                                            EventHotKeyID(signature: 0x52464C44, id: 1),
                                            GetApplicationEventTarget(), 0, &hotKey)
        if installed != noErr || registered != noErr {
            model?.message = "Shortcut ⌃⌥R is unavailable. Use the menu bar icon."
        }
    }
}

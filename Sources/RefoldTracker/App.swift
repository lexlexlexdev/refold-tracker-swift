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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: TrackerModel?
    private var item: NSStatusItem?
    private let popover = NSPopover()
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
            pendingControlURLs.forEach(handleControlURL)
            pendingControlURLs.removeAll()
            // Keep the popover anchor stable when the title or tracking state changes.
            item = NSStatusBar.system.statusItem(withLength: 112)
            item?.button?.image = NSImage(systemSymbolName: "stopwatch", accessibilityDescription: "Refold Tracker")
            item?.button?.target = self
            item?.button?.action = #selector(togglePopover)
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: TrackerView(model: model))
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

    @objc private func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { showPopover(using: button) }
    }

    private func showPopover(using button: NSStatusBarButton? = nil) {
        guard !popover.isShown, let button = button ?? item?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
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
            showPopover()
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
            MainActor.assumeIsolated { delegate.togglePopover() }
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

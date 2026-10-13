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

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let database = try Database()
            let adapter = try RefoldAdapter()
            let model = try TrackerModel(database: database, initial: database.load(), adapter: adapter)
            self.model = model
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.image = NSImage(systemSymbolName: "stopwatch", accessibilityDescription: "Refold Tracker")
            item?.button?.target = self
            item?.button?.action = #selector(togglePopover)
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: TrackerView(model: model))
            subscription = model.$elapsedMs.combineLatest(model.$state).sink { [weak self] elapsed, state in
                self?.item?.button?.title = state.active == nil ? "" : " " + durationText(elapsed)
                self?.item?.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                if state.active == nil {
                    self?.timer?.fireDate = .distantFuture
                } else if self?.timer?.fireDate == .distantFuture {
                    self?.timer?.fireDate = Date().addingTimeInterval(1)
                }
            }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak model] _ in
                MainActor.assumeIsolated { model?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            timer.tolerance = 0.2
            if model.state.active == nil { timer.fireDate = .distantFuture }
            self.timer = timer
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

    @objc private func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    @objc private func willSleep() { model?.willSleep() }
    @objc private func didWake() { model?.didWake() }

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

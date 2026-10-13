import AppKit
import Combine

@MainActor
final class TrackerModel: ObservableObject {
    @Published private(set) var state: Snapshot
    @Published private(set) var elapsedMs: Int64 = 0
    @Published private(set) var syncing = false
    @Published private(set) var connected = false
    @Published private(set) var canWrite = false
    @Published var message: String?
    @Published private(set) var storageHealthy = true
    let adapter: RefoldAdapter
    private let database: Database
    private var monotonicStart: TimeInterval?
    private var lastCheckpoint: TimeInterval = 0

    init(database: Database, initial: Snapshot, adapter: RefoldAdapter) throws {
        self.database = database
        self.adapter = adapter
        var recovered = initial
        // Never count the time between the last durable checkpoint and an unknown restart.
        if var active = recovered.active {
            active.delivery = .review
            active.error = "Recovered the last checkpoint. Review the duration before saving."
            recovered.entries.insert(active, at: 0)
            recovered.active = nil
        }
        for i in recovered.entries.indices where recovered.entries[i].delivery == .sending {
            recovered.entries[i].delivery = .uncertain
        }
        try database.save(recovered)
        state = recovered
        adapter.onNavigation = { [weak self] in
            Task { await self?.sync() }
        }
    }

    var menuTitle: String { state.active == nil ? "" : durationText(elapsedMs) }

    func start(_ action: TrackingAction) {
        guard state.active == nil, storageHealthy else { return }
        var next = state
        next.active = LocalEntry(action: action)
        guard commit(next) else { return }
        monotonicStart = ProcessInfo.processInfo.systemUptime
        lastCheckpoint = monotonicStart!
        elapsedMs = 0
    }

    func tick() {
        guard let start = monotonicStart, state.active != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        elapsedMs = max(0, Int64((now - start) * 1_000))
        if now - lastCheckpoint >= 5 {
            var next = state
            next.active?.durationMs = elapsedMs
            if commit(next) { lastCheckpoint = now }
        }
    }

    @discardableResult
    func stop(shouldSync: Bool = true) -> Bool {
        guard var entry = state.active else { return true }
        if let start = monotonicStart {
            entry.durationMs = max(1, Int64((ProcessInfo.processInfo.systemUptime - start) * 1_000))
        }
        entry.delivery = .pending
        var next = state
        next.active = nil
        next.entries.insert(entry, at: 0)
        guard commit(next) else { return false }
        monotonicStart = nil
        elapsedMs = 0
        if shouldSync { Task { await sync() } }
        return true
    }

    func willSleep() { _ = stop(shouldSync: false) }

    func didWake() {
        // Fallback when willSleep was not delivered. Do not include unobserved sleep time.
        if var active = state.active {
            active.delivery = .review
            active.error = "Sleep was not captured in advance. Review the duration."
            var next = state
            next.active = nil
            next.entries.insert(active, at: 0)
            if commit(next) { monotonicStart = nil; elapsedMs = 0 }
        }
        Task { await sync() }
    }

    func editLocal(id: UUID, durationMs: Int64) {
        guard durationMs > 0, let index = state.entries.firstIndex(where: { $0.id == id }),
              [.pending, .review].contains(state.entries[index].delivery) else { return }
        var next = state
        next.entries[index].durationMs = durationMs
        next.entries[index].delivery = .pending
        next.entries[index].error = nil
        if commit(next) { Task { await sync() } }
    }

    func editRemote(_ entry: RemoteEntry, durationMs: Int64) {
        guard durationMs > 0, entry.isInScope, !state.remoteEdits.contains(where: { $0.id == entry.id }) else { return }
        var next = state
        next.remoteEdits.append(RemoteEdit(original: entry, desiredDurationMs: durationMs))
        if commit(next) { Task { await sync() } }
    }

    func retryEdit(_ id: String) {
        guard !syncing else { return }
        var next = state
        guard let index = next.remoteEdits.firstIndex(where: { $0.id == id }) else { return }
        next.remoteEdits[index].error = nil
        if commit(next) { Task { await sync() } }
    }

    func deleteLocal(_ id: UUID) {
        guard !syncing, let entry = state.entries.first(where: { $0.id == id }),
              [.pending, .review].contains(entry.delivery) else { return }
        var next = state
        next.entries.removeAll { $0.id == id }
        _ = commit(next)
    }

    func deleteRemote(_ entry: RemoteEntry) {
        guard !syncing, entry.isInScope,
              !state.remoteEdits.contains(where: { $0.id == entry.id }),
              !(state.remoteDeletes ?? []).contains(where: { $0.id == entry.id }) else { return }
        var next = state
        next.remoteDeletes = (next.remoteDeletes ?? []) + [RemoteDelete(original: entry)]
        if commit(next) { Task { await sync() } }
    }

    func sync() async {
        guard !syncing, storageHealthy else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await refresh()
            let ids = state.entries.filter { $0.delivery == .pending || $0.delivery == .uncertain }.map(\.id)
            for id in ids {
                guard storageHealthy, let index = state.entries.firstIndex(where: { $0.id == id }) else { return }
                let entry = state.entries[index]
                if entry.delivery == .uncertain {
                    reconcile(id: id)
                    continue
                }
                guard canWrite else { message = "Refold changed: write operations not found."; return }
                // Persist the pre-request history and sending state before the POST.
                var next = state
                next.entries[index].knownRemoteIDs = state.remoteEntries.map(\.id)
                next.entries[index].delivery = .sending
                guard commit(next) else { return }
                do {
                    try await adapter.save(entry)
                    updateEntry(id) { $0.delivery = .synced; $0.error = nil }
                    try await refresh()
                    reconcile(id: id)
                } catch {
                    updateEntry(id) { $0.delivery = .uncertain; $0.error = error.localizedDescription }
                    // A timeout is not evidence that the server did not save the entry.
                    if (try? await refresh()) != nil { reconcile(id: id) }
                }
            }
            for edit in state.remoteEdits {
                guard storageHealthy, canWrite else { return }
                try await refresh()
                guard let current = state.remoteEntries.first(where: { $0.id == edit.id }) else {
                    setEditError(edit.id, "Entry not found in recent history. Check it on the website.")
                    continue
                }
                if current.durationMs == edit.desiredDurationMs {
                    completeEdit(edit.id)
                    continue
                }
                guard current.durationMs == edit.original.durationMs,
                      current.name == edit.original.name, current.activityId == edit.original.activityId,
                      current.languageCode == edit.original.languageCode,
                      current.attributedDate == edit.original.attributedDate,
                      current.startTime == edit.original.startTime, current.note == edit.original.note else {
                    setEditError(edit.id, "Entry changed on the website. Changes were not overwritten; check it there.")
                    continue
                }
                // Uncertain edits are checked but not repeated automatically.
                if edit.error != nil { continue }
                // Journal uncertainty before sending so a crash cannot trigger a blind retry.
                setEditError(edit.id, "Edit interrupted or awaiting confirmation. Check history before retrying.")
                guard storageHealthy else { return }
                do {
                    try await adapter.edit(current, durationMs: edit.desiredDurationMs)
                    try await refresh()
                    if state.remoteEntries.first(where: { $0.id == edit.id })?.durationMs == edit.desiredDurationMs {
                        completeEdit(edit.id)
                    } else { setEditError(edit.id, "Could not confirm the edit. Check the entry on the website.") }
                } catch { setEditError(edit.id, error.localizedDescription) }
            }
            for deletion in state.remoteDeletes ?? [] {
                guard storageHealthy, canWrite else { return }
                try await refresh()
                guard let current = state.remoteEntries.first(where: { $0.id == deletion.id }) else {
                    // Recent-history absence alone is not proof of deletion (pagination).
                    setDeleteError(deletion.id, "Entry is absent from recent history. Verify deletion on the website.")
                    continue
                }
                guard current == deletion.original else {
                    setDeleteError(deletion.id, "Entry changed on the website. Deletion blocked.")
                    continue
                }
                guard deletion.error == nil else { continue }
                setDeleteError(deletion.id, "Deletion result is unknown. Check the website; it will not be repeated automatically.")
                guard storageHealthy else { return }
                do {
                    try await adapter.delete(current)
                    try await refresh()
                    if !state.remoteEntries.contains(where: { $0.id == deletion.id }) {
                        var next = state
                        next.remoteDeletes?.removeAll { $0.id == deletion.id }
                        next.entries.removeAll { $0.remoteID == deletion.id }
                        _ = commit(next)
                    } else { setDeleteError(deletion.id, "Refold still shows this entry. Verify deletion on the website.") }
                } catch { setDeleteError(deletion.id, error.localizedDescription) }
            }
        } catch {
            connected = false
            message = error.localizedDescription
        }
    }

    private func refresh() async throws {
        let history = try await adapter.history()
        var next = state
        next.remoteEntries = history.entries
        guard commit(next) else { throw NSError(domain: "RefoldTracker.Storage", code: 1) }
        connected = true
        canWrite = history.canWrite
        message = nil
    }

    private func reconcile(id: UUID) {
        guard let entry = state.entries.first(where: { $0.id == id }) else { return }
        let candidates = state.remoteEntries.filter {
            !entry.knownRemoteIDs.contains($0.id) && $0.matches(entry)
        }
        guard candidates.count == 1 else { return }
        updateEntry(id) { $0.delivery = .synced; $0.remoteID = candidates[0].id; $0.error = nil }
    }

    private func updateEntry(_ id: UUID, change: (inout LocalEntry) -> Void) {
        var next = state
        guard let index = next.entries.firstIndex(where: { $0.id == id }) else { return }
        change(&next.entries[index])
        _ = commit(next)
    }
    private func setEditError(_ id: String, _ error: String) {
        var next = state
        guard let i = next.remoteEdits.firstIndex(where: { $0.id == id }) else { return }
        next.remoteEdits[i].error = error
        _ = commit(next)
    }
    private func completeEdit(_ id: String) {
        var next = state
        next.remoteEdits.removeAll { $0.id == id }
        _ = commit(next)
    }
    private func setDeleteError(_ id: String, _ error: String) {
        var next = state
        guard let index = next.remoteDeletes?.firstIndex(where: { $0.id == id }) else { return }
        next.remoteDeletes?[index].error = error
        _ = commit(next)
    }
    private func commit(_ next: Snapshot) -> Bool {
        do {
            try database.save(next)
            state = next
            storageHealthy = true
            return true
        } catch {
            storageHealthy = false
            message = "Could not save to disk: \(error.localizedDescription). Tracking is blocked."
            return false
        }
    }
}

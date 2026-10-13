import SwiftUI

struct EditTarget: Identifiable {
    var id: String
    var local: LocalEntry?
    var remote: RemoteEntry?
    var durationMs: Int64 { local?.durationMs ?? remote!.durationMs }
    var name: String { local?.action.name ?? remote!.name }
}

struct TrackerView: View {
    @ObservedObject var model: TrackerModel
    @State private var editTarget: EditTarget?
    @State private var confirmingCancel = false
    @State private var cancelSessionID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Refold Tracker").font(.headline)
                Spacer()
                Text("Korean").foregroundStyle(.secondary)
                Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 14) {
                if let active = model.state.active {
                    Text(active.action.name).font(.headline)
                    HStack(spacing: 14) {
                        Text(durationText(model.elapsedMs))
                            .font(.system(size: 36, weight: .medium, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Button {
                            if active.pausedAt == nil { model.pause() } else { model.resume() }
                        } label: {
                            Image(systemName: active.pausedAt == nil ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.purple)
                                .frame(width: 32, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.storageHealthy)
                        .help(active.pausedAt == nil ? "Pause tracking" : "Resume tracking")
                        .accessibilityLabel(active.pausedAt == nil ? "Pause tracking" : "Resume tracking")
                    }
                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                        .opacity(active.pausedAt != nil ? 1 : 0)
                        .accessibilityHidden(active.pausedAt == nil)
                    HStack {
                        Button("Stop & Save") { model.stop() }
                            .buttonStyle(.borderedProminent).disabled(!model.storageHealthy)
                        Button("Cancel", role: .destructive) {
                            cancelSessionID = active.id
                            confirmingCancel = true
                        }.buttonStyle(.bordered).disabled(!model.storageHealthy)
                    }
                } else {
                    ForEach(TrackingAction.allCases) { action in
                        Button { model.start(action) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(action.name).foregroundStyle(.primary)
                                    Text(action.activity).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "play.fill").foregroundStyle(.purple)
                            }.padding(7).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!model.storageHealthy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 154, alignment: .top)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Learned today")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(durationText(model.learnedTodayMs))
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.8))
            }
            .padding(.vertical, 6)
            Divider()
            HStack {
                Text("Recent entries").font(.subheadline.weight(.semibold))
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(width: 16, height: 16)
                    .opacity(model.syncing ? 1 : 0)
                    .accessibilityHidden(!model.syncing)
                Button { Task { await model.sync() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.syncing).help("Refresh and verify sync")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.state.entries.filter { $0.delivery != .synced }) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            row(name: entry.action.name, duration: entry.durationMs,
                                editable: !model.syncing && [.pending, .review].contains(entry.delivery)) {
                                editTarget = EditTarget(id: entry.id.uuidString, local: entry)
                            }
                            Text(entry.delivery.label).font(.caption).foregroundStyle(.orange)
                            if let error = entry.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    ForEach(Array(model.state.remoteEntries.filter(\.isInScope).prefix(20))) { entry in
                        let pending = model.state.remoteEdits.first { $0.id == entry.id }
                        let deletion = (model.state.remoteDeletes ?? []).first { $0.id == entry.id }
                        VStack(alignment: .leading, spacing: 4) {
                            row(name: entry.name, duration: entry.durationMs,
                                editable: pending == nil && deletion == nil && !model.syncing) {
                                editTarget = EditTarget(id: entry.id, remote: entry)
                            }
                            Text("\(entry.attributedDate) · \(entry.startTime ?? "—")").font(.caption).foregroundStyle(.secondary)
                            if let pending {
                                Text("Requested: \(durationText(pending.desiredDurationMs)) — not confirmed")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(pending.error ?? "Edit awaiting confirmation").font(.caption).foregroundStyle(.orange)
                                if pending.error != nil {
                                    Button("Check and retry edit") { model.retryEdit(entry.id) }
                                        .font(.caption).disabled(model.syncing)
                                }
                            }
                            if let deletion {
                                Text(deletion.error ?? "Deletion pending")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    if model.state.entries.isEmpty && model.state.remoteEntries.isEmpty {
                        Text("Sign in to load history. Tracking also works offline.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 220)
            if let message = model.message, !message.isEmpty {
                Text(message)
                    .font(.caption).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: 40, alignment: .top)
                    .help(message)
            }
            HStack {
                Button("Sign in / open Refold") { model.adapter.showLogin() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.font(.caption)
            Text("⌃⌥R to open · sleep ends tracking").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 390,
                           height: model.message?.isEmpty == false ? 668 : 614,
                           alignment: .top)
        .transaction { $0.animation = nil }
        .alert("Discard this session?", isPresented: $confirmingCancel) {
            Button("Keep Tracking", role: .cancel) { cancelSessionID = nil }
            Button("Discard", role: .destructive) {
                if let id = cancelSessionID { model.cancelSession(id: id) }
                cancelSessionID = nil
            }
        } message: {
            Text("The current session will be discarded without saving to Refold. This cannot be undone.")
        }
        .sheet(item: $editTarget) { target in
            DurationEditor(target: target, save: { duration in
                if let local = target.local { model.editLocal(id: local.id, durationMs: duration) }
                if let remote = target.remote { model.editRemote(remote, durationMs: duration) }
            }, delete: {
                if let local = target.local { model.deleteLocal(local.id) }
                if let remote = target.remote { model.deleteRemote(remote) }
            })
        }
    }

    private func row(name: String, duration: Int64, editable: Bool, edit: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Text(name).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            Text(durationText(duration)).font(.system(.caption, design: .monospaced))
            Button(action: edit) {
                Image(systemName: "pencil").frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(!editable)
            .opacity(editable ? 1 : 0)
            .accessibilityHidden(!editable)
        }
    }
}

struct DurationEditor: View {
    let target: EditTarget
    let save: (Int64) -> Void
    let delete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hours: String
    @State private var minutes: String
    @State private var seconds: String
    @State private var confirmingDelete = false

    init(target: EditTarget, save: @escaping (Int64) -> Void, delete: @escaping () -> Void) {
        self.target = target
        self.save = save
        self.delete = delete
        let total = target.durationMs / 1_000
        _hours = State(initialValue: String(total / 3600))
        _minutes = State(initialValue: String(total / 60 % 60))
        _seconds = State(initialValue: String(total % 60))
    }

    private var duration: Int64? {
        guard let h = Int64(hours), let m = Int64(minutes), let s = Int64(seconds),
              (0...999).contains(h), (0...59).contains(m), (0...59).contains(s) else { return nil }
        let value = (h * 3600 + m * 60 + s) * 1_000
        return value > 0 ? value : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit entry").font(.headline)
                Spacer()
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete entry")
                .accessibilityLabel("Delete entry")
            }
            Text(target.name).font(.subheadline)
            HStack {
                field("Hours", text: $hours)
                field("Minutes", text: $minutes)
                field("Seconds", text: $seconds)
            }
            Text("Date, start time, activity and language stay unchanged.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    if let duration { save(duration); dismiss() }
                }.buttonStyle(.borderedProminent).disabled(duration == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 350)
        .alert("Delete this entry?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(); dismiss() }
        } message: {
            Text(target.remote == nil
                 ? "This local entry will be permanently removed. This cannot be undone."
                 : "This entry will be permanently deleted from Refold. This cannot be undone.")
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption)
            TextField("0", text: text).textFieldStyle(.roundedBorder)
        }
    }
}

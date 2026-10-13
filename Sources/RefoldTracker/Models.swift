import Foundation

enum TrackingAction: String, Codable, CaseIterable, Identifiable {
    case anki, listening, reading
    var id: String { rawValue }
    var name: String {
        switch self {
        case .anki: return "Anki"
        case .listening: return "Podcast / video listening"
        case .reading: return "문법 / 읽기 / 쓰기 / 발음"
        }
    }
    var activity: String {
        switch self {
        case .anki: return "Vocab Study"
        case .listening: return "Freeflow Listening"
        case .reading: return "Interactive Reading"
        }
    }
    var activityID: Int {
        switch self {
        case .anki: return 60202
        case .listening: return 30104
        case .reading: return 20101
        }
    }
}

enum Delivery: String, Codable {
    case pending, sending, synced, uncertain, review
    var label: String {
        switch self {
        case .pending: return "Waiting to sync"
        case .sending: return "Saving…"
        case .synced: return "Saved to Refold"
        case .uncertain: return "Unknown result — check history"
        case .review: return "Recovered — review duration"
        }
    }
}

struct LocalEntry: Codable, Identifiable {
    var id = UUID()
    var action: TrackingAction
    var startedAt: Date
    var pausedAt: Date?
    var durationMs: Int64 = 0
    var attributedDate: String
    var startTime: String
    var delivery: Delivery = .pending
    var remoteID: String?
    var error: String?
    var knownRemoteIDs: [String] = []

    init(action: TrackingAction, now: Date = Date()) {
        self.action = action
        startedAt = now
        attributedDate = Self.format(now, pattern: "yyyy-MM-dd")
        startTime = Self.format(now, pattern: "HH:mm:ss")
    }

    static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")!
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

struct RemoteEntry: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var activityId: String
    var activityName: String
    var durationMs: Int64
    var languageCode: String
    var attributedDate: String
    var startTime: String?
    var note: String?

    var isInScope: Bool {
        languageCode == "ko" && TrackingAction.allCases.contains {
            $0.name == name && String($0.activityID) == activityId
        }
    }
    func matches(_ entry: LocalEntry) -> Bool {
        name == entry.action.name && activityId == String(entry.action.activityID)
            && languageCode == "ko" && attributedDate == entry.attributedDate
            && startTime == entry.startTime && abs(durationMs - entry.durationMs) <= 1_000
    }
}

struct Snapshot: Codable {
    var active: LocalEntry?
    var entries: [LocalEntry] = []
    var remoteEntries: [RemoteEntry] = []
    var remoteEdits: [RemoteEdit] = []
    var remoteDeletes: [RemoteDelete]?
}

struct RemoteDelete: Codable, Identifiable {
    var id: String { original.id }
    var original: RemoteEntry
    var error: String?
}

struct RemoteEdit: Codable, Identifiable {
    var id: String { original.id }
    var original: RemoteEntry
    var desiredDurationMs: Int64
    var error: String?
}

func durationText(_ milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds / 1_000)
    return String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
}

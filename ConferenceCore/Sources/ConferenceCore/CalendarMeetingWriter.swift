import EventKit
import Foundation

public struct CalendarMeetingDraft: Equatable, Sendable {
    public var calendarIdentifier: String?
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var meetingURL: URL?
    public var notes: String
    public var alarmOffsetMinutesBefore: Int?

    public init(
        calendarIdentifier: String? = nil,
        title: String,
        startAt: Date,
        endAt: Date,
        meetingURL: URL? = nil,
        notes: String = "",
        alarmOffsetMinutesBefore: Int? = 10
    ) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.meetingURL = meetingURL
        self.notes = notes
        self.alarmOffsetMinutesBefore = alarmOffsetMinutesBefore
    }
}

public struct CreatedCalendarEventResult: Equatable, Sendable {
    public let eventIdentifier: String
    public let calendarIdentifier: String
    public let calendarTitle: String
    public let title: String
    public let startAt: Date
    public let endAt: Date
    public let meetingURL: URL?

    public init(
        eventIdentifier: String,
        calendarIdentifier: String,
        calendarTitle: String,
        title: String,
        startAt: Date,
        endAt: Date,
        meetingURL: URL?
    ) {
        self.eventIdentifier = eventIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.calendarTitle = calendarTitle
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.meetingURL = meetingURL
    }
}

public enum CalendarMeetingWriteError: LocalizedError, Equatable {
    case permissionDenied
    case noWritableCalendar
    case invalidDateRange
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return L("Calendar access is disabled. Allow Calendar access in System Settings or Settings app.")
        case .noWritableCalendar:
            return L("No writable calendar is available on this device.")
        case .invalidDateRange:
            return L("End time must be after start time.")
        case .saveFailed(let detail):
            return detail.isEmpty ? L("Could not save the meeting to Calendar.") : detail
        }
    }
}

public protocol CalendarMeetingWriting: Sendable {
    func requestAccessAndFetchWritableCalendars() async throws -> [WritableEventCalendarInfo]
    func createEvent(_ draft: CalendarMeetingDraft) async throws -> CreatedCalendarEventResult
}

/// Lists writable Apple calendars and persists newly created meetings via EventKit.
public actor CalendarMeetingWriter: CalendarMeetingWriting {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public static func validateDraft(_ draft: CalendarMeetingDraft) throws {
        guard draft.endAt > draft.startAt else {
            throw CalendarMeetingWriteError.invalidDateRange
        }
    }

    public func requestAccess(writeOnlyAcceptable: Bool = false) async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, macOS 14.0, *) {
            if status == .fullAccess || (writeOnlyAcceptable && status == .writeOnly) {
                return true
            }
            if status == .denied || status == .restricted {
                return false
            }
            if status == .writeOnly {
                return try await store.requestFullAccessToEvents()
            }
            return try await store.requestFullAccessToEvents()
        } else {
            if status == .authorized { return true }
            if status == .denied || status == .restricted { return false }
            return try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
        }
    }

    public func requestAccessAndFetchWritableCalendars() async throws -> [WritableEventCalendarInfo] {
        guard try await requestAccess(writeOnlyAcceptable: false) else {
            throw CalendarMeetingWriteError.permissionDenied
        }
        var calendars = store.calendars(for: .event).filter(\.allowsContentModifications)
        if calendars.isEmpty,
           let defaultCalendar = store.defaultCalendarForNewEvents,
           defaultCalendar.allowsContentModifications {
            calendars = [defaultCalendar]
        }
        return calendars
            .map {
                WritableEventCalendarInfo(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source?.title ?? L("Calendar")
                )
            }
            .sorted { ($0.sourceTitle, $0.title, $0.id) < ($1.sourceTitle, $1.title, $1.id) }
    }

    public func createEvent(_ draft: CalendarMeetingDraft) async throws -> CreatedCalendarEventResult {
        try Self.validateDraft(draft)
        guard try await requestAccess(writeOnlyAcceptable: false) else {
            throw CalendarMeetingWriteError.permissionDenied
        }

        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        let targetCalendar = writable.first(where: { $0.calendarIdentifier == draft.calendarIdentifier })
            ?? store.defaultCalendarForNewEvents.flatMap { def in def.allowsContentModifications ? def : nil }
            ?? writable.first
        guard let targetCalendar else {
            throw CalendarMeetingWriteError.noWritableCalendar
        }

        let cleanTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = cleanTitle.isEmpty ? L("New meeting") : String(cleanTitle.prefix(240))

        let event = EKEvent(eventStore: store)
        event.calendar = targetCalendar
        event.title = effectiveTitle
        event.startDate = draft.startAt
        event.endDate = draft.endAt

        if let meetingURL = draft.meetingURL {
            event.url = meetingURL
            event.location = meetingURL.absoluteString
        }

        let cleanNotes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var noteParts: [String] = []
        if !cleanNotes.isEmpty { noteParts.append(cleanNotes) }
        if let meetingURL = draft.meetingURL { noteParts.append(meetingURL.absoluteString) }
        if !noteParts.isEmpty {
            event.notes = noteParts.joined(separator: "\n\n")
        }

        if let minutes = draft.alarmOffsetMinutesBefore, minutes >= 0 {
            event.alarms = [EKAlarm(relativeOffset: -Double(minutes * 60))]
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarMeetingWriteError.saveFailed(error.localizedDescription)
        }

        return CreatedCalendarEventResult(
            eventIdentifier: event.calendarItemIdentifier,
            calendarIdentifier: targetCalendar.calendarIdentifier,
            calendarTitle: targetCalendar.title,
            title: event.title ?? effectiveTitle,
            startAt: event.startDate ?? draft.startAt,
            endAt: event.endDate ?? draft.endAt,
            meetingURL: draft.meetingURL
        )
    }
}

import ConferenceCore
import CryptoKit
import EventKit
import Foundation

enum CalendarAccess: Sendable { case notDetermined, allowed, denied }
struct MeetingCalendar: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let source: String
    var color: [Double] = [0.5, 0.5, 0.5]
}
struct CalendarSnapshot: Sendable {
    let calendars: [MeetingCalendar]
    let meetings: [CalendarMeeting]
}
protocol CalendarReading: Sendable {
    func access() async -> CalendarAccess
    func requestAccess() async throws -> Bool
    func refreshSources() async
    func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) async -> CalendarSnapshot
    func readRange(selected: Set<String>, interval: DateInterval, knownOrigins: Set<String>, aliases: [String: URL]) async -> [CalendarMeeting]
}

extension CalendarReading {
    func refreshSources() async {}
    func readRange(selected: Set<String>, interval: DateInterval, knownOrigins: Set<String>, aliases: [String: URL]) async -> [CalendarMeeting] {
        []
    }
}

/// EventKit objects never leave this actor. Only value snapshots reach the UI.
actor AppleCalendarReader: CalendarReading {
    private lazy var store = EKEventStore()
    private var lastSourcesRefresh: Date = .distantPast

    func refreshSources() {
        guard access() == .allowed else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSourcesRefresh) >= 30 else { return }
        lastSourcesRefresh = now
        store.refreshSourcesIfNecessary()
    }
    func access() -> CalendarAccess {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17, macOS 14, *) {
            if status == .fullAccess { return .allowed }
            if status == .writeOnly { return .notDetermined }
        } else if status == .authorized { return .allowed }
        return status == .notDetermined ? .notDetermined : .denied
    }
    func requestAccess() async throws -> Bool {
        if #available(iOS 17, macOS 14, *) { return try await store.requestFullAccessToEvents() }
        return try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(to: .event) { allowed, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: allowed) }
            }
        }
    }
    func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
        guard access() == .allowed else { return .init(calendars: [], meetings: []) }
        let calendars = store.calendars(for: .event)
        let options = calendars.map { calendar in
            let components = calendar.cgColor?.components ?? []
            let rgb = components.count >= 3 ? Array(components.prefix(3)) : Array(repeating: components.first ?? 0.5, count: 3)
            return MeetingCalendar(id: calendar.calendarIdentifier, name: calendar.title ?? L("Untitled calendar"),
                                   source: calendar.source?.title ?? L("Calendar account"),
                                   color: rgb.map { min(1, max(0, Double($0))) })
        }
            .sorted { ($0.source, $0.name, $0.id) < ($1.source, $1.name, $1.id) }
        let chosen = calendars.filter { selected.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return .init(calendars: options, meetings: []) }
        let day = Calendar.current.startOfDay(for: now)
        let start = Calendar.current.date(byAdding: .day, value: -30, to: day)!
        let end = Calendar.current.date(byAdding: .day, value: 30, to: day)!
        let meetings = mapEvents(
            in: DateInterval(start: start, end: end),
            calendars: chosen,
            knownOrigins: knownOrigins,
            aliases: aliases
        )
        let upcoming = Array(meetings.filter { $0.end > now }.prefix(300))
        let past = Array(meetings.filter { $0.end <= now }.suffix(300))
        return .init(calendars: options, meetings: past + upcoming)
    }
    func readRange(selected: Set<String>, interval: DateInterval, knownOrigins: Set<String>, aliases: [String: URL]) -> [CalendarMeeting] {
        guard access() == .allowed, interval.duration > 0 else { return [] }
        let chosen = store.calendars(for: .event).filter { selected.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return [] }
        return Array(mapEvents(in: interval, calendars: chosen, knownOrigins: knownOrigins, aliases: aliases).prefix(400))
    }
    private func mapEvents(in interval: DateInterval, calendars chosen: [EKCalendar], knownOrigins: Set<String>, aliases: [String: URL]) -> [CalendarMeeting] {
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: chosen)
        return store.events(matching: predicate).compactMap { event -> CalendarMeeting? in
            guard let eventCalendar = event.calendar, event.status != .canceled, let begin = event.startDate, let finish = event.endDate,
                  finish > begin, event.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) != true else { return nil }
            let groups = CalendarLinkDiscovery.groups(url: event.url, location: event.location, notes: event.notes,
                knownOrigins: knownOrigins, hintedHostFragments: VendorEndpointResolver.calendarHostHints,
                aliases: aliases, title: event.title, nativeSchemes: VendorEndpointResolver.calendarNativeSchemes)
            guard !event.isAllDay || groups.contains(where: { !$0.links.isEmpty }) else { return nil }
            let series = digest(eventCalendar.calendarIdentifier + "|" + (event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier))
            let externalSeries = event.calendarItemExternalIdentifier.map { digest("ext|" + $0) }
            let occurrence = event.occurrenceDate ?? begin
            return CalendarMeeting(id: series + "|" + String(occurrence.timeIntervalSince1970),
                seriesID: series, calendarID: eventCalendar.calendarIdentifier, calendarTitle: eventCalendar.title ?? L("Untitled calendar"),
                title: String((event.title ?? L("Untitled meeting")).prefix(160)), start: begin, end: finish,
                allDay: event.isAllDay, tentative: event.status == .tentative,
                linkGroups: groups, externalSeriesID: externalSeries, originalOccurrenceStart: occurrence)
        }.sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
    }
    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

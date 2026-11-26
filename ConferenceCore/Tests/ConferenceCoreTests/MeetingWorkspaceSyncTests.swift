import CloudKit
import Foundation
import XCTest
@testable import ConferenceCore

final class MeetingWorkspaceSyncTests: XCTestCase {
    func testNoteThreeWayMergeDisjointEditsAndConvergence() {
        let vMac = SyncVersion(counter: 2, device: "mac-1")
        let vPhone = SyncVersion(counter: 2, device: "ios-1")
        let base = """
        # Agenda
        - Intro
        - Budget review
        - Wrap up
        """
        let macEdit = """
        # Agenda
        - Intro (Alice joined)
        - Budget review
        - Wrap up
        """
        let phoneEdit = """
        # Agenda
        - Intro
        - Budget review
        - Wrap up
        - Action: send notes
        """

        let mergedAB = NoteThreeWayMerger.merge(
            base: base,
            local: macEdit,
            localVersion: vMac,
            remote: phoneEdit,
            remoteVersion: vPhone
        )
        let mergedBA = NoteThreeWayMerger.merge(
            base: base,
            local: phoneEdit,
            localVersion: vPhone,
            remote: macEdit,
            remoteVersion: vMac
        )
        XCTAssertFalse(mergedAB.hadConflict)
        XCTAssertEqual(mergedAB.markdown, mergedBA.markdown)
        XCTAssertTrue(mergedAB.markdown.contains("Alice joined"))
        XCTAssertTrue(mergedAB.markdown.contains("Action: send notes"))

        // Subsequent merge against converged remote does not duplicate lines.
        let followUp = NoteThreeWayMerger.merge(
            base: base,
            local: phoneEdit,
            localVersion: vPhone,
            remote: mergedAB.markdown,
            remoteVersion: SyncVersion(counter: 3, device: "mac-1")
        )
        XCTAssertEqual(followUp.markdown, mergedAB.markdown)
    }

    func testNoteThreeWayMergeSameLineConflictPreservesBothDeterministically() {
        let vMac = SyncVersion(counter: 4, device: "mac-a")
        let vPhone = SyncVersion(counter: 5, device: "ios-b")
        let base = "Deadline: Tuesday"
        let macEdit = "Deadline: Wednesday"
        let phoneEdit = "Deadline: Friday"

        let ab = NoteThreeWayMerger.merge(
            base: base,
            local: macEdit,
            localVersion: vMac,
            remote: phoneEdit,
            remoteVersion: vPhone
        )
        let ba = NoteThreeWayMerger.merge(
            base: base,
            local: phoneEdit,
            localVersion: vPhone,
            remote: macEdit,
            remoteVersion: vMac
        )
        XCTAssertTrue(ab.hadConflict)
        XCTAssertEqual(ab.markdown, ba.markdown)
        XCTAssertTrue(ab.markdown.contains("Friday"))
        XCTAssertTrue(ab.markdown.contains("Wednesday"))
        XCTAssertEqual(ab.archivedLoser, macEdit)
    }

    func testTranscriptMergeDeduplicatesLocalASRSuppressesOwnEchoAndHealsGaps() {
        let sessionID = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let macChunk = SyncedTranscriptChunk(
            sessionID: sessionID,
            deviceID: "mac",
            chunkIndex: 0,
            sessionStartedAt: t0,
            sessionEndedAt: t0.addingTimeInterval(120),
            micActiveIntervals: [DateInterval(start: t0, end: t0.addingTimeInterval(30))],
            events: [
                SyncedTranscriptEvent(
                    id: "srv-1",
                    providerMessageID: "chat-42",
                    kind: "chat",
                    sourceTier: 3,
                    occurredAt: t0.addingTimeInterval(5),
                    speaker: "Elena",
                    isOwn: false,
                    text: "Link posted",
                    revisions: [.init(text: "Link posted", author: "Elena", observedAt: t0.addingTimeInterval(5))],
                    isBookmarked: false,
                    deviceID: "mac"
                ),
                SyncedTranscriptEvent(
                    id: "mac-asr-1",
                    kind: "transcript",
                    sourceTier: 2,
                    occurredAt: t0.addingTimeInterval(10),
                    speaker: "You",
                    isOwn: true,
                    text: "Let's finalize the schedule for Friday",
                    deviceID: "mac"
                ),
                SyncedTranscriptEvent(
                    id: "mac-asr-2",
                    kind: "transcript",
                    sourceTier: 2,
                    occurredAt: t0.addingTimeInterval(40),
                    speaker: "Alex",
                    isOwn: false,
                    text: "Sounds great I will send the updated budget tonight",
                    deviceID: "mac"
                )
            ]
        )

        let iosChunk = SyncedTranscriptChunk(
            sessionID: sessionID,
            deviceID: "ios",
            chunkIndex: 0,
            sessionStartedAt: t0,
            sessionEndedAt: t0.addingTimeInterval(120),
            micActiveIntervals: [],
            events: [
                SyncedTranscriptEvent(
                    id: "srv-1-ios",
                    providerMessageID: "chat-42",
                    kind: "chat",
                    sourceTier: 3,
                    occurredAt: t0.addingTimeInterval(5),
                    speaker: "Elena",
                    isOwn: false,
                    text: "Link posted",
                    revisions: [.init(text: "Link posted here", author: "Elena", observedAt: t0.addingTimeInterval(6))],
                    isBookmarked: true,
                    deviceID: "ios"
                ),
                SyncedTranscriptEvent(
                    id: "ios-echo-1",
                    kind: "transcript",
                    sourceTier: 1,
                    occurredAt: t0.addingTimeInterval(10.8),
                    speaker: "Participant",
                    isOwn: true,
                    text: "finalize schedule Friday",
                    deviceID: "ios"
                ),
                SyncedTranscriptEvent(
                    id: "ios-asr-2",
                    kind: "transcript",
                    sourceTier: 1,
                    occurredAt: t0.addingTimeInterval(41.5),
                    speaker: "Alex",
                    isOwn: false,
                    text: "Sounds great I will send the updated budget tonight",
                    deviceID: "ios"
                ),
                SyncedTranscriptEvent(
                    id: "gap-1",
                    kind: "captureGap",
                    sourceTier: 1,
                    occurredAt: t0.addingTimeInterval(35),
                    endedAt: t0.addingTimeInterval(55),
                    text: "audioPaused",
                    deviceID: "ios"
                )
            ]
        )

        let merged = TranscriptMergeEngine.merge(chunks: [macChunk, iosChunk])
        XCTAssertFalse(merged.contains { $0.kind == "captureGap" })
        XCTAssertEqual(merged.filter { $0.kind == "chat" }.count, 1)
        XCTAssertEqual(merged.first(where: { $0.kind == "chat" })?.text, "Link posted here")
        XCTAssertEqual(merged.first(where: { $0.kind == "chat" })?.isBookmarked, true)

        let speech = merged.filter { $0.kind == "transcript" }
        XCTAssertEqual(speech.count, 2)
        XCTAssertEqual(speech.map(\.id), ["mac-asr-1", "mac-asr-2"])
    }

    func testOutcomePolicyDefersToOnlineMacAndMergesOfflineDualRuns() {
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        let v1 = SyncVersion(counter: 1, device: "mac")
        var session = SyncedMeetingSession(
            id: UUID(),
            occurrenceKey: "room:abc",
            title: SyncValue("Weekly Sync", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "room:abc",
            startedAt: now.addingTimeInterval(-600),
            endedAt: SyncValue(now, version: v1),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: v1),
            legs: [
                "mac": DeviceParticipationLeg(
                    deviceID: "mac",
                    deviceKind: .mac,
                    joinedAt: now.addingTimeInterval(-600),
                    leftAt: now.addingTimeInterval(-5),
                    hasOutcomeWriter: true,
                    updatedAt: now.addingTimeInterval(-5)
                ),
                "ios": DeviceParticipationLeg(
                    deviceID: "ios",
                    deviceKind: .ios,
                    joinedAt: now.addingTimeInterval(-300),
                    leftAt: now,
                    hasOutcomeWriter: true,
                    updatedAt: now
                )
            ],
            isDeleted: SyncValue(false, version: v1),
            createdAt: now,
            updatedAt: now
        )

        let deadline = OutcomeCoordinatorPolicy.deferToMacDeadline(
            session: session,
            localDeviceID: "ios",
            localIsMac: false,
            isOnline: true,
            now: now
        )
        XCTAssertNotNil(deadline)
        XCTAssertNil(
            OutcomeCoordinatorPolicy.deferToMacDeadline(
                session: session,
                localDeviceID: "ios",
                localIsMac: false,
                isOnline: false,
                now: now
            )
        )

        session.outcomeClaim = SyncValue(
            OutcomeGenerationClaim(
                ownerDeviceID: "mac",
                deviceKind: .mac,
                claimedAt: now,
                leaseExpiresAt: now.addingTimeInterval(90),
                state: "ready"
            ),
            version: SyncVersion(counter: 2, device: "mac")
        )
        XCTAssertNil(
            OutcomeCoordinatorPolicy.deferToMacDeadline(
                session: session,
                localDeviceID: "ios",
                localIsMac: false,
                isOnline: true,
                now: now
            )
        )

        // Offline dual generation: higher coverage wins, runner-up archived, human edit preserved.
        let vPhone = SyncVersion(counter: 3, device: "ios")
        let vMacEdit = SyncVersion(counter: 4, device: "mac")
        let phoneOutcome = SyncedMeetingOutcome(
            outcomeID: UUID(),
            sessionID: session.id,
            state: SyncValue("ready", version: vPhone),
            summary: SyncValue("Phone short summary", version: vPhone),
            decisions: SyncValue(["Use weekly cadence"], version: vPhone),
            openQuestions: SyncValue(["Budget approval?"], version: vPhone),
            coverageSeconds: 300,
            writerTier: 1,
            reviewCandidates: SyncValue([], version: vPhone),
            updatedAt: now,
            isDeleted: SyncValue(false, version: vPhone)
        )
        let macOutcome = SyncedMeetingOutcome(
            outcomeID: UUID(),
            sessionID: session.id,
            state: SyncValue("ready", version: vMacEdit),
            summary: SyncValue("Full Mac summary", version: vMacEdit),
            decisions: SyncValue(["Use weekly cadence", "Ship beta 117"], version: vMacEdit),
            openQuestions: SyncValue(["Who signs off?"], version: vMacEdit),
            coverageSeconds: 600,
            writerTier: 2,
            reviewCandidates: SyncValue([], version: vMacEdit),
            updatedAt: now.addingTimeInterval(2),
            isDeleted: SyncValue(false, version: vMacEdit)
        )

        let mergedA = OutcomeAndTaskMergeEngine.mergeOutcomes(local: phoneOutcome, remote: macOutcome)
        let mergedB = OutcomeAndTaskMergeEngine.mergeOutcomes(local: macOutcome, remote: phoneOutcome)
        XCTAssertEqual(mergedA, mergedB)
        XCTAssertEqual(mergedA.summary.value, "Full Mac summary")
        XCTAssertEqual(mergedA.versions.first?.summary, "Phone short summary")
        XCTAssertEqual(Set(mergedA.decisions.value), ["Use weekly cadence", "Ship beta 117"])
        XCTAssertEqual(Set(mergedA.openQuestions.value), ["Budget approval?", "Who signs off?"])

        let macTask = SyncedMeetingTask(
            id: UUID(),
            sessionID: session.id,
            outcomeID: macOutcome.outcomeID,
            ordinal: SyncValue(0, version: vMacEdit),
            text: SyncValue("Send budget spreadsheet to Anna", version: vMacEdit),
            owner: SyncValue("Alex", version: vMacEdit),
            assigneeID: SyncValue(nil, version: vMacEdit),
            dueDay: SyncValue(nil, version: vMacEdit),
            dueAt: SyncValue(nil, version: vMacEdit),
            reminderAt: SyncValue(nil, version: vMacEdit),
            done: SyncValue(false, version: vMacEdit),
            completedAt: SyncValue(nil, version: vMacEdit),
            isDeleted: SyncValue(false, version: vMacEdit)
        )
        let phoneMatchingTask = SyncedMeetingTask(
            id: UUID(),
            sessionID: session.id,
            outcomeID: phoneOutcome.outcomeID,
            ordinal: SyncValue(0, version: vPhone),
            text: SyncValue("Send budget spreadsheet to Anna", version: SyncVersion(counter: 1, device: "ios")),
            owner: SyncValue("Alex", version: vPhone),
            assigneeID: SyncValue(nil, version: vPhone),
            dueDay: SyncValue(nil, version: vPhone),
            dueAt: SyncValue(nil, version: vPhone),
            reminderAt: SyncValue(nil, version: vPhone),
            done: SyncValue(true, version: SyncVersion(counter: 10, device: "ios")),
            completedAt: SyncValue(now, version: SyncVersion(counter: 10, device: "ios")),
            isDeleted: SyncValue(false, version: vPhone)
        )
        let phoneExtraTask = SyncedMeetingTask(
            id: UUID(),
            sessionID: session.id,
            outcomeID: phoneOutcome.outcomeID,
            ordinal: SyncValue(1, version: vPhone),
            text: SyncValue("Book rehearsal room B", version: vPhone),
            owner: SyncValue("Vlad", version: vPhone),
            assigneeID: SyncValue(nil, version: vPhone),
            dueDay: SyncValue(nil, version: vPhone),
            dueAt: SyncValue(nil, version: vPhone),
            reminderAt: SyncValue(nil, version: vPhone),
            done: SyncValue(false, version: vPhone),
            completedAt: SyncValue(nil, version: vPhone),
            isDeleted: SyncValue(false, version: vPhone)
        )
        let reconciled = OutcomeAndTaskMergeEngine.reconcileDualGeneratedTasks(
            primary: [macTask],
            secondary: [phoneMatchingTask, phoneExtraTask],
            sessionID: session.id,
            version: vMacEdit
        )
        XCTAssertEqual(reconciled.merged.count, 1)
        XCTAssertEqual(reconciled.merged.first?.done.value, true)
        XCTAssertEqual(reconciled.links.count, 1)
        XCTAssertEqual(reconciled.links.first?.canonicalTaskID, macTask.id)
        XCTAssertEqual(reconciled.reviewCandidates.map(\.text), ["Book rehearsal room B"])
    }

    func testSessionCoalescingAndTieredTranscriptRetention() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var doc = MeetingWorkspaceSyncDocument(device: "mac")
        let s1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let s2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let v1 = doc.nextVersion()
        doc.upsertSession(SyncedMeetingSession(
            id: s1,
            occurrenceKey: "cal:series1:100",
            title: SyncValue("Design Review", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "rock.glowsoft.ru · design",
            startedAt: now,
            endedAt: SyncValue(nil, version: v1),
            timeZoneID: "UTC",
            state: SyncValue("active", version: v1),
            legs: ["mac": .init(deviceID: "mac", deviceKind: .mac, joinedAt: now)],
            isDeleted: SyncValue(false, version: v1),
            createdAt: now,
            updatedAt: now
        ))
        let v2 = SyncVersion(counter: 1, device: "ios")
        doc.upsertSession(SyncedMeetingSession(
            id: s2,
            occurrenceKey: "cal:series1:100",
            title: SyncValue("Design Review", version: v2),
            hasTitleOverride: SyncValue(false, version: v2),
            invitation: SyncValue(nil, version: v2),
            roomIdentity: "rock.glowsoft.ru · design",
            startedAt: now.addingTimeInterval(60),
            endedAt: SyncValue(nil, version: v2),
            timeZoneID: "UTC",
            state: SyncValue("active", version: v2),
            legs: ["ios": .init(deviceID: "ios", deviceKind: .ios, joinedAt: now.addingTimeInterval(60))],
            isDeleted: SyncValue(false, version: v2),
            createdAt: now,
            updatedAt: now
        ))
        doc.saveNote(sessionID: s2, markdown: "iPhone note line", now: now)
        let redirects = doc.coalesceOverlappingSessions()
        XCTAssertEqual(redirects.count, 1)
        XCTAssertEqual(doc.resolveCanonicalSessionID(for: s2), s1)
        XCTAssertEqual(doc.notes[s1]?.markdown, "iPhone note line")
        XCTAssertEqual(doc.sessions[s1]?.legs.keys.sorted(), ["ios", "mac"])

        // Transcript retention pruning: 10-day-old chunk expires under 7-day policy, stays under 30-day.
        let oldDate = now.addingTimeInterval(-10 * 86_400)
        let chunk = SyncedTranscriptChunk(
            sessionID: s1,
            deviceID: "mac",
            chunkIndex: 0,
            sessionStartedAt: oldDate,
            events: [.init(id: "e1", kind: "transcript", occurredAt: oldDate, text: "hello", deviceID: "mac")]
        )
        _ = doc.mergeTranscriptRecords([.chunk(chunk)])
        XCTAssertEqual(doc.expiredCloudTranscriptRecordIDs(retention: .days30, now: now), [])
        XCTAssertEqual(doc.expiredCloudTranscriptRecordIDs(retention: .days7, now: now), ["transcript:" + chunk.id])
        XCTAssertEqual(doc.transcriptRecordsForCloud(retention: .days7, now: now), [])
        XCTAssertEqual(doc.mergedTranscript(for: s1).count, 1)
    }

    func testLegacyCalendarAssociationRequiresUniqueRoomWindowAndHonorsSeparateChoice() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try XCTUnwrap(URL(string: "https://rock.glowsoft.ru/jams/history?name=Mac"))
        let room = try XCTUnwrap(MeetingRoomIdentity(url))
        let event = CalendarMeeting(id: "one", seriesID: "series", calendarID: "work", calendarTitle: "Work",
            title: "Review", start: start, end: start + 1800)
        let next = CalendarMeeting(id: "two", seriesID: "series", calendarID: "work", calendarTitle: "Work",
            title: "Review", start: start + 1800, end: start + 3600)
        let link = MeetingCalendarAssociation(event, room: room)
        let nextLink = MeetingCalendarAssociation(next, room: room)
        var doc = MeetingWorkspaceSyncDocument(device: "mac")
        func entry(_ at: Date, _ version: SyncVersion) -> SyncedMeetingSession {
            SyncedMeetingSession(id: UUID(), occurrenceKey: "legacy", title: SyncValue("Review", version: version),
                hasTitleOverride: SyncValue(false, version: version), invitation: SyncValue(url, version: version),
                roomIdentity: "legacy", startedAt: at, endedAt: SyncValue(at + 60, version: version),
                timeZoneID: "UTC", state: SyncValue("ended", version: version),
                isDeleted: SyncValue(false, version: version), createdAt: at, updatedAt: at)
        }
        let first = entry(start, doc.nextVersion())
        let second = entry(start + 900, doc.nextVersion())
        let other = entry(start + 1900, doc.nextVersion())
        var separate = entry(start + 1200, doc.nextVersion())
        separate.calendarAssociation = SyncValue(link, version: doc.nextVersion())
        separate.historyGroupParent = SyncValue(nil, version: doc.nextVersion())
        for row in [first, second, other, separate] { doc.upsertSession(row) }
        XCTAssertEqual(doc.inferCalendarAssociations(from: [link, nextLink]), [first.id, second.id, other.id])
        XCTAssertEqual(doc.sessions[other.id]?.calendarAssociation?.value, nextLink)
        XCTAssertTrue(doc.coalesceOverlappingSessions(excludingSessions: [second.id]).isEmpty)
        XCTAssertEqual(doc.resolveCanonicalSessionID(for: second.id), second.id)
        XCTAssertEqual(doc.coalesceOverlappingSessions().count, 1)
        XCTAssertEqual(doc.resolveCanonicalSessionID(for: second.id), first.id)
        XCTAssertEqual(doc.resolveCanonicalSessionID(for: separate.id), separate.id)
        XCTAssertEqual(doc.resolveCanonicalSessionID(for: other.id), other.id)
    }

    func testCalendarOccurrenceUsesOriginalDateAndMergesSequentialMacAndPhoneJoins() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let ends = start + 30 * 60
        let macURL = try XCTUnwrap(URL(string: "https://rock.glowsoft.ru/jams/history?name=Mac"))
        let phoneURL = try XCTUnwrap(URL(string: "https://rock.glowsoft.ru/jams/history?name=iPhone"))
        let macRoom = try XCTUnwrap(MeetingRoomIdentity(macURL))
        let phoneRoom = try XCTUnwrap(MeetingRoomIdentity(phoneURL))
        let first = CalendarMeeting(id: "mac", seriesID: "private-mac", calendarID: "work", calendarTitle: "Work",
            title: "Review", start: start, end: ends, externalSeriesID: "shared-series", originalOccurrenceStart: start)
        let moved = CalendarMeeting(id: "phone", seriesID: "private-phone", calendarID: "work", calendarTitle: "Work",
            title: "Review", start: start + 60, end: ends + 60, externalSeriesID: "shared-series", originalOccurrenceStart: start)
        let nextWeek = CalendarMeeting(id: "next", seriesID: "private-phone", calendarID: "work", calendarTitle: "Work",
            title: "Review", start: start + 604_800, end: ends + 604_800, externalSeriesID: "shared-series")
        let firstLink = MeetingCalendarAssociation(first, room: macRoom)
        let movedLink = MeetingCalendarAssociation(moved, room: phoneRoom)
        let nextWeekLink = MeetingCalendarAssociation(nextWeek, room: phoneRoom)
        XCTAssertTrue(firstLink.matches(movedLink))
        XCTAssertFalse(firstLink.matches(nextWeekLink))
        XCTAssertTrue(firstLink.allowsRejoin(at: ends + 20 * 60))
        XCTAssertFalse(firstLink.allowsRejoin(at: ends + 20 * 60, before: ends + 15 * 60))

        var doc = MeetingWorkspaceSyncDocument(device: "mac")
        let macID = UUID(), phoneID = UUID(), nextID = UUID()
        let macFirstInterval = UUID(), macSecondInterval = UUID(), phoneInterval = UUID()
        var macLeg = DeviceParticipationLeg(deviceID: "mac", deviceKind: .mac, joinedAt: start, leftAt: start + 42 * 60)
        macLeg.beginInterval(id: macFirstInterval, at: start)
        macLeg.endInterval(id: macFirstInterval, at: start + 18 * 60)
        macLeg.beginInterval(id: macSecondInterval, at: start + 29 * 60)
        macLeg.endInterval(id: macSecondInterval, at: start + 42 * 60)
        var phoneLeg = DeviceParticipationLeg(deviceID: "phone", deviceKind: .ios, joinedAt: start + 19 * 60, leftAt: start + 27 * 60)
        phoneLeg.beginInterval(id: phoneInterval, at: start + 19 * 60)
        phoneLeg.endInterval(id: phoneInterval, at: start + 27 * 60)

        func entry(_ id: UUID, _ key: String, _ link: MeetingCalendarAssociation?,
                   _ leg: DeviceParticipationLeg, _ version: SyncVersion) -> SyncedMeetingSession {
            SyncedMeetingSession(id: id, occurrenceKey: key, calendarAssociation: SyncValue(link, version: version),
                title: SyncValue("Review", version: version), hasTitleOverride: SyncValue(false, version: version),
                invitation: SyncValue(nil, version: version), roomIdentity: key, startedAt: leg.joinedAt,
                endedAt: SyncValue(leg.leftAt, version: version), timeZoneID: "UTC",
                state: SyncValue("ended", version: version), legs: [leg.deviceID: leg],
                isDeleted: SyncValue(false, version: version), createdAt: start, updatedAt: leg.leftAt ?? start)
        }

        let mac = entry(macID, "mac-legacy-room", firstLink, macLeg, doc.nextVersion())
        let phone = entry(phoneID, "phone-legacy-room", movedLink, phoneLeg, doc.nextVersion())
        let next = entry(nextID, "mac-legacy-room", nextWeekLink, phoneLeg, doc.nextVersion())
        for session in [mac, phone, next] { doc.upsertSession(session) }
        XCTAssertEqual(doc.coalesceOverlappingSessions().count, 1)
        XCTAssertEqual(doc.resolveCanonicalSessionID(for: phoneID), macID)
        XCTAssertEqual(doc.resolveCanonicalSessionID(for: nextID), nextID)
        XCTAssertEqual(doc.sessions[macID]?.legs["mac"]?.intervals?.count, 2)
        XCTAssertEqual(doc.sessions[macID]?.legs["phone"]?.intervals?[phoneInterval]?.leftAt, start + 27 * 60)
        XCTAssertTrue(doc.coalesceOverlappingSessions().isEmpty)

        let saved = try JSONDecoder().decode(MeetingWorkspaceSyncDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(saved, doc)
    }

    func testManualHistoryGroupingCanBeUndoneWithoutMovingSourceContent() throws {
        let first = UUID(), second = UUID()
        let visible: Set<UUID> = [first, second]
        var doc = MeetingWorkspaceSyncDocument(device: "mac")
        doc.saveNote(sessionID: second, markdown: "Original note")
        let link = SyncValue<UUID?>(first, version: doc.nextVersion())
        XCTAssertEqual(doc.resolveHistorySessionID(for: second, visibleIDs: visible) {
            $0 == second ? link : nil
        }, first)
        let unlink = SyncValue<UUID?>(nil, version: doc.nextVersion())
        XCTAssertEqual(doc.resolveHistorySessionID(for: second, visibleIDs: visible) {
            $0 == second ? unlink : nil
        }, second)
        XCTAssertEqual(doc.notes[second]?.markdown, "Original note")
        XCTAssertNil(doc.notes[first])
    }

    func testCalendarScheduleDocumentMergesAndPrunes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var macDoc = CalendarScheduleSyncDocument(device: "mac")
        var phoneDoc = CalendarScheduleSyncDocument(device: "ios")
        let link = URL(string: "https://rock.glowsoft.ru/jams/daily")!
        var meeting = CalendarMeeting(
            id: "ev-1",
            seriesID: "ser-1",
            calendarID: "cal-1",
            calendarTitle: "Work",
            title: "Daily Standup",
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(5400),
            links: [link],
            externalSeriesID: "ext-ser-1"
        )
        meeting.invitation = link
        meeting.engine = .community

        macDoc.updateLocalMeetings([meeting], bindings: [:], suppressed: [:], reminderStates: [:], now: now)
        _ = phoneDoc.merge(macDoc.records)
        XCTAssertEqual(phoneDoc.projectedOccurrences(now: now).map(\.title), ["Daily Standup"])

        phoneDoc.setOccurrenceState(occurrenceKey: meeting.occurrenceSyncKey, skipped: true, now: now.addingTimeInterval(5))
        _ = macDoc.merge(phoneDoc.records)
        XCTAssertEqual(macDoc.occurrences[meeting.occurrenceSyncKey]?.skipped?.value, true)

        let expiredIDs = macDoc.pruneExpired(now: now.addingTimeInterval(60 * 3600))
        XCTAssertEqual(expiredIDs, ["cal:" + meeting.occurrenceSyncKey])
        XCTAssertTrue(macDoc.occurrences.isEmpty)
    }

    func testPayloadCompressionRoundtripAndArchiveStore() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID()
        let events = (0..<60).map { idx in
            SyncedTranscriptEvent(
                id: "ev-\(idx)",
                kind: "transcript",
                occurredAt: now.addingTimeInterval(Double(idx * 5)),
                speaker: "Speaker \(idx % 3)",
                text: "Testing LZFSE compression across repeated meeting transcript segments number \(idx).",
                deviceID: "mac"
            )
        }
        let chunk = SyncedTranscriptChunk(
            sessionID: sessionID,
            deviceID: "mac",
            chunkIndex: 0,
            sessionStartedAt: now,
            events: events
        )
        let encoded = try CloudPayloadCodec.encode(chunk)
        let decoded = try CloudPayloadCodec.decode(encoded, as: SyncedTranscriptChunk.self)
        XCTAssertEqual(decoded, chunk)

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let archive = TranscriptArchiveStore(root: tempRoot)
        let v = SyncVersion(counter: 1, device: "mac")
        let session = SyncedMeetingSession(
            id: sessionID,
            occurrenceKey: "room:1",
            title: SyncValue("Archive Test", version: v),
            hasTitleOverride: SyncValue(false, version: v),
            invitation: SyncValue(nil, version: v),
            roomIdentity: "rock.glowsoft.ru · test",
            startedAt: now,
            endedAt: SyncValue(now.addingTimeInterval(300), version: v),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: v),
            isDeleted: SyncValue(false, version: v),
            createdAt: now,
            updatedAt: now
        )
        try await archive.archive(session: session, events: events)
        let loaded = await archive.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(loaded?.count, events.count)
        let stats = await archive.stats()
        XCTAssertEqual(stats.archivedCount, 1)
        XCTAssertGreaterThan(stats.totalBytes, 0)
    }

    func testCoalesceExcludesSameSingleDevicePairsAndReadsDocumentContextSettings() {
        let now = Date()
        var doc = MeetingWorkspaceSyncDocument(device: "ios-1")
        let macOnlyV1 = SyncVersion(counter: 1, device: "mac-1")
        let macOnlyV2 = SyncVersion(counter: 2, device: "mac-1")
        let macA = UUID()
        let macB = UUID()

        doc.upsertSession(SyncedMeetingSession(
            id: macA,
            occurrenceKey: "room:daily-a",
            title: SyncValue("Daily 1", version: macOnlyV1),
            hasTitleOverride: SyncValue(false, version: macOnlyV1),
            invitation: SyncValue(nil, version: macOnlyV1),
            roomIdentity: "rock.glowsoft.ru · daily",
            startedAt: now,
            endedAt: SyncValue(nil, version: macOnlyV1),
            timeZoneID: "UTC",
            state: SyncValue("active", version: macOnlyV1),
            legs: ["mac-1": .init(deviceID: "mac-1", deviceKind: .mac, joinedAt: now)],
            isDeleted: SyncValue(false, version: macOnlyV1),
            createdAt: now,
            updatedAt: now
        ))
        doc.upsertSession(SyncedMeetingSession(
            id: macB,
            occurrenceKey: "room:daily-b",
            title: SyncValue("Daily 2", version: macOnlyV2),
            hasTitleOverride: SyncValue(false, version: macOnlyV2),
            invitation: SyncValue(nil, version: macOnlyV2),
            roomIdentity: "rock.glowsoft.ru · daily",
            startedAt: now.addingTimeInterval(60),
            endedAt: SyncValue(nil, version: macOnlyV2),
            timeZoneID: "UTC",
            state: SyncValue("active", version: macOnlyV2),
            legs: ["mac-1": .init(deviceID: "mac-1", deviceKind: .mac, joinedAt: now.addingTimeInterval(60))],
            isDeleted: SyncValue(false, version: macOnlyV2),
            createdAt: now.addingTimeInterval(60),
            updatedAt: now.addingTimeInterval(60)
        ))

        let noRedirects = doc.coalesceOverlappingSessions()
        XCTAssertTrue(noRedirects.isEmpty)
        XCTAssertEqual(doc.resolveCanonicalSessionID(for: macA), macA)
        XCTAssertEqual(doc.resolveCanonicalSessionID(for: macB), macB)

        // Separate-sessions setting stored inside doc.contextSettings is honored directly without external closure state.
        let vCfg = SyncVersion(counter: 3, device: "mac-1")
        doc.upsertContextSettings(SyncedMeetingContextSettings(
            scopeKey: "room:rock.glowsoft.ru · cal-sep",
            scopeKind: .room,
            title: SyncValue("Cal Sep", version: vCfg),
            sameRoomTransition: SyncValue("separateSessions", version: vCfg)
        ))
        let s1 = UUID()
        let s2 = UUID()
        doc.upsertSession(SyncedMeetingSession(
            id: s1,
            occurrenceKey: "cal:sep:1",
            title: SyncValue("Part 1", version: vCfg),
            hasTitleOverride: SyncValue(false, version: vCfg),
            invitation: SyncValue(nil, version: vCfg),
            roomIdentity: "rock.glowsoft.ru · cal-sep",
            startedAt: now,
            endedAt: SyncValue(now.addingTimeInterval(120), version: vCfg),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: vCfg),
            legs: ["mac-1": .init(deviceID: "mac-1", deviceKind: .mac, joinedAt: now)],
            isDeleted: SyncValue(false, version: vCfg),
            createdAt: now,
            updatedAt: now
        ))
        let vIOS = SyncVersion(counter: 1, device: "ios-1")
        doc.upsertSession(SyncedMeetingSession(
            id: s2,
            occurrenceKey: "cal:sep:1",
            title: SyncValue("Part 2", version: vIOS),
            hasTitleOverride: SyncValue(false, version: vIOS),
            invitation: SyncValue(nil, version: vIOS),
            roomIdentity: "rock.glowsoft.ru · cal-sep",
            startedAt: now.addingTimeInterval(240),
            endedAt: SyncValue(now.addingTimeInterval(360), version: vIOS),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: vIOS),
            legs: ["ios-1": .init(deviceID: "ios-1", deviceKind: .ios, joinedAt: now.addingTimeInterval(240))],
            isDeleted: SyncValue(false, version: vIOS),
            createdAt: now.addingTimeInterval(240),
            updatedAt: now.addingTimeInterval(240)
        ))
        let sepRedirects = doc.coalesceOverlappingSessions()
        XCTAssertTrue(sepRedirects.isEmpty)
    }

    func testCloudKitRateLimitExtractsRetryAfterAndExponentialBackoff() {
        let withHint = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.requestRateLimited.rawValue,
            userInfo: [CKErrorRetryAfterKey: 28.0]
        )
        XCTAssertEqual(CloudKitRateLimit.retryAfter(for: withHint, consecutiveFailures: 1), 28.0)

        let withoutHint = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.serviceUnavailable.rawValue,
            userInfo: [:]
        )
        XCTAssertEqual(CloudKitRateLimit.retryAfter(for: withoutHint, consecutiveFailures: 1), 15.0)
        XCTAssertEqual(CloudKitRateLimit.retryAfter(for: withoutHint, consecutiveFailures: 2), 30.0)
        XCTAssertEqual(CloudKitRateLimit.retryAfter(for: withoutHint, consecutiveFailures: 5), 120.0)

        let partialRateLimit = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: ["rec-1": withHint]]
        )
        XCTAssertEqual(CloudKitRateLimit.retryAfter(for: partialRateLimit, consecutiveFailures: 1), 28.0)

        let nonThrottle = NSError(domain: CKError.errorDomain, code: CKError.Code.unknownItem.rawValue)
        XCTAssertNil(CloudKitRateLimit.retryAfter(for: nonThrottle))
        XCTAssertNil(CloudKitRateLimit.retryAfter(for: CloudZoneError.noAccount))
    }

    func testCalendarScheduleDeduplicatesCrossPlatformExternalIDsAndAvoidsNoOpRewrites() {
        let now = Date(timeIntervalSince1970: 1_795_070_000)
        let start = now.addingTimeInterval(1800)
        let end = now.addingTimeInterval(3600)
        let roomA = URL(string: "https://salutejazz.ru/j1ds87")!
        let roomB = URL(string: "https://salutejazz.ru/q01xx4")!

        var macMeeting = CalendarMeeting(
            id: "mac-ev-1",
            seriesID: "mac-cal-series",
            calendarID: "mac-cal",
            calendarTitle: "Календарь",
            title: "FW: рг.5 Утр. синк",
            start: start,
            end: end,
            links: [roomA],
            externalSeriesID: "a-mac-ext-1"
        )
        macMeeting.invitation = roomA
        macMeeting.engine = .community

        let phoneMeeting = CalendarMeeting(
            id: "ios-ev-1",
            seriesID: "ios-cal-series",
            calendarID: "ios-cal",
            calendarTitle: "Work Calendar",
            title: "FW: рг.5 Утр. синк",
            start: start,
            end: end,
            links: [roomA],
            externalSeriesID: "z-ios-ext-1"
        )

        var parallelPhoneMeeting = CalendarMeeting(
            id: "ios-ev-2",
            seriesID: "ios-cal-series-2",
            calendarID: "ios-cal",
            calendarTitle: "Work Calendar",
            title: "Infra daily [Cloud]",
            start: start,
            end: end,
            links: [roomB],
            externalSeriesID: "z-ios-ext-2"
        )
        parallelPhoneMeeting.invitation = roomB
        parallelPhoneMeeting.engine = .community

        var macDoc = CalendarScheduleSyncDocument(device: "mac")
        var phoneDoc = CalendarScheduleSyncDocument(device: "ios")

        // Simulate both devices having already uploaded separate records for the same event before merging.
        macDoc.updateLocalMeetings([macMeeting], bindings: [:], suppressed: [:], reminderStates: [:], now: now)
        phoneDoc.updateLocalMeetings([phoneMeeting, parallelPhoneMeeting], bindings: [:], suppressed: [:], reminderStates: [:], now: now.addingTimeInterval(1))
        let countBeforeRepeat = phoneDoc.counter
        let snapshotRecordsBeforeRepeat = phoneDoc.records

        // Repeat pass with unchanged local calendar must be a strict no-op (counter and records unchanged).
        phoneDoc.updateLocalMeetings([phoneMeeting, parallelPhoneMeeting], bindings: [:], suppressed: [:], reminderStates: [:], now: now.addingTimeInterval(20))
        XCTAssertEqual(phoneDoc.counter, countBeforeRepeat)
        XCTAssertEqual(phoneDoc.records, snapshotRecordsBeforeRepeat)

        // Merge both zones; projectedOccurrences immediately deduplicates to 2 unique meetings (1 synced + 1 parallel).
        _ = macDoc.merge(phoneDoc.records)
        _ = phoneDoc.merge(macDoc.records)
        XCTAssertEqual(Set(macDoc.projectedOccurrences(now: now).map(\.title)), ["FW: рг.5 Утр. синк", "Infra daily [Cloud]"])
        XCTAssertEqual(macDoc.projectedOccurrences(now: now).count, 2)
        XCTAssertEqual(phoneDoc.projectedOccurrences(now: now).count, 2)

        // Next sync pass on both devices converges onto the deterministic smaller occurrenceKey and tombstones the duplicate.
        macDoc.updateLocalMeetings([macMeeting], bindings: [:], suppressed: [:], reminderStates: [:], now: now.addingTimeInterval(30))
        phoneDoc.updateLocalMeetings([phoneMeeting, parallelPhoneMeeting], bindings: [:], suppressed: [:], reminderStates: [:], now: now.addingTimeInterval(31))
        _ = macDoc.merge(phoneDoc.records)
        _ = phoneDoc.merge(macDoc.records)

        let activeMac = macDoc.projectedOccurrences(now: now)
        let activePhone = phoneDoc.projectedOccurrences(now: now)
        XCTAssertEqual(activeMac.count, 2)
        XCTAssertEqual(activePhone.count, 2)
        XCTAssertEqual(activeMac.first(where: { $0.title == "FW: рг.5 Утр. синк" })?.sourceDevices.keys.sorted(), ["ios", "mac"])
        XCTAssertEqual(phoneDoc.occurrences[phoneMeeting.occurrenceSyncKey]?.isDeleted.value, true)

        // Repeat steady-state pass after convergence must emit zero counter/record mutations on either device.
        let macSteadyCounter = macDoc.counter
        let macSteadyRecords = macDoc.records
        let phoneSteadyCounter = phoneDoc.counter
        let phoneSteadyRecords = phoneDoc.records
        macDoc.updateLocalMeetings([macMeeting], bindings: [:], suppressed: [:], reminderStates: [:], now: now.addingTimeInterval(60))
        phoneDoc.updateLocalMeetings([phoneMeeting, parallelPhoneMeeting], bindings: [:], suppressed: [:], reminderStates: [:], now: now.addingTimeInterval(61))
        XCTAssertEqual(macDoc.counter, macSteadyCounter)
        XCTAssertEqual(macDoc.records, macSteadyRecords)
        XCTAssertEqual(phoneDoc.counter, phoneSteadyCounter)
        XCTAssertEqual(phoneDoc.records, phoneSteadyRecords)
    }

    func testCanonicalTaskProfilePrefersConfiguredHigherCounterAndNonDefaultID() {
        var doc = MeetingWorkspaceSyncDocument(device: "ios-1")
        let emptyUUID = SyncedTaskProfile(
            profileID: "ZZZZZZZZ-0000-0000-0000-000000000001",
            assigneeID: SyncValue(nil, version: SyncVersion(counter: 10, device: "mac-2")),
            aliases: SyncValue([], version: SyncVersion(counter: 10, device: "mac-2"))
        )
        let uuidLow = SyncedTaskProfile(
            profileID: "AAAAAAAA-0000-0000-0000-000000000001",
            assigneeID: SyncValue(nil, version: SyncVersion(counter: 1, device: "mac-1")),
            aliases: SyncValue(["Vitalii"], version: SyncVersion(counter: 1, device: "mac-1"))
        )
        let defaultCounterZero = SyncedTaskProfile(
            profileID: "default",
            assigneeID: SyncValue(nil, version: SyncVersion(counter: 0, device: "ios-1")),
            aliases: SyncValue(["Phone Alias"], version: SyncVersion(counter: 0, device: "ios-1"))
        )
        doc.upsertTaskProfile(emptyUUID)
        doc.upsertTaskProfile(defaultCounterZero)
        XCTAssertEqual(doc.canonicalTaskProfile?.profileID, "default")
        XCTAssertEqual(doc.canonicalTaskProfile?.aliases.value, ["Phone Alias"])

        doc.upsertTaskProfile(uuidLow)
        XCTAssertEqual(doc.canonicalTaskProfile?.profileID, uuidLow.profileID)

        // Same configured counter prefers non-default UUID over "default".
        let defaultSameCounter = SyncedTaskProfile(
            profileID: "default",
            assigneeID: SyncValue(nil, version: SyncVersion(counter: 1, device: "ios-1")),
            aliases: SyncValue(["Phone"], version: SyncVersion(counter: 1, device: "ios-1"))
        )
        doc.upsertTaskProfile(defaultSameCounter)
        XCTAssertEqual(doc.canonicalTaskProfile?.profileID, uuidLow.profileID)

        // Higher counter wins even on "default".
        let defaultNewer = SyncedTaskProfile(
            profileID: "default",
            assigneeID: SyncValue("Vitalii", version: SyncVersion(counter: 5, device: "ios-1")),
            aliases: SyncValue(["Vitalii", "Виталий"], version: SyncVersion(counter: 5, device: "ios-1"))
        )
        doc.upsertTaskProfile(defaultNewer)
        XCTAssertEqual(doc.canonicalTaskProfile?.profileID, "default")
    }

    func testCloudEnvelopeChangedItemDecodeSkipsCorruptPayloadWhilePropagatingGenerationMismatch() throws {
        struct TestEnvelope: Codable {
            var schema: Int
            var generation: String
            var record: MeetingLibrarySyncRecord
        }
        let zone = CKRecordZone.ID(zoneName: "MeetingLibrary", ownerName: CKCurrentUserDefaultName)
        let v1 = SyncVersion(counter: 1, device: "mac-1")
        let note = SyncedMeetingNote(
            sessionID: UUID(),
            noteID: UUID(),
            markdown: "Valid payload",
            version: v1,
            updatedAt: Date(),
            isDeleted: SyncValue(false, version: v1)
        )
        let record = MeetingLibrarySyncRecord.note(note)
        let recordName = CloudEnvelopeTransport<MeetingLibrarySyncRecord>.cloudRecordName(for: record.syncRecordID)
        let ckID = CKRecord.ID(recordName: recordName, zoneID: zone)

        // 1. Corrupted JSON/LZFSE bytes are skipped cleanly instead of poisoning the zone fetch.
        let corrupt = try CloudEnvelopeTransport<MeetingLibrarySyncRecord>.decodeChangedItemPayload(
            Data("not-json-at-all".utf8),
            hasChangeTag: true,
            recordID: ckID,
            generation: "gen-1",
            zone: zone
        )
        XCTAssertNil(corrupt)

        // 2. Future schema record is skipped cleanly instead of poisoning the zone fetch.
        let futurePayload = try CloudPayloadCodec.encode(TestEnvelope(schema: 99, generation: "gen-1", record: record))
        let future = try CloudEnvelopeTransport<MeetingLibrarySyncRecord>.decodeChangedItemPayload(
            futurePayload,
            hasChangeTag: true,
            recordID: ckID,
            generation: "gen-1",
            zone: zone
        )
        XCTAssertNil(future)

        // 3. Valid schema-2 record decodes intact.
        let validPayload = try CloudPayloadCodec.encode(TestEnvelope(schema: 2, generation: "gen-1", record: record))
        let decoded = try CloudEnvelopeTransport<MeetingLibrarySyncRecord>.decodeChangedItemPayload(
            validPayload,
            hasChangeTag: true,
            recordID: ckID,
            generation: "gen-1",
            zone: zone
        )
        XCTAssertEqual(decoded, record)

        // 4. Zone generation change MUST still throw so the transport resets its zone session.
        XCTAssertThrowsError(
            try CloudEnvelopeTransport<MeetingLibrarySyncRecord>.decodeChangedItemPayload(
                validPayload,
                hasChangeTag: true,
                recordID: ckID,
                generation: "gen-2",
                zone: zone
            )
        ) { error in
            XCTAssertEqual(error as? CloudZoneError, .generationChanged)
        }
    }

    func testSyncedMeetingContextSettingsAutoJoinAndFacilitatorSkillRoundTripAndMerge() throws {
        let v1 = SyncVersion(counter: 1, device: "mac-1")
        let v2 = SyncVersion(counter: 2, device: "ios-1")
        let initial = SyncedMeetingContextSettings(
            scopeKey: "series:cto-daily",
            scopeKind: .calendarSeries,
            title: SyncValue("CTO Daily", version: v1),
            autoJoin: SyncValue(true, version: v1),
            autoFacilitatorSkillID: SyncValue(nil, version: v1)
        )
        let encoded = try JSONEncoder().encode(initial)
        let decoded = try JSONDecoder().decode(SyncedMeetingContextSettings.self, from: encoded)
        XCTAssertEqual(decoded, initial)
        XCTAssertEqual(decoded.autoJoin?.value, true)
        XCTAssertNil(decoded.autoFacilitatorSkillID?.value ?? nil)

        let remote = SyncedMeetingContextSettings(
            scopeKey: "series:cto-daily",
            scopeKind: .calendarSeries,
            title: SyncValue("CTO Daily", version: v1),
            autoJoin: SyncValue(false, version: v2),
            autoFacilitatorSkillID: SyncValue("scrum-master", version: v2)
        )
        let merged = decoded.merging(remote)
        XCTAssertEqual(merged.autoJoin?.value, false)
        XCTAssertEqual(merged.autoFacilitatorSkillID?.value, "scrum-master")
        XCTAssertEqual(merged.maximumCounter, 2)

        // Legacy payloads missing autoJoin/autoFacilitatorSkillID still decode cleanly as nil.
        let legacyJSON = """
        {"scopeKey":"room:standup","scopeKind":"room","title":{"value":"Standup","version":{"counter":1,"device":"mac-1"}},"guidanceRules":[]}
        """
        let legacy = try JSONDecoder().decode(SyncedMeetingContextSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.autoJoin)
        XCTAssertNil(legacy.autoFacilitatorSkillID)
    }

    func testSyncedMeetingContextSettingsMergesJiraConfigAndAutoExportTriStateOverrides() throws {
        XCTAssertEqual(
            SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: [" sdbprod, sps ", "SDBPROD", " rock "]),
            ["SDBPROD", "SPS", "ROCK"]
        )

        let v1 = SyncVersion(counter: 1, device: "mac-1")
        let v2 = SyncVersion(counter: 2, device: "ios-1")
        let v3 = SyncVersion(counter: 3, device: "ios-1")

        let base = SyncedMeetingContextSettings(
            scopeKey: "series:daily",
            scopeKind: .calendarSeries,
            title: SyncValue("CTO Daily", version: v1)
        )
        XCTAssertEqual(base.autoExportSettings?.overrides ?? .init(), MeetingAutoExportOverrides())

        let overrideUpdate = SyncedMeetingContextSettings(
            scopeKey: "series:daily",
            scopeKind: .calendarSeries,
            title: SyncValue("CTO Daily", version: v1),
            jiraBoardURL: SyncValue("https://jira.example.com/secure/RapidBoard.jspa?rapidView=77", version: v2),
            jiraProjectKeys: SyncValue(["SDBPROD", "SPS"], version: v2),
            autoExportSettings: SyncedMeetingAutoExportSettings(
                autoExport: SyncValue(false, version: v2),
                includeTranscript: SyncValue(true, version: v2),
                autoGenerateSummary: SyncValue(true, version: v2),
                autoSyncTasks: SyncValue(false, version: v2)
            )
        )

        let merged = base.merging(overrideUpdate)
        XCTAssertEqual(merged.jiraBoardURL?.value, "https://jira.example.com/secure/RapidBoard.jspa?rapidView=77")
        XCTAssertEqual(merged.jiraProjectKeys?.value, ["SDBPROD", "SPS"])
        XCTAssertEqual(merged.autoExportSettings?.overrides.autoExport, false)
        XCTAssertEqual(merged.autoExportSettings?.overrides.includeTranscript, true)
        XCTAssertNil(merged.autoExportSettings?.overrides.includeSummary)
        XCTAssertEqual(merged.autoExportSettings?.overrides.autoGenerateSummary, true)
        XCTAssertEqual(merged.autoExportSettings?.overrides.autoSyncTasks, false)

        // Resetting back to "Use default" (nil with higher CRDT version) propagates nil.
        let resetUpdate = SyncedMeetingContextSettings(
            scopeKey: "series:daily",
            scopeKind: .calendarSeries,
            title: SyncValue("CTO Daily", version: v1),
            jiraBoardURL: SyncValue(nil, version: v3),
            jiraProjectKeys: SyncValue(nil, version: v3),
            autoExportSettings: SyncedMeetingAutoExportSettings(
                autoExport: SyncValue(nil, version: v3),
                includeTranscript: SyncValue(nil, version: v3),
                autoGenerateSummary: SyncValue(nil, version: v3),
                autoSyncTasks: SyncValue(nil, version: v3)
            )
        )
        let afterReset = merged.merging(resetUpdate)
        XCTAssertNil(afterReset.jiraBoardURL?.value ?? nil)
        XCTAssertNil(afterReset.jiraProjectKeys?.value ?? nil)
        XCTAssertFalse(afterReset.autoExportSettings?.hasAnyExplicitOverride ?? true)
    }

    func testSyncRecordDigestIsDeterministicAcrossSetOrderingAndSidecarWritesIncrementally() throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let v1 = SyncVersion(counter: 1, device: "mac-1")
        let occA = SyncedCalendarOccurrence(
            occurrenceKey: "cal:series:1",
            seriesKey: "series",
            title: "Standup",
            calendarTitle: "Work",
            start: now,
            end: now.addingTimeInterval(1800),
            attendedDevices: ["ios-b", "mac-a", "mac-c"],
            isDeleted: SyncValue(false, version: v1),
            updatedAt: now
        )
        var occB = occA
        occB.attendedDevices = Set(["mac-c", "mac-a", "ios-b"])

        XCTAssertEqual(
            SyncRecordDigest.sha256(MeetingScheduleSyncRecord.occurrence(occA)),
            SyncRecordDigest.sha256(MeetingScheduleSyncRecord.occurrence(occB))
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sid1 = UUID()
        let sid2 = UUID()
        let chunk1 = SyncedTranscriptChunk(
            sessionID: sid1,
            deviceID: "mac",
            chunkIndex: 0,
            sessionStartedAt: now,
            events: [SyncedTranscriptEvent(id: "e1", kind: "transcript", occurredAt: now, text: "First", deviceID: "mac")],
            updatedAt: now
        )
        var chunk2 = SyncedTranscriptChunk(
            sessionID: sid2,
            deviceID: "mac",
            chunkIndex: 0,
            sessionStartedAt: now,
            events: [SyncedTranscriptEvent(id: "e2", kind: "transcript", occurredAt: now, text: "Second", deviceID: "mac")],
            updatedAt: now
        )
        var digests: [String: String] = [:]
        var chunks = [chunk1.id: chunk1, chunk2.id: chunk2]
        try WorkspaceTranscriptChunkSidecar.sync(chunks: chunks, persistedDigests: &digests, to: dir)

        let url1 = WorkspaceTranscriptChunkSidecar.fileURL(for: chunk1.id, in: dir)
        let url2 = WorkspaceTranscriptChunkSidecar.fileURL(for: chunk2.id, in: dir)
        let inode1Before = try FileManager.default.attributesOfItem(atPath: url1.path)[.systemFileNumber] as? NSNumber
        let inode2Before = try FileManager.default.attributesOfItem(atPath: url2.path)[.systemFileNumber] as? NSNumber

        // Unchanged sync must not rewrite any sidecar files.
        try WorkspaceTranscriptChunkSidecar.sync(chunks: chunks, persistedDigests: &digests, to: dir)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url1.path)[.systemFileNumber] as? NSNumber, inode1Before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url2.path)[.systemFileNumber] as? NSNumber, inode2Before)

        // Updating only chunk2 must leave chunk1 untouched on disk.
        chunk2.events.append(SyncedTranscriptEvent(id: "e3", kind: "transcript", occurredAt: now.addingTimeInterval(5), text: "Updated", deviceID: "mac"))
        chunks[chunk2.id] = chunk2
        try WorkspaceTranscriptChunkSidecar.sync(chunks: chunks, persistedDigests: &digests, to: dir)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url1.path)[.systemFileNumber] as? NSNumber, inode1Before)
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: url2.path)[.systemFileNumber] as? NSNumber, inode2Before)

        let loaded = WorkspaceTranscriptChunkSidecar.loadChunksWithDigests(from: dir)
        XCTAssertEqual(loaded.chunks, chunks)
        XCTAssertEqual(loaded.digests, digests)

        // Removing chunk1 deletes its sidecar file while preserving chunk2.
        chunks.removeValue(forKey: chunk1.id)
        try WorkspaceTranscriptChunkSidecar.sync(chunks: chunks, persistedDigests: &digests, to: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url2.path))

        var doc = MeetingWorkspaceSyncDocument(device: "mac")
        doc.restoreTranscriptChunks(loaded.chunks)
        XCTAssertEqual(doc.transcriptChunks.count, 2)
        XCTAssertTrue(doc.withoutTranscriptChunks().transcriptChunks.isEmpty)
        let record = MeetingLibrarySyncRecord.session(SyncedMeetingSession(
            id: sid1,
            occurrenceKey: "room:test",
            title: SyncValue("Test", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "room:test",
            startedAt: now,
            endedAt: SyncValue(nil, version: v1),
            timeZoneID: "UTC",
            state: SyncValue("active", version: v1),
            isDeleted: SyncValue(false, version: v1),
            createdAt: now,
            updatedAt: now
        ))
        doc.upsertSession(SyncedMeetingSession(
            id: sid1,
            occurrenceKey: "room:test",
            title: SyncValue("Test", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "room:test",
            startedAt: now,
            endedAt: SyncValue(nil, version: v1),
            timeZoneID: "UTC",
            state: SyncValue("active", version: v1),
            isDeleted: SyncValue(false, version: v1),
            createdAt: now,
            updatedAt: now
        ))
        XCTAssertTrue(doc.pendingLibraryRecords(acknowledgedDigests: [record.syncRecordID: SyncRecordDigest.sha256(record)]).isEmpty)

        // Cloud transcript upload index lives in the cursor sidecar, leaving metadata replica invariant.
        doc.markTranscriptUploaded(recordID: "transcript:\(sid1.uuidString):mac:0", sessionStartedAt: now)
        let stripped = doc.withoutSyncSidecars()
        XCTAssertTrue(stripped.transcriptChunks.isEmpty)
        XCTAssertTrue(stripped.cloudTranscriptIndex.isEmpty)

        let cursorsURL = dir.deletingLastPathComponent().appendingPathComponent("cursors.json")
        var cursorsDigest: String?
        let initialCursors = WorkspaceSyncCursorState(
            libraryToken: Data([1, 2, 3]),
            transcriptToken: Data([4, 5]),
            scheduleToken: Data([6]),
            zoneGenerations: ["library": "gen-1"],
            acknowledgedLibraryDigests: [record.syncRecordID: SyncRecordDigest.sha256(record)],
            acknowledgedTranscriptDigests: ["transcript:t1": "d1"],
            acknowledgedScheduleDigests: ["sched:s1": "d2"],
            cloudTranscriptIndex: doc.cloudTranscriptIndex
        )
        try WorkspaceSyncCursorSidecar.sync(initialCursors, persistedDigest: &cursorsDigest, to: cursorsURL)
        let cursorInode = try FileManager.default.attributesOfItem(atPath: cursorsURL.path)[.systemFileNumber] as? NSNumber

        try WorkspaceSyncCursorSidecar.sync(initialCursors, persistedDigest: &cursorsDigest, to: cursorsURL)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cursorsURL.path)[.systemFileNumber] as? NSNumber, cursorInode)

        let loadedCursors = WorkspaceSyncCursorSidecar.loadWithDigest(from: cursorsURL)
        XCTAssertEqual(loadedCursors.state, initialCursors)
        var restored = MeetingWorkspaceSyncDocument(device: "mac")
        restored.restoreCloudTranscriptIndex(loadedCursors.state?.cloudTranscriptIndex ?? [:])
        XCTAssertEqual(restored.cloudTranscriptIndex, doc.cloudTranscriptIndex)
    }
}

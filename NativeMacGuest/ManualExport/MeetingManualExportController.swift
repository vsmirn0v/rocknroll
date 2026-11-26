import AppKit
import ConferenceCore
import Foundation

@MainActor final class MeetingManualExportController: ObservableObject {
    @Published private(set) var exporting = false
    @Published private(set) var results: [MeetingManualExportFileResult]?

    private let library: MeetingLibraryController
    private let notes: MeetingNotesController
    private let flushOutcomeWrites: @MainActor () async -> Void
    private let transcriptLoader: @MainActor (MeetingLibraryCard, MeetingSessionRecord?) async -> String?
    private let snapshotSessionIDsProvider: @MainActor (UUID) -> [UUID]

    init(library: MeetingLibraryController, notes: MeetingNotesController,
         flushOutcomeWrites: @escaping @MainActor () async -> Void,
         transcriptLoader: @escaping @MainActor (MeetingLibraryCard, MeetingSessionRecord?) async -> String? = { _, _ in nil },
         snapshotSessionIDsProvider: @escaping @MainActor (UUID) -> [UUID] = { [$0] }) {
        self.library = library
        self.notes = notes
        self.flushOutcomeWrites = flushOutcomeWrites
        self.transcriptLoader = transcriptLoader
        self.snapshotSessionIDsProvider = snapshotSessionIDsProvider
    }

    func export(cards: [MeetingLibraryCard], options: MeetingManualExportOptions) async {
        guard !exporting, !cards.isEmpty else { return }
        results = nil
        exporting = true
        defer { exporting = false }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Export")
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let (items, failures) = await makeItems(cards: cards)
        let written = await Task.detached(priority: .utility) {
            MeetingManualExport.write(items: items, directory: directory, options: options)
        }.value
        results = written + failures
    }

    /// Collects all persisted components in one SQLite transaction after flushing
    /// selected documents. Edits made after that transaction remain visible as drafts.
    func makeItems(cards: [MeetingLibraryCard]) async -> ([MeetingManualExportItem], [MeetingManualExportFileResult]) {
        for card in cards { await notes.flush(sessionID: card.sessionID) }
        await flushOutcomeWrites()
        let snapshots: [ObsidianExportSnapshot]
        let snapshotError: String?
        do {
            snapshots = try await library.store.manualExportSnapshots(sessionIDs: cards.map(\.sessionID))
            snapshotError = nil
        } catch {
            snapshots = []
            snapshotError = error.localizedDescription
        }
        let snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.session.id, $0) })
        var items: [MeetingManualExportItem] = []
        var failures: [MeetingManualExportFileResult] = []
        for card in cards {
            let draft = notes.draft(sessionID: card.sessionID)
            guard let snapshot = snapshotsByID[card.sessionID] else {
                if let draft, draft.isDirty || draft.saveError != nil {
                    let session = MeetingSessionRecord(id: card.sessionID, title: card.title, startedAt: card.startedAt,
                        endedAt: card.endedAt, state: card.state, startProvenance: card.startProvenance,
                        outcomeEndFallback: card.outcomeEndFallback)
                    let transcriptBody = await transcriptLoader(card, session)
                    let snaps = await MeetingSnapshotStore.shared.snapshots(for: snapshotSessionIDsProvider(card.sessionID))
                    var urls: [UUID: URL] = [:]
                    for snap in snaps { urls[snap.id] = await MeetingSnapshotStore.shared.imageURL(for: snap) }
                    items.append(.init(session: session, note: Self.draftNote(draft.text, session: session),
                                       outcome: nil, outcomeState: card.outcomeState, isUnsavedDraft: true,
                                       transcriptBody: transcriptBody, visualSnapshots: snaps, snapshotSourceURLs: urls))
                } else {
                    let name = MeetingMarkdownTemplate.meetingFileName(title: card.title, sessionID: card.sessionID)
                    failures.append(.init(name: name, url: nil, error: snapshotError ?? L("The meeting is unavailable.")))
                }
                continue
            }
            var note = snapshot.note
            let unsaved = draft.map { $0.isDirty || $0.saveError != nil } ?? false
            if let draft, unsaved || (draft.revision ?? 0) > (note?.revision ?? 0) {
                if note == nil { note = Self.draftNote(draft.text, session: snapshot.session) }
                note?.markdown = draft.text
                if !unsaved, let revision = draft.revision { note?.revision = revision }
            }
            let transcriptBody = await transcriptLoader(card, snapshot.session)
            let snaps = await MeetingSnapshotStore.shared.snapshots(for: snapshotSessionIDsProvider(card.sessionID))
            var urls: [UUID: URL] = [:]
            for snap in snaps { urls[snap.id] = await MeetingSnapshotStore.shared.imageURL(for: snap) }
            items.append(.init(session: snapshot.session, note: note, outcome: snapshot.outcome,
                               outcomeState: snapshot.outcomeState, isUnsavedDraft: unsaved,
                               transcriptBody: transcriptBody, visualSnapshots: snaps, snapshotSourceURLs: urls))
        }
        return (items, failures)
    }

    private static func draftNote(_ markdown: String, session: MeetingSessionRecord) -> MeetingNoteRecord {
        .init(id: UUID(), sessionID: session.id, markdown: markdown, revision: 0, createdAt: Date(), updatedAt: Date())
    }
}

import ConferenceCore
import SwiftUI

/// Pure presentation model for the macOS sidebar iCloud sync status card and popover.
struct MacSyncStatusPresentation: Equatable {
    enum Tone: Equatable {
        case neutral
        case active
        case ok
        case warning

        var color: Color {
            switch self {
            case .neutral: return .secondary
            case .active: return .accentColor
            case .ok: return .teal
            case .warning: return .orange
            }
        }
    }

    struct Snapshot: Equatable {
        var enabled: Bool
        var busy: Bool
        var syncState: RoomSyncCoordinator.SyncState
        var status: String
        var storageWarning: String?
        var hasNameChoice: Bool
        var needsFreshAccount: Bool
        var includeRecent: Bool
        var syncWorkspace: Bool
        var shareCalendar: Bool
        var handoffEnabled: Bool
        var transcriptRetention: TranscriptSyncRetention
        var workspaceIsSyncing: Bool
        var workspaceSyncError: String?
        var lastLibrarySyncAt: Date?
        var nextRetryAt: Date?
    }

    let cardTitle: String
    let cardSubtitle: String
    let popoverTitle: String
    let popoverBadge: String
    let statusDetail: String
    let iconName: String
    let tone: Tone
    let showsSpinner: Bool
    let syncedItems: [String]
    let accessibilityLabel: String

    init(_ snapshot: Snapshot) {
        cardTitle = L("Meetings sync")
        popoverTitle = L("iCloud Sync for Meetings")

        let hasBlockingIssue = snapshot.needsFreshAccount
            || snapshot.storageWarning != nil
            || snapshot.hasNameChoice
            || snapshot.workspaceSyncError != nil
            || [.unavailable, .restricted, .incompatible, .failed].contains(snapshot.syncState)

        let spinning = snapshot.enabled && !hasBlockingIssue && (
            snapshot.busy
                || snapshot.workspaceIsSyncing
                || snapshot.syncState == .connecting
                || snapshot.syncState == .syncing
        )
        showsSpinner = spinning

        if snapshot.needsFreshAccount || snapshot.syncState == .accountChanged {
            iconName = "exclamationmark.icloud"
            tone = .warning
            cardSubtitle = L("Apple Account changed")
            popoverBadge = L("Action needed")
        } else if !snapshot.enabled {
            iconName = "icloud.slash"
            tone = .neutral
            cardSubtitle = L("On this Mac · Enable iCloud")
            popoverBadge = L("Off")
        } else if snapshot.storageWarning != nil {
            iconName = "exclamationmark.icloud"
            tone = .warning
            cardSubtitle = L("Save issue · Retry")
            popoverBadge = L("Action needed")
        } else if snapshot.hasNameChoice || snapshot.syncState == .nameConflict {
            iconName = "exclamationmark.icloud"
            tone = .warning
            cardSubtitle = L("Choose display name")
            popoverBadge = L("Action needed")
        } else if snapshot.syncState == .unavailable {
            iconName = "exclamationmark.icloud"
            tone = .warning
            cardSubtitle = L("iCloud unavailable")
            popoverBadge = L("Unavailable")
        } else if snapshot.syncState == .restricted {
            iconName = "exclamationmark.icloud"
            tone = .warning
            cardSubtitle = L("iCloud restricted")
            popoverBadge = L("Restricted")
        } else if snapshot.syncState == .incompatible {
            iconName = "exclamationmark.icloud"
            tone = .warning
            cardSubtitle = L("Update app to sync")
            popoverBadge = L("Update needed")
        } else if snapshot.workspaceSyncError != nil || snapshot.syncState == .failed {
            iconName = "exclamationmark.icloud"
            tone = .warning
            cardSubtitle = L("Sync issue · Retry")
            popoverBadge = L("Sync issue")
        } else if spinning {
            iconName = "arrow.triangle.2.circlepath.icloud"
            tone = .active
            cardSubtitle = L("Syncing with iCloud…")
            popoverBadge = L("Syncing…")
        } else if snapshot.syncState == .pending {
            iconName = "icloud.and.arrow.up"
            tone = .warning
            cardSubtitle = L("Changes pending")
            popoverBadge = L("Pending")
        } else {
            iconName = "checkmark.icloud"
            tone = .ok
            cardSubtitle = L("Synced with iCloud")
            popoverBadge = L("Up to date")
        }

        if !snapshot.enabled {
            if snapshot.needsFreshAccount || snapshot.status != L("Stored on this device") {
                statusDetail = snapshot.status
            } else {
                statusDetail = L("Stored on this Mac only")
            }
            syncedItems = []
        } else {
            statusDetail = snapshot.workspaceSyncError ?? snapshot.status
            var items = [L("Saved rooms & favorites")]
            if snapshot.includeRecent {
                items.append(L("Recent jams"))
            }
            if snapshot.syncWorkspace {
                items.append(L("Meeting history, summaries, notes & tasks"))
            }
            if snapshot.shareCalendar {
                items.append(L("Calendar schedule"))
            }
            if snapshot.handoffEnabled {
                items.append(L("Active meeting handoff"))
            }
            if snapshot.transcriptRetention != .off {
                items.append(L("Raw transcripts · %@", snapshot.transcriptRetention.title))
            }
            syncedItems = items
        }

        accessibilityLabel = L("%@. %@", cardTitle, cardSubtitle)
    }

    @MainActor
    init(
        sync: RoomSyncCoordinator,
        continuation: MeetingContinuationCoordinator,
        workspaceSync: MacWorkspaceSyncCoordinator
    ) {
        self.init(Snapshot(
            enabled: sync.enabled,
            busy: sync.busy,
            syncState: sync.syncState,
            status: sync.status,
            storageWarning: sync.storageWarning,
            hasNameChoice: sync.nameChoice != nil,
            needsFreshAccount: sync.needsFreshAccount,
            includeRecent: sync.includeRecent,
            syncWorkspace: sync.syncWorkspace,
            shareCalendar: sync.shareCalendar,
            handoffEnabled: continuation.enabled,
            transcriptRetention: sync.transcriptRetention,
            workspaceIsSyncing: workspaceSync.isSyncing,
            workspaceSyncError: workspaceSync.syncError,
            lastLibrarySyncAt: workspaceSync.lastLibrarySyncAt,
            nextRetryAt: workspaceSync.nextRetryAt
        ))
    }
}

/// Interactive sidebar footer card that explains meeting sync scope and opens the iCloud sync popover.
struct MacSyncStatusIndicator: View {
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var continuation: MeetingContinuationCoordinator
    @ObservedObject var workspaceSync: MacWorkspaceSyncCoordinator
    var onOpenSettings: () -> Void

    @State private var showingPopover = false
    @State private var isHovered = false

    private var presentation: MacSyncStatusPresentation {
        MacSyncStatusPresentation(sync: sync, continuation: continuation, workspaceSync: workspaceSync)
    }

    var body: some View {
        let model = presentation
        Button { showingPopover = true } label: {
            HStack(spacing: 8) {
                leadingIcon(for: model)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.cardTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(model.cardSubtitle)
                        .font(.caption2)
                        .foregroundStyle(model.tone == .warning ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(isHovered ? 0.7 : 0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.primary.opacity(isHovered ? 0.16 : 0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .popover(isPresented: $showingPopover, arrowEdge: .trailing) {
            MacSyncStatusPopover(
                sync: sync,
                continuation: continuation,
                workspaceSync: workspaceSync,
                onOpenSettings: {
                    showingPopover = false
                    onOpenSettings()
                }
            )
            .frame(width: 340)
        }
        .accessibilityIdentifier("sidebar.sync-status")
        .accessibilityLabel(model.accessibilityLabel)
        .help(L("iCloud sync for meetings, notes, tasks, and saved rooms. Click to manage."))
    }

    @ViewBuilder
    private func leadingIcon(for model: MacSyncStatusPresentation) -> some View {
        if model.showsSpinner {
            ProgressView()
                .controlSize(.mini)
        } else {
            Image(systemName: model.iconName)
                .font(.caption)
                .foregroundStyle(model.tone.color)
        }
    }
}

/// Popover showing iCloud meeting sync status, synced data categories, one-click Enable / Sync now, and Settings navigation.
struct MacSyncStatusPopover: View {
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var continuation: MeetingContinuationCoordinator
    @ObservedObject var workspaceSync: MacWorkspaceSyncCoordinator
    var onOpenSettings: () -> Void

    private var presentation: MacSyncStatusPresentation {
        MacSyncStatusPresentation(sync: sync, continuation: continuation, workspaceSync: workspaceSync)
    }

    var body: some View {
        let model = presentation
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: model.iconName)
                    .foregroundStyle(model.tone.color)
                Text(model.popoverTitle)
                    .font(.headline)
                Spacer(minLength: 8)
                statusBadge(for: model)
            }

            if !sync.enabled {
                offContent(model)
            } else {
                onContent(model)
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-popover")
    }

    private func statusBadge(for model: MacSyncStatusPresentation) -> some View {
        Text(model.popoverBadge)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(model.tone.color)
            .overlay(Capsule().stroke(model.tone.color.opacity(0.6), lineWidth: 1))
            .accessibilityAddTraits(.isStaticText)
    }

    @ViewBuilder
    private func offContent(_ model: MacSyncStatusPresentation) -> some View {
        if sync.needsFreshAccount {
            Text(sync.status)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                settingsButton(prominent: true)
            }
        } else {
            if sync.status != L("Stored on this device") {
                Text(sync.status)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("Keep your saved rooms, meeting history, summaries, notes, and tasks in sync across your Mac, iPhone, and iPad using your private iCloud storage."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Enable iCloud Sync")) {
                    sync.setEnabled(true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sync.busy)
                .accessibilityIdentifier("sync-popover.enable")
                Spacer()
                settingsButton(prominent: false)
            }
        }
    }

    @ViewBuilder
    private func onContent(_ model: MacSyncStatusPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.showsSpinner {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("Syncing with iCloud…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(model.statusDetail)
                    .font(.callout)
                    .foregroundStyle(model.tone == .warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let last = workspaceSync.lastLibrarySyncAt {
                Text(L("Last synced %@", last.formatted(.relative(presentation: .named))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let retry = workspaceSync.nextRetryAt, retry > Date(), workspaceSync.syncError != nil {
                Text(L("Next sync attempt at %@", retry.formatted(date: .omitted, time: .shortened)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warning = sync.storageWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Retry saving sync changes")) { sync.retryLocalSave() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let choice = sync.nameChoice {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Your devices have different saved names. Choose the name to use for future joins."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(L("Use this device’s name: %@", choice.local)) {
                            sync.chooseName(useCloud: false)
                        }
                        .controlSize(.small)
                        Button(L("Use iCloud name: %@", choice.cloud.isEmpty ? L("No saved name") : choice.cloud)) {
                            sync.chooseName(useCloud: true)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 5) {
            Text(L("Synced data"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.syncedItems, id: \.self) { item in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.teal)
                    Text(item)
                        .font(.caption)
                }
            }
        }

        Divider()

        HStack {
            Button(L("Sync now")) {
                sync.requestSync(immediate: true)
                workspaceSync.scheduleSync(delayMilliseconds: 0)
            }
            .buttonStyle(.bordered)
            .disabled(sync.busy || workspaceSync.isSyncing)
            .accessibilityIdentifier("sync-popover.sync-now")
            Spacer()
            settingsButton(prominent: false)
        }
    }

    @ViewBuilder
    private func settingsButton(prominent: Bool) -> some View {
        if prominent {
            Button(L("Sync settings…")) { onOpenSettings() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("sync-popover.settings")
        } else {
            Button(L("Sync settings…")) { onOpenSettings() }
                .accessibilityIdentifier("sync-popover.settings")
        }
    }
}

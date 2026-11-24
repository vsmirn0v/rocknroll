import ConferenceCore
import SwiftUI
import UIKit

struct IOSAssistantModePill: View {
    let mode: IOSMeetingAssistantMode
    let isPaused: Bool
    let alertCount: Int
    var facilitatorSkillName: String? = nil
    var action: () -> Void

    private var hasFacilitatorOnly: Bool {
        mode == .off && facilitatorSkillName != nil
    }

    private var effectiveSymbol: String {
        hasFacilitatorOnly ? "waveform" : mode.symbol
    }

    private var effectiveTitle: String {
        if isPaused { return L("Paused") }
        if hasFacilitatorOnly, let facilitatorSkillName { return facilitatorSkillName }
        return mode.shortTitle
    }

    private var effectiveAccessibilityLabel: String {
        var parts: [String] = []
        if hasFacilitatorOnly, let facilitatorSkillName {
            parts.append(L("Voice facilitator: %@", facilitatorSkillName))
        } else {
            parts.append(L("Assistant mode: %@", mode.title))
            if let facilitatorSkillName {
                parts.append(L("Voice facilitator: %@", facilitatorSkillName))
            }
        }
        if isPaused { parts.append(L("Paused")) }
        if alertCount > 0 { parts.append(L("Unread alerts: %ld", alertCount)) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: effectiveSymbol)
                    .font(.caption.weight(.semibold))
                Text(effectiveTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if alertCount > 0 {
                    Text("\(alertCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(pillBackground, in: Capsule())
            .foregroundStyle(pillForeground)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(effectiveAccessibilityLabel)
    }

    private var pillBackground: Color {
        if isPaused { return .orange.opacity(0.16) }
        if hasFacilitatorOnly { return .teal.opacity(0.16) }
        switch mode {
        case .off: return Color.secondary.opacity(0.12)
        case .mentions: return Color.blue.opacity(0.14)
        case .follow: return Color.indigo.opacity(0.14)
        case .participating: return Color.green.opacity(0.16)
        }
    }

    private var pillForeground: Color {
        if isPaused { return .orange }
        if hasFacilitatorOnly { return .teal }
        switch mode {
        case .off: return .secondary
        case .mentions: return .blue
        case .follow: return .indigo
        case .participating: return .green
        }
    }
}

struct IOSAssistantAlertCardView: View {
    let card: IOSAssistantAlertCard
    @ObservedObject var assistant: IOSAssistantCoordinator
    var showMeetingTitle: Bool = true
    var canSendChat: Bool = true
    var onFocusMeeting: (() -> Void)? = nil

    @State private var draftReply: String
    @State private var isWorking = false
    @State private var actionError: String?

    init(
        card: IOSAssistantAlertCard,
        assistant: IOSAssistantCoordinator,
        showMeetingTitle: Bool = true,
        canSendChat: Bool = true,
        onFocusMeeting: (() -> Void)? = nil
    ) {
        self.card = card
        self.assistant = assistant
        self.showMeetingTitle = showMeetingTitle
        self.canSendChat = canSendChat
        self.onFocusMeeting = onFocusMeeting
        _draftReply = State(initialValue: card.suggestedReply)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: card.urgency == .now ? "bell.badge.fill" : card.mode.symbol)
                    .foregroundStyle(card.urgency == .now ? .orange : .accentColor)
                if showMeetingTitle {
                    Text(card.meetingTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Text(card.urgency == .now ? L("Needs you now") : L("Heads up"))
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                Text(card.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(card.reason)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if !card.excerpt.isEmpty {
                Text("“\(card.excerpt)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let deliveryNote = card.deliveryNote, !deliveryNote.isEmpty {
                Label(deliveryNote, systemImage: card.deliveryFailed ? "exclamationmark.triangle" : "checkmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(card.deliveryFailed ? Color.orange : .green)
            }

            if card.mode == .participating || !draftReply.isEmpty {
                TextField(L("Draft reply…"), text: $draftReply, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .lineLimit(1...4)
                    .onChange(of: draftReply) { _, newValue in
                        assistant.updateCardDraft(card.id, text: newValue)
                    }
            }

            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                let cleanReply = draftReply.trimmingCharacters(in: .whitespacesAndNewlines)
                if canSendChat && !cleanReply.isEmpty {
                    Button {
                        perform {
                            assistant.updateCardDraft(card.id, text: cleanReply)
                            try await assistant.sendCardToChat(card.id)
                        }
                    } label: {
                        Label(L("Send chat"), systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isWorking)
                }

                if !cleanReply.isEmpty {
                    Button {
                        perform {
                            assistant.updateCardDraft(card.id, text: cleanReply)
                            try await assistant.speakCardReply(card.id)
                        }
                    } label: {
                        Label(L("Speak"), systemImage: "waveform")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                }

                if let onFocusMeeting {
                    Button(L("Open meeting"), action: onFocusMeeting)
                        .buttonStyle(.bordered)
                }

                Spacer()

                Button {
                    assistant.dismissCard(card.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 36, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(L("Dismiss alert"))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        isWorking = true
        actionError = nil
        Task {
            do {
                try await work()
            } catch {
                actionError = error.localizedDescription
            }
            isWorking = false
        }
    }
}

struct IOSAssistantModeSheet: View {
    let controllerID: UUID
    let meetingTitle: String
    let canSendChat: Bool
    @ObservedObject var assistant: IOSAssistantCoordinator
    var speech: IOSAssistantSpeechCoordinator? = nil
    var skills: IOSAssistantSkillsController? = nil
    var facilitator: IOSAutonomousMeetingFacilitator? = nil
    var board: IOSAssistantBoardController? = nil
    var onFocusMeeting: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var rememberForRoom = false
    @State private var output: IOSParticipationOutput
    @State private var askBeforeSending: Bool
    @State private var goalDraft: String
    @State private var dictatingGoal = false
    @State private var updatingGoalFromSpeech = false
    @State private var showingBoardSheet = false

    init(
        controllerID: UUID,
        meetingTitle: String,
        canSendChat: Bool,
        assistant: IOSAssistantCoordinator,
        speech: IOSAssistantSpeechCoordinator? = nil,
        skills: IOSAssistantSkillsController? = nil,
        facilitator: IOSAutonomousMeetingFacilitator? = nil,
        board: IOSAssistantBoardController? = nil,
        onFocusMeeting: (() -> Void)? = nil
    ) {
        self.controllerID = controllerID
        self.meetingTitle = meetingTitle
        self.canSendChat = canSendChat
        self.assistant = assistant
        self.speech = speech
        self.skills = skills
        self.facilitator = facilitator
        self.board = board
        self.onFocusMeeting = onFocusMeeting
        _output = State(initialValue: assistant.effectiveParticipationOutput(for: controllerID))
        _askBeforeSending = State(initialValue: assistant.effectiveAskBeforeSending(for: controllerID))
        _goalDraft = State(initialValue: assistant.effectiveParticipationGoal(for: controllerID))
    }

    private var activeMode: IOSMeetingAssistantMode {
        assistant.resolvedMode(for: controllerID)
    }

    private var sessionCards: [IOSAssistantAlertCard] {
        assistant.alertCards.filter { $0.controllerID == controllerID && !$0.dismissed }
    }

    private var sessionActivity: [IOSAssistantActivityItem] {
        assistant.activityLog.filter { $0.controllerID == controllerID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(IOSMeetingAssistantMode.allCases) { mode in
                        Button {
                            assistant.setMode(mode, for: controllerID, rememberForRoom: rememberForRoom)
                            if mode == .participating {
                                maybeAutoStartGoalDictation()
                            } else {
                                stopGoalDictation(commit: false)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: mode.symbol)
                                    .font(.title3)
                                    .foregroundStyle(activeMode == mode ? Color.accentColor : .secondary)
                                    .frame(width: 28, alignment: .center)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mode.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(mode.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if activeMode == mode {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(activeMode == mode ? [.isSelected] : [])
                    }

                    Toggle(L("Remember mode for this room"), isOn: $rememberForRoom)
                        .onChange(of: rememberForRoom) { _, newValue in
                            if newValue {
                                assistant.setMode(activeMode, for: controllerID, rememberForRoom: true)
                            }
                        }
                } header: {
                    Text(meetingTitle)
                } footer: {
                    if activeMode != .off, let error = assistant.evaluationErrors[controllerID] {
                        Text(error).foregroundStyle(.red)
                    }
                    if let status = assistant.lastStatusNoteBySession[controllerID] {
                        Text(status)
                    }
                    if activeMode != .off && !assistant.hasModelConfigured() {
                        Text(L("Local mention detection is active. Configure Apple Intelligence or an AI API key in Settings → Assistant & Sync for deeper context follow-up."))
                    }
                }

                if activeMode == .participating {
                    Section(L("Participation Settings")) {
                        Picker(L("Reply channel"), selection: $output) {
                            ForEach(IOSParticipationOutput.allCases) { ch in
                                Label(ch.title, systemImage: ch.symbol).tag(ch)
                            }
                        }
                        .onChange(of: output) { _, _ in syncParticipationOptions() }

                        Toggle(L("Ask before replying"), isOn: $askBeforeSending)
                            .onChange(of: askBeforeSending) { _, _ in syncParticipationOptions() }

                        HStack(alignment: .top, spacing: 8) {
                            TextField(L("Goal for assistant (optional)"), text: goalTextBinding, axis: .vertical)
                                .lineLimit(2...4)
                                .accessibilityIdentifier("assistant.mode.goal")
                            if speech != nil {
                                Button {
                                    dictatingGoal ? stopGoalDictation(commit: true) : startGoalDictation()
                                } label: {
                                    Image(systemName: dictatingGoal ? "stop.circle.fill" : "mic.fill")
                                        .font(.title3)
                                        .foregroundStyle(dictatingGoal ? Color.red : Color.accentColor)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("assistant.mode.dictate")
                                .accessibilityLabel(dictatingGoal ? L("Stop dictation") : L("Speak context"))
                            }
                        }
                        if let speech {
                            IOSAssistantDictationFeedbackRow(speech: speech, dictatingGoal: $dictatingGoal)
                        }

                        if !canSendChat && (output == .chat || output == .voiceAndChat) {
                            Text(L("Meeting chat is currently unavailable; voice replies will be used or drafted."))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Button {
                            Task { await assistant.evaluateNow(controllerID: controllerID) }
                        } label: {
                            HStack {
                                Label(L("Check conversation now"), systemImage: "sparkles")
                                if assistant.evaluatingSessions.contains(controllerID) {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(assistant.evaluatingSessions.contains(controllerID))
                    }
                }

                if let skills, let facilitator {
                    IOSFacilitatorModeSection(
                        controllerID: controllerID,
                        meetingTitle: meetingTitle,
                        skills: skills,
                        facilitator: facilitator,
                        board: board,
                        onOpenBoard: { showingBoardSheet = true }
                    )
                }

                if !sessionCards.isEmpty {
                    Section(L("Alerts & Suggested Replies")) {
                        ForEach(sessionCards) { card in
                            IOSAssistantAlertCardView(
                                card: card,
                                assistant: assistant,
                                showMeetingTitle: false,
                                canSendChat: canSendChat,
                                onFocusMeeting: onFocusMeeting.map { fn in
                                    {
                                        dismiss()
                                        fn()
                                    }
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowBackground(Color.clear)
                        }
                    }
                }

                if !sessionActivity.isEmpty {
                    Section(L("Recent Activity")) {
                        ForEach(sessionActivity.prefix(8)) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.mode.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    if let channel = item.deliveredChannel {
                                        Text("· \(channel)")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.green)
                                    }
                                    Spacer()
                                    Text(item.at, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.summary)
                                    .font(.subheadline)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle(L("Assistant Mode"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) {
                        stopGoalDictation(commit: true)
                        syncParticipationOptions()
                        dismiss()
                    }
                }
            }
            .onAppear { maybeAutoStartGoalDictation() }
            .onDisappear {
                stopGoalDictation(commit: false)
                board?.isInlineSheetActive = false
            }
            .onChange(of: showingBoardSheet) { _, isShowing in
                board?.isInlineSheetActive = isShowing
            }
            .sheet(isPresented: $showingBoardSheet) {
                if let board {
                    IOSAssistantBoardSheet(
                        controller: board,
                        defaultBoardURL: board.defaultBoardURLForTarget?(controllerID)
                            ?? board.defaultBoardURLProvider?()
                            ?? skills?.teamContext.defaultJiraBoardURL
                            ?? ""
                    )
                }
            }
        }
    }

    private var goalTextBinding: Binding<String> {
        Binding(
            get: { goalDraft },
            set: { newValue in
                if dictatingGoal && !updatingGoalFromSpeech {
                    stopGoalDictation(commit: false)
                }
                goalDraft = newValue
                syncParticipationOptions()
            }
        )
    }

    private func maybeAutoStartGoalDictation() {
        guard activeMode == .participating,
              goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !dictatingGoal else { return }
        startGoalDictation()
    }

    private func startGoalDictation() {
        guard let speech else { return }
        dictatingGoal = true
        speech.startDictation(
            onPartial: { partial in
                updatingGoalFromSpeech = true
                goalDraft = partial
                updatingGoalFromSpeech = false
                syncParticipationOptions()
            },
            onFinal: { finalText in
                updatingGoalFromSpeech = true
                let clean = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    goalDraft = clean
                    syncParticipationOptions()
                }
                updatingGoalFromSpeech = false
                dictatingGoal = false
            }
        )
        if speech.mode != .dictating {
            dictatingGoal = false
        }
    }

    private func stopGoalDictation(commit: Bool) {
        guard dictatingGoal else { return }
        dictatingGoal = false
        speech?.stopDictation(commit: commit)
    }

    private func syncParticipationOptions() {
        assistant.setParticipationOptions(
            for: controllerID,
            askBeforeSending: askBeforeSending,
            output: output,
            goal: goalDraft
        )
    }
}

private struct IOSAssistantDictationFeedbackRow: View {
    @ObservedObject var speech: IOSAssistantSpeechCoordinator
    @Binding var dictatingGoal: Bool

    var body: some View {
        Group {
            if dictatingGoal {
                Label(
                    speech.livePartialText.isEmpty ? L("Listening — speak your meeting context…") : speech.livePartialText,
                    systemImage: "waveform"
                )
                .font(.caption)
                .foregroundStyle(.teal)
            } else if speech.permissionDenied {
                HStack(spacing: 8) {
                    Text(L("Allow Microphone and Speech Recognition in Settings to dictate."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(L("Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption)
                }
            } else if let blocked = speech.blockedMessage {
                Text(blocked)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onChange(of: speech.mode) { _, mode in
            if dictatingGoal && mode != .dictating {
                dictatingGoal = false
            }
        }
        .onChange(of: speech.permissionDenied) { _, denied in
            if denied && dictatingGoal {
                dictatingGoal = false
            }
        }
    }
}

struct IOSActiveMeetingAssistantPill: View {
    let controllerID: UUID
    @ObservedObject var assistant: IOSAssistantCoordinator
    var facilitator: IOSAutonomousMeetingFacilitator? = nil
    var skills: IOSAssistantSkillsController? = nil
    var action: () -> Void

    var body: some View {
        let mode = assistant.resolvedMode(for: controllerID)
        let isPaused = assistant.isPausedForMicrophone(controllerID: controllerID)
        let alerts = assistant.alertCards.filter { $0.controllerID == controllerID && !$0.dismissed }.count
        if let facilitator {
            IOSFacilitatorAwareModePill(
                controllerID: controllerID,
                mode: mode,
                isPaused: isPaused,
                alertCount: alerts,
                facilitator: facilitator,
                skills: skills,
                action: action
            )
        } else {
            IOSAssistantModePill(
                mode: mode,
                isPaused: isPaused,
                alertCount: alerts,
                action: action
            )
        }
    }
}

private struct IOSFacilitatorAwareModePill: View {
    let controllerID: UUID
    let mode: IOSMeetingAssistantMode
    let isPaused: Bool
    let alertCount: Int
    @ObservedObject var facilitator: IOSAutonomousMeetingFacilitator
    var skills: IOSAssistantSkillsController?
    let action: () -> Void

    private var skillName: String? {
        guard let slug = facilitator.activeSessionSkills[controllerID] else { return nil }
        return skills?.skills.first(where: { $0.id == slug })?.name ?? slug
    }

    var body: some View {
        IOSAssistantModePill(
            mode: mode,
            isPaused: isPaused,
            alertCount: alertCount,
            facilitatorSkillName: skillName,
            action: action
        )
    }
}

struct IOSAssistantAlertsHomeSection: View {
    @ObservedObject var assistant: IOSAssistantCoordinator
    var canSendChat: (UUID) -> Bool
    var onFocusMeeting: (UUID) -> Void

    var body: some View {
        let cards = assistant.alertCards.filter { !$0.dismissed }
        if !cards.isEmpty {
            Section(L("Assistant Alerts")) {
                ForEach(cards) { card in
                    IOSAssistantAlertCardView(
                        card: card,
                        assistant: assistant,
                        showMeetingTitle: true,
                        canSendChat: canSendChat(card.controllerID),
                        onFocusMeeting: { onFocusMeeting(card.controllerID) }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                }
            }
            .accessibilityIdentifier("home.assistant-alerts")
        }
    }
}

private struct IOSFacilitatorModeSection: View {
    let controllerID: UUID
    let meetingTitle: String
    @ObservedObject var skills: IOSAssistantSkillsController
    @ObservedObject var facilitator: IOSAutonomousMeetingFacilitator
    var board: IOSAssistantBoardController?
    let onOpenBoard: () -> Void

    var body: some View {
        let activeSkillID = facilitator.activeSessionSkills[controllerID]
        let isActive = activeSkillID != nil

        Section(L("Autonomous Voice Facilitator")) {
            Toggle(L("Voice facilitator in this meeting"), isOn: Binding(
                get: { isActive },
                set: { enabled in
                    if enabled {
                        facilitator.enable(controllerID: controllerID, title: meetingTitle, skillID: nil)
                    } else {
                        facilitator.disable(controllerID: controllerID)
                    }
                }
            ))

            if isActive {
                Picker(L("Skill Role"), selection: Binding(
                    get: { activeSkillID ?? skills.selectedSkillIDs.first ?? "scrum-master" },
                    set: { chosen in
                        facilitator.enable(controllerID: controllerID, title: meetingTitle, skillID: chosen)
                    }
                )) {
                    ForEach(skills.skills.filter(\.enabled)) { skill in
                        Text(skill.name).tag(skill.id)
                    }
                }

                Button {
                    Task {
                        await facilitator.kickOffSkill(controllerID: controllerID, title: meetingTitle, skillID: activeSkillID)
                    }
                } label: {
                    Label(L("Kick off role in call"), systemImage: "waveform")
                }
            }

            if let board {
                IOSFacilitatorBoardControls(
                    controllerID: controllerID,
                    board: board,
                    onOpenBoard: onOpenBoard
                )
            }

            if let note = facilitator.lastStatusBySession[controllerID] {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct IOSFacilitatorBoardControls: View {
    let controllerID: UUID
    @ObservedObject var board: IOSAssistantBoardController
    let onOpenBoard: () -> Void
    @State private var shareError: String?

    var body: some View {
        Button {
            onOpenBoard()
        } label: {
            Label(L("Open Assistant Board"), systemImage: "macwindow")
        }

        if board.isSharing || board.isRecoveringShare {
            Button(role: .destructive) {
                shareError = nil
                board.stopSharing()
            } label: {
                Label(
                    board.isRecoveringShare ? L("Stop Board Reconnect") : L("Stop Sharing Board"),
                    systemImage: "display.trianglebadge.exclamationmark"
                )
            }
        } else if board.canShareToActiveMeeting {
            Button {
                shareError = nil
                Task {
                    do {
                        let resolvedURL = board.defaultBoardURLForTarget?(controllerID)
                            ?? board.defaultBoardURLProvider?()
                        _ = try await board.startSharing(
                            targetID: controllerID,
                            urlOverride: (board.currentURL == nil && !(resolvedURL ?? "").isEmpty) ? resolvedURL : nil
                        )
                    } catch {
                        shareError = error.localizedDescription
                    }
                }
            } label: {
                Label(
                    board.isStartingShare ? L("Starting Share…") : L("Share Desktop Board"),
                    systemImage: "display"
                )
            }
            .disabled(board.isStartingShare)
        }

        if let shareError {
            Text(shareError)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

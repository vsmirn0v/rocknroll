import AVFoundation
import Combine
import ConferenceCore
import CoreMedia
import LiveKit
import LiveKitWebRTC
import MeetingEngine
import SwiftUI
import UIKit

/// Manages one live `MeetingSession` across any provider (`.guest`, `.community`,
/// `.telemost`, `.trueconf`), sharing workspace-wide CallKit/AVAudioSession ownership
/// through `IOSWorkspaceAudioCoordinator` and gating remote video decode to foreground visibility.
@MainActor
final class IOSMeetingSessionController: ObservableObject, CallEngine, Identifiable, IOSBoardShareSession {
    let id: UUID
    let destination: JoinDestination
    let session: MeetingSession
    let chat: ChatStore
    let catchUp: CatchUpStore
    let reactions = MeetingReactionsModel(preferences: .standard)
    let studio: StudioModel
    let localTranscriber: IOSMeetingTranscriber

    var invitationURL: URL { destination.invitationURL }
    var kind: MeetingEngineKind { destination.engineKind }

    var onEvent: ((CallEvent) -> Void)?
    var onMediaStatus: ((String?) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onMinimize: (() -> Void)?
    var onSelectMeeting: ((UUID) -> Void)?
    var onTalkHere: ((UUID) -> Void)?
    var onLeaveMeeting: ((UUID) -> Void)?
    var onJoinAnotherMeeting: (() -> Void)?
    var onOpenAssistant: (() -> Void)?
    var onMicrophoneStateChanged: ((UUID, Bool) -> Void)?
    var onMeetingSoundChanged: ((UUID) -> Void)?
    var canStartBroadcast: (() -> Bool)?
    var onBroadcastOwnershipChanged: ((Bool) -> Void)?
    var voiceReplyTargetsProvider: (() -> [VoiceReplyTargetRoom])?
    var onSpeakVoiceReplyInRoom: ((UUID, String) async throws -> Void)?
    var onCancelVoiceReplyInRoom: ((UUID) -> Void)?
    var workspaceSessionID: UUID?
    var workspaceDeviceID = ""
    var onOpenNotes: (() -> Void)?
    var onOpenBoard: (() -> Void)?
    var onOpenAsk: (() -> Void)?
    var onExternalBoardShareStopped: (() -> Void)?
    var onBoardShareInterrupted: (() -> Void)?
    var canShareBoard: Bool { !leaving && phase == .connected && !isHeld && !quiet }
    var isBoardShareSessionAlive: Bool { !leaving && phase != .idle && phase != .failed && !isHeld && !quiet }
    var onWorkspaceEventsChanged: ((UUID, [SyncedTranscriptEvent], [DateInterval], Set<String>) -> Void)?

    @Published private(set) var callView: RockCallViewController?
    @Published private(set) var title: String
    @Published private(set) var phase: NativeDesktopMeetingPhase = .idle
    private(set) var lastConnectFailure: Error?
    @Published private(set) var isForegroundVisible = false
    private var lastAssistantBadge: (mode: IOSMeetingAssistantMode, isPaused: Bool, alertCount: Int, facilitatorSkillName: String?) = (.off, false, 0, nil)
    private weak var presentedBoardController: UIViewController?
    @Published private(set) var isTalkRoom = false
    @Published private(set) var isHeld = false
    @Published private(set) var isMeetingSoundEnabled = true
    private var requestedMeetingSound: Bool?
    var canSetMeetingSound: Bool {
        phase == .connected && !leaving && !isHeld && requestedMeetingSound == nil
    }
    var isMeetingSoundAudible: Bool {
        isMeetingSoundEnabled && requestedMeetingSound != false && meetingVolume > 0 && !isHeld && !quiet
    }
    @Published private(set) var isMicrophoneOn = false
    @Published private(set) var isCameraOn = false
    @Published private(set) var isSharingScreen = false
    @Published private(set) var isSpeakingVoiceReply = false
    @Published private(set) var meetingVolume: Double
    @Published private(set) var participantVolumes: [String: Double] = [:]
    var supportsParticipantVolume: Bool { session.supportsParticipantVolume }
    private let volumePreferences: UserDefaults
    private let meetingVolumeKey: String
    private let invitationCopiedOnJoin: Bool
    @Published private(set) var lastDemand: MeetingEngine.MeetingVideoDemand?

    var callWorkspacePublisher: AnyPublisher<CallWorkspaceControls?, Never> {
        $callView.map { $0?.workspace }.eraseToAnyPublisher()
    }
    var activityMicrophonePublisher: AnyPublisher<PiPMicrophoneStatus, Never> {
        studio.microphoneActivity.$status.eraseToAnyPublisher()
    }
    var hasJoinStarted: Bool { joinStarted }
    var isConnectingInFlight: Bool {
        phase == .connecting || phase == .lobby || (connectTask != nil && !terminalDelivered)
    }
    var continuationHostView: UIView? { callView?.viewIfLoaded }
    var reminderHost: MeetingReminderHost? { callView?.reminderHost }
    var currentAudioState: (microphoneOn: Bool, playoutOn: Bool) { session.appliedAudioState }

    private weak var workspaceAudio: IOSWorkspaceAudioCoordinator?
    private(set) var displayName = ""
    private var quiet = false
    private var joinStarted = false
    private var leaving = false
    private var terminalDelivered = false
    private var everConnected = false
    private var displayMode: ConferenceDisplayMode = .all
    private var localCameraTrack: LKRTCVideoTrack?
    private var cachedLiveCaptureDevice: AVCaptureDevice?
    private var compositeSources: [String: CompositeVideoSource] = [:]
    private var receivedReactionIDs: Set<UUID> = []
    private var screenShare: IOSScreenShareCapture?
    private var connectTask: Task<Void, Never>?
    private var broadcastObservation: AnyCancellable?
    private var audioSubscriptions: Set<AnyCancellable> = []
    private let videoDemand = MeetingVideoDemand()
    private var requestedMicrophone: Bool?
    private var microphoneTask: Task<Void, Never>?
    private var requestedCamera: Bool?
    private var cameraTask: Task<Void, Never>?
    private var lastLoggedPhase: NativeDesktopMeetingPhase?
    private var lastLoggedVideoCount = -1
    private var appLifecycleObservers: [NSObjectProtocol] = []
    private var backgroundRecoveryTask: UIBackgroundTaskIdentifier = .invalid
    private var privateCheckAudioSink: ((AVAudioPCMBuffer) -> Void)?
    let assistantSpeechLedger = AssistantSpeechLedger()
    private var assistantTranscriptSegments: [TranscriptSegment] = []
    private var providerTranscriptSegments: [TranscriptSegment] = []
    private var providerCanViewTranscript: Bool?
    private var providerTranscriptActive = false
    private var providerCanManageTranscript = false
    private var didAutoStartLocalTranscription = false
    private var assistantTranscriptionConsumers: Set<String> = []
    private var voiceReplyTask: Task<Void, Error>? {
        didSet {
            voiceReplyLock.lock()
            voiceReplyInFlightFlag = (voiceReplyTask != nil)
            voiceReplyLock.unlock()
        }
    }
    private final class VoiceReplyEchoGate: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = false
        private var suppressUntilUptime: TimeInterval = -.infinity

        func begin() {
            lock.lock()
            inFlight = true
            suppressUntilUptime = .infinity
            lock.unlock()
        }

        func end(tailSeconds: TimeInterval = 1.8) {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            inFlight = false
            suppressUntilUptime = now + max(0, tailSeconds)
            lock.unlock()
        }

        var isSuppressing: Bool {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let active = inFlight || now < suppressUntilUptime
            lock.unlock()
            return active
        }
    }

    private final class SpeechActivityTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var lastLocalSpeechUptime: TimeInterval = -.infinity
        private var bargeInStartUptime: TimeInterval?
        private var lastBargeInTriggerUptime: TimeInterval = -.infinity
        private var speakerOutput = true

        func setSpeakerOutput(_ enabled: Bool) {
            lock.lock()
            speakerOutput = enabled
            lock.unlock()
        }

        func secondsSinceLocalSpeech(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
            lock.lock()
            let last = lastLocalSpeechUptime
            lock.unlock()
            return last.isFinite ? max(0, now - last) : .infinity
        }

        /// Evaluates mic buffer RMS off MainActor. Returns `true` when sustained local speech should barge in.
        func observeLocalBuffer(_ buffer: AVAudioPCMBuffer, isEchoSuppressing: Bool, isVoiceReplyInFlight: Bool) -> Bool {
            let rms = Self.fastRMS(of: buffer)
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            defer { lock.unlock() }
            if !isEchoSuppressing && rms >= 0.015 {
                lastLocalSpeechUptime = now
            }
            guard isVoiceReplyInFlight else {
                bargeInStartUptime = nil
                return false
            }
            let threshold: Float = speakerOutput ? 0.085 : 0.035
            if rms >= threshold {
                if bargeInStartUptime == nil {
                    bargeInStartUptime = now
                }
                if let start = bargeInStartUptime,
                   now - start >= 0.28,
                   now - lastBargeInTriggerUptime >= 0.8 {
                    lastBargeInTriggerUptime = now
                    bargeInStartUptime = nil
                    lastLocalSpeechUptime = now
                    return true
                }
            } else {
                bargeInStartUptime = nil
            }
            return false
        }

        private static func fastRMS(of buffer: AVAudioPCMBuffer) -> Float {
            let count = Int(buffer.frameLength)
            guard count > 0 else { return 0 }
            let step = max(1, count >= 128 ? 4 : 1)
            var sumSq: Float = 0
            var samples = 0
            if let floatData = buffer.floatChannelData?[0] {
                var i = 0
                while i < count {
                    let s = floatData[i]
                    sumSq += s * s
                    samples += 1
                    i += step
                }
            } else if let int16Data = buffer.int16ChannelData?[0] {
                let norm: Float = 1.0 / 32768.0
                var i = 0
                while i < count {
                    let s = Float(int16Data[i]) * norm
                    sumSq += s * s
                    samples += 1
                    i += step
                }
            }
            guard samples > 0 else { return 0 }
            return sqrt(sumSq / Float(samples))
        }
    }

    private let voiceReplyLock = NSLock()
    private let voiceReplyEchoGate = VoiceReplyEchoGate()
    private let speechActivityTracker = SpeechActivityTracker()
    nonisolated(unsafe) private var voiceReplyInFlightFlag = false
    private var lastRemoteSpeechUptime: TimeInterval = -.infinity
    private var remoteBargeInTask: Task<Void, Never>?
    var onVoiceReplyBargeIn: (() -> Void)?
    var isVoiceReplyInFlight: Bool { voiceReplyTask != nil }
    var isConnectedForAssistant: Bool { !leaving && phase == .connected }
    nonisolated func isVoiceReplyInFlightThreadSafe() -> Bool {
        voiceReplyLock.lock()
        defer { voiceReplyLock.unlock() }
        return voiceReplyInFlightFlag || voiceReplyEchoGate.isSuppressing
    }
    var isHumanSpeakingNow: Bool {
        guard !leaving, phase == .connected else { return false }
        if session.sessionSnapshot.participants.contains(where: { !$0.isLocal && $0.speaking == true }) {
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        if (now - lastRemoteSpeechUptime) < 0.85 {
            return true
        }
        if isLocalMicrophoneUnmuted && speechActivityTracker.secondsSinceLocalSpeech(now: now) < 0.85 {
            return true
        }
        if !localTranscriber.partialSegmentIDs.isEmpty {
            return true
        }
        return false
    }
    private var assistantHUDContext: (talk: IOSAssistantTalkController, speech: IOSAssistantSpeechCoordinator)?
    private var micActiveStart: Date?
    private var micActiveIntervals: [DateInterval] = []

    init(destination: JoinDestination,
         session: MeetingSession,
         chat: ChatStore,
         catchUp: CatchUpStore,
         workspaceAudio: IOSWorkspaceAudioCoordinator,
         initialTitle: String?,
         preferences: UserDefaults = .standard,
         invitationCopiedOnJoin: Bool = false) {
        self.id = session.id
        self.destination = destination
        self.session = session
        self.chat = chat
        self.catchUp = catchUp
        self.workspaceAudio = workspaceAudio
        self.invitationCopiedOnJoin = invitationCopiedOnJoin
        volumePreferences = preferences
        meetingVolumeKey = "ios.meetingVolume." + destination.engineKind.rawValue
        let savedVolume = preferences.object(forKey: meetingVolumeKey) as? Double ?? 1
        meetingVolume = Self.clampedGain(savedVolume, maximum: 1)
        let cleanTitle = initialTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (cleanTitle?.isEmpty == false ? cleanTitle! : nil)
            ?? L("Jam %@", destination.roomIdentifier)
        if UserDefaults.standard.object(forKey: GuestAudioProfile.preferenceKey) != nil {
            let syncedProfile = GuestAudioProfile.saved == .music ? "music" : "conversation"
            UserDefaults.standard.set(syncedProfile, forKey: "studio.audio-profile")
        }
        weak var weakSelf: IOSMeetingSessionController?
        let privateMicrophone = SessionPrivateMicrophoneCapture(
            startSessionCheck: { onBuffer in
                guard let controller = weakSelf, controller.phase == .connected else { return false }
                controller.setPrivateCheckAudioSink(onBuffer)
                do {
                    try await controller.session.startPrivateAudioCheck()
                    return true
                } catch is CancellationError {
                    controller.setPrivateCheckAudioSink(nil)
                    throw CancellationError()
                } catch {
                    controller.setPrivateCheckAudioSink(nil)
                    return false
                }
            },
            stopSessionCheck: {
                guard let controller = weakSelf else { return }
                controller.setPrivateCheckAudioSink(nil)
                try? await controller.session.stopPrivateAudioCheck()
            }
        )
        self.studio = StudioModel(
            audioControl: .fullProcessing,
            preferences: .standard,
            privateMicrophone: privateMicrophone
        )
        self.localTranscriber = IOSMeetingTranscriber(
            modelStore: .shared,
            localDisplayName: { weakSelf?.displayName ?? "" },
            participantNameLookup: { participantID in
                weakSelf?.session.sessionSnapshot.participants.first(where: { $0.id == participantID })?.name
            },
            setOutputDemand: { keep in
                await weakSelf?.session.setTranscriptionOutput(keep) ?? !keep
            }
        )
        self.screenShare = IOSScreenShareCapture(
            session: session,
            preview: LocalSharePreview()
        )
        weakSelf = self
        if let initialShare = self.screenShare {
            bindScreenShareCallbacks(initialShare)
        }
        localTranscriber.onSegmentsChanged = { [weak self] _ in
            self?.syncCatchUpTranscript()
        }
        configureStudio()
        videoDemand.onChange = { [weak self] in self?.updateVideoDemand() }
        observeWorkspaceAudio(workspaceAudio)
        observeSession()
        observeLifecycle()
    }

    deinit {
        appLifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        let sessionID = id
        let recoveryTask = backgroundRecoveryTask
        Task { @MainActor in
            if recoveryTask != .invalid { UIApplication.shared.endBackgroundTask(recoveryTask) }
            IOSCameraCapture.removeObserver(id: sessionID)
        }
    }

    func prepareCallView() -> RockCallViewController {
        if let callView { return callView }
        let view = RockCallViewController(
            title: title,
            catchUp: catchUp,
            chat: chat,
            invitationURL: destination.invitationURL,
            roomIdentifier: destination.roomIdentifier,
            invitationCopiedOnJoin: invitationCopiedOnJoin
        )
        view.reactions = reactions
        view.supportsChat = session.capabilities.supportsChatRead || session.capabilities.supportsChatSend
        view.supportsSharing = true
        view.usesNativeShareControl = IOSNativeScreenCaptureAvailability.isAvailable
        view.sharingAvailable = false
        view.studio = studio
        view.workspaceSessionIDProvider = { [weak self] in self?.workspaceSessionID ?? self?.id ?? UUID() }
        view.transcriptExcerptProvider = { [weak self] in self?.latestTranscriptExcerpt() ?? "" }
        view.onMinimize = { [weak self] in self?.onMinimize?() }
        view.onSelectMeeting = { [weak self] id in self?.onSelectMeeting?(id) }
        view.onTalkHere = { [weak self] id in self?.onTalkHere?(id) }
        view.onLeaveMeeting = { [weak self] id in self?.onLeaveMeeting?(id) }
        view.onJoinAnotherMeeting = { [weak self] in self?.onJoinAnotherMeeting?() }
        view.onOpenAssistant = { [weak self] in self?.onOpenAssistant?() }
        if let hud = assistantHUDContext {
            view.attachAssistantVoiceHUD(talk: hud.talk, speech: hud.speech) { [weak self] in
                if let onOpenAsk = self?.onOpenAsk {
                    onOpenAsk()
                } else {
                    self?.onOpenAssistant?()
                }
            }
        }
        view.onLeave = { [weak self] in self?.leave() }
        view.workspace.setMeetingSound = { [weak self] enabled in self?.setMeetingSoundEnabled(enabled) }
        view.workspace.setMeetingVolume = { [weak self] level in self?.setMeetingVolume(level) }
        $meetingVolume.assign(to: &view.workspace.$meetingVolume)
        if supportsParticipantVolume {
            view.participantVolumeControls = ParticipantVolumeControls(
                level: { [weak self] id in self?.participantVolume(id) ?? 1 },
                setLevel: { [weak self] level, id in self?.setParticipantVolume(level, participantID: id) }
            )
        }
        view.onMicrophone = { [weak self] enabled in self?.setMicrophone(enabled) }
        view.onToggleMicrophone = { [weak self] in self?.toggleMicrophone() }
        view.onCamera = { [weak self] enabled in self?.setCamera(enabled) }
        view.onToggleCamera = { [weak self] in self?.toggleCamera() }
        view.onShare = { [weak self] enabled in self?.setScreenSharing(enabled) }
        view.onSpeaker = { [weak self] enabled in
            guard let self, !self.leaving else { return }
            Task { @MainActor [weak self] in
                do {
                    try await self?.workspaceAudio?.audio.selectBuiltInOutput(speaker: enabled)
                } catch is CancellationError {
                } catch {
                    self?.reportMediaStatus(error.localizedDescription)
                }
            }
        }
        view.onChooseAudioOutput = { [weak self] in
            self?.workspaceAudio?.audio.userWillSelectOutput()
        }
        view.onDisplayMode = { [weak self] mode in
            guard let self else { return }
            self.displayMode = mode
            self.updateVideoDemand()
        }
        view.onVideoDemandChanged = { [weak self] in self?.updateVideoDemand() }
        view.onFloatingChanged = { [weak self] active in
            self?.videoDemand.setFloating(active)
            self?.updateVideoDemand()
        }
        view.onFloatingRecoveryDemandChanged = { [weak self] needed in
            self?.videoDemand.setFloatingRecovery(needed)
        }
        view.loadViewIfNeeded()
        view.setStagePhase(phase, lobbyMessage: phase == .lobby ? session.sessionSnapshot.lastError : nil)
        view.setConnectionRecovering(isRecoveringConnection)
        view.setMeetingSound(enabled: isMeetingSoundEnabled, available: canSetMeetingSound)
        view.updateAssistantBadge(
            mode: lastAssistantBadge.mode,
            isPaused: lastAssistantBadge.isPaused,
            alertCount: lastAssistantBadge.alertCount,
            facilitatorSkillName: lastAssistantBadge.facilitatorSkillName
        )
        if let output = workspaceAudio?.audio.output { view.setAudioOutput(output) }
        view.workspace.openVoiceReply = { [weak self] in self?.presentVoiceReplySheet() }
        view.workspace.openTranscriptionSettings = { [weak self] in self?.presentTranscriptionSettingsSheet() }
        view.workspace.openNotes = { [weak self] in self?.onOpenNotes?() }
        view.workspace.openBoard = { [weak self] in self?.onOpenBoard?() }
        view.setHeld(quiet || isHeld)
        view.setMicrophone(false)
        view.setCamera(false)
        view.setSharing(false)

        if let screenShare {
            let rewired = IOSScreenShareCapture(session: session, preview: view.sharePreview)
            bindScreenShareCallbacks(rewired)
            screenShare.onSharingChanged = nil
            screenShare.onExternalEnd = nil
            screenShare.onError = nil
            self.screenShare = rewired
        }

        callView = view
        return view
    }

    private func bindScreenShareCallbacks(_ capture: IOSScreenShareCapture) {
        capture.onSharingChanged = { [weak self] sharing in
            guard let self else { return }
            let wasSharing = self.isSharingScreen
            self.isSharingScreen = sharing
            self.callView?.setSharing(sharing)
            self.renderSnapshot()
            if wasSharing, !sharing,
               self.phase != .connected,
               self.isBoardShareSessionAlive,
               self.onBoardShareInterrupted != nil {
                self.notifyBoardShareInterrupted()
            }
        }
        capture.onEndMessage = { [weak self] message in
            if let message { self?.reportMediaStatus(message) }
        }
        capture.onExternalEnd = { [weak self] in
            guard let self else { return }
            self.studio.presenter.sharingEnded()
            if self.phase != .connected,
               self.isBoardShareSessionAlive,
               self.screenShare?.isBroadcastSharing != true,
               self.onBoardShareInterrupted != nil {
                self.notifyBoardShareInterrupted()
            } else {
                self.notifyExternalBoardShareStopped()
            }
        }
        capture.onError = { [weak self] error in
            guard let self else { return }
            self.reportMediaStatus(error.localizedDescription)
            if self.isBoardShareSessionAlive,
               self.screenShare?.isBroadcastSharing != true,
               self.onBoardShareInterrupted != nil {
                self.notifyBoardShareInterrupted()
            }
        }
    }

    func start(displayName: String, quiet: Bool, backgroundJoin: Bool = false) {
        guard !joinStarted, !leaving else { return }
        self.displayName = displayName
        self.quiet = quiet
        isMeetingSoundEnabled = !quiet
        lastConnectFailure = nil
        joinStarted = true

        _ = prepareCallView()
        catchUp.enter(roomKey: destination.invitationURL.absoluteString)
        providerTranscriptSegments = []
        assistantTranscriptSegments = []
        providerCanViewTranscript = nil
        providerTranscriptActive = false
        providerCanManageTranscript = false
        didAutoStartLocalTranscription = false
        catchUp.observe(messages: [], canView: true, enabled: false)
        catchUp.canManageTranscript = false
        catchUp.transcriptUnavailableReason = nil
        chat.clear()
        chat.reactionHistory.beginMeeting(id: id)
        bindChatCallbacks()
        bindReactionsCallbacks()
        bindTranscriptCallbacks()
        updateSwitcherItems(items: callView?.activeMeetingsForSwitcher ?? [])

        workspaceAudio?.registerSession(session, title: title, backgroundJoin: backgroundJoin,
                                        soundEnabled: !quiet, hasAudibleVolume: meetingVolume > 0)
        isTalkRoom = workspaceAudio?.isTalkSession(id) ?? true
        updateBroadcastObservation()
        videoDemand.beginJoin(inBackground: backgroundJoin)
        AppDiagnostics.log("meeting-start", ["provider": kind.rawValue, "quiet": quiet, "background": backgroundJoin])

        let url = destination.invitationURL
        phase = .connecting
        connectTask = Task { @MainActor [weak self] in
            guard let self, !self.leaving else { return }
            defer { self.connectTask = nil }
            do {
                if let workspaceAudio = self.workspaceAudio {
                    try await workspaceAudio.waitUntilAudioReady(for: self.id)
                }
                guard !self.leaving, !Task.isCancelled else { return }
                await self.session.setPlayoutVolume(self.meetingVolume)
                guard !self.leaving, !Task.isCancelled else { return }
                try await self.session.connect(invitation: url, name: displayName, quiet: quiet)
            } catch is CancellationError {
                return
            } catch {
                guard !self.leaving else { return }
                self.lastConnectFailure = error
                self.reportMediaStatus(error.localizedDescription)
                await self.finish(event: .failed)
            }
        }
    }

    private static func clampedGain(_ value: Double, maximum: Double) -> Double {
        value.isFinite ? min(maximum, max(0, value)) : 1
    }

    func setMeetingVolume(_ value: Double, persist: Bool = true) {
        guard !leaving else { return }
        let volume = Self.clampedGain(value, maximum: 1)
        if volume != meetingVolume {
            meetingVolume = volume
            workspaceAudio?.setHasAudibleVolume(volume > 0, for: id)
            if volume == 0 { cancelVoiceReply() }
            Task { @MainActor [weak self] in
                guard let self, !leaving, meetingVolume == volume else { return }
                await session.setPlayoutVolume(volume)
            }
        }
        if persist { volumePreferences.set(volume, forKey: meetingVolumeKey) }
    }

    func participantVolume(_ participantID: String) -> Double {
        participantVolumes[participantID] ?? 1
    }

    func setParticipantVolume(_ value: Double, participantID: String) {
        guard !leaving, supportsParticipantVolume,
              session.sessionSnapshot.participants.contains(where: { $0.id == participantID && !$0.isLocal }) else { return }
        let volume = Self.clampedGain(value, maximum: 2)
        guard volume != participantVolume(participantID) else { return }
        participantVolumes[participantID] = volume == 1 ? nil : volume
        Task { @MainActor [weak self] in
            guard let self, !leaving, participantVolume(participantID) == volume else { return }
            await session.setParticipantVolume(volume, participantID: participantID)
        }
    }

    func present(in container: UIViewController, animated: Bool = false) {
        let view = prepareCallView()
        setForegroundVisible(true)
        guard container.view.window != nil else { return }
        if view.presentingViewController === container { return }
        if let activeModal = container.presentedViewController, activeModal !== view {
            activeModal.dismiss(animated: false) { [weak view, weak container] in
                guard let view, let container, container.view.window != nil else { return }
                if view.presentingViewController === container { return }
                if view.presentingViewController != nil {
                    view.dismiss(animated: false) {
                        if view.presentingViewController == nil {
                            container.present(view, animated: animated)
                        }
                    }
                } else {
                    container.present(view, animated: animated)
                }
            }
            return
        }
        if view.presentingViewController != nil {
            view.dismiss(animated: false) {
                if view.presentingViewController == nil {
                    container.present(view, animated: animated)
                }
            }
            return
        }
        container.present(view, animated: animated)
    }

    func dismissFromPresentation(animated: Bool = false, completion: (() -> Void)? = nil) {
        setForegroundVisible(false)
        guard let view = callView, view.presentingViewController != nil else {
            completion?()
            return
        }
        view.dismiss(animated: animated, completion: completion)
    }

    func setForegroundVisible(_ visible: Bool) {
        guard isForegroundVisible != visible else { return }
        isForegroundVisible = visible
        updateBroadcastObservation()
        updateVideoDemand()
        refreshCameraReactionStatus()
    }

    func updateSwitcherItems(items: [RockCallViewController.SwitcherItem]) {
        callView?.activeMeetingsForSwitcher = items
        callView?.isTalkRoom = isTalkRoom
    }

    func setSystemHeld(_ held: Bool) {
        isHeld = held
        refreshMeetingSoundControl()
        studio.held = held || quiet
        callView?.setHeld(held || quiet)
        callView?.sharingAvailable = phase == .connected && !held && !quiet
        callView?.setSpeakerReceptionAvailable(!held && !quiet)
        if held {
            catchUp.begin(.anotherCall)
            Task { [weak self] in await self?.stopScreenSharing(retirePresenter: true) }
        } else {
            catchUp.end(.anotherCall)
        }
        updateMicrophoneIndicator()
        updateVideoDemand()
        refreshCameraReactionStatus()
    }

    func setRoomTitle(_ newTitle: String) {
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        title = clean
        callView?.setRoomTitle(clean)
        workspaceAudio?.updateSessionTitle(id: id, title: clean)
        onTitleChanged?(clean)
    }

    func setMeetingSoundEnabled(_ enabled: Bool) {
        guard canSetMeetingSound, enabled != isMeetingSoundEnabled, let workspaceAudio else { return }
        requestedMeetingSound = enabled
        if !enabled { cancelVoiceReply() }
        refreshMeetingSoundControl()
        Task { @MainActor [weak self] in
            guard let self, !leaving else { return }
            defer {
                requestedMeetingSound = nil
                refreshMeetingSoundControl()
            }
            do {
                try await workspaceAudio.setMeetingSoundEnabled(enabled, for: id)
                guard !leaving else { return }
                isMeetingSoundEnabled = enabled
                if enabled && quiet {
                    quiet = false
                    setSystemHeld(isHeld)
                }
                onMeetingSoundChanged?(id)
            } catch is CancellationError {
            } catch {
                reportMediaStatus(error.localizedDescription)
            }
        }
    }

    private func refreshMeetingSoundControl() {
        callView?.setMeetingSound(enabled: isMeetingSoundEnabled, available: canSetMeetingSound)
    }

    private var hasPendingUnmutedReconnectIntent: Bool {
        isTalkRoom && isRecoveringConnection && session.sessionSnapshot.intent.microphoneOn && !(workspaceAudio?.isMuted ?? true) && !isHeld && !quiet
    }

    func toggleMicrophone() {
        let activeOrPending = requestedMicrophone ?? (isMicrophoneOn || hasPendingUnmutedReconnectIntent)
        setMicrophone(!activeOrPending)
    }

    func setMicrophone(_ enabled: Bool) {
        guard !leaving else {
            requestedMicrophone = nil
            callView?.setMicrophone(false)
            return
        }
        guard phase == .connected else {
            requestedMicrophone = nil
            if !enabled {
                workspaceAudio?.suppressMicrophoneImmediately(for: id)
                updateMicrophoneIndicator()
                renderSnapshot()
                if microphoneTask == nil {
                    microphoneTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { self.microphoneTask = nil }
                        guard !self.leaving else { return }
                        try? await self.workspaceAudio?.setTalkMicrophone(false, for: self.id)
                        self.updateMicrophoneIndicator()
                        self.renderSnapshot()
                    }
                }
            } else {
                callView?.setMicrophone(false)
            }
            return
        }
        requestedMicrophone = enabled
        if !enabled {
            workspaceAudio?.suppressMicrophoneImmediately(for: id)
            updateMicrophoneIndicator()
        }
        guard microphoneTask == nil else { return }
        microphoneTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.microphoneTask = nil }
            var cancelledAfterUnmuteWithPendingMute = false
            while !self.leaving, self.phase == .connected, let desired = self.requestedMicrophone {
                if self.requestedMicrophone == desired {
                    self.requestedMicrophone = nil
                }
                if !desired, cancelledAfterUnmuteWithPendingMute,
                   !self.session.appliedAudioState.microphoneOn,
                   !self.session.sessionSnapshot.effective.microphoneOn {
                    cancelledAfterUnmuteWithPendingMute = false
                    self.updateMicrophoneIndicator()
                    self.renderSnapshot()
                    continue
                }
                cancelledAfterUnmuteWithPendingMute = false
                guard let workspaceAudio = self.workspaceAudio else { break }
                do {
                    try await workspaceAudio.setTalkMicrophone(desired, for: self.id)
                    self.isTalkRoom = workspaceAudio.isTalkSession(self.id)
                    self.callView?.isTalkRoom = self.isTalkRoom
                    self.updateMicrophoneIndicator()
                    self.renderSnapshot()
                } catch is CancellationError {
                    cancelledAfterUnmuteWithPendingMute = desired && (self.requestedMicrophone == false)
                    self.updateMicrophoneIndicator()
                } catch {
                    AppDiagnostics.log("meeting-mic-error", ["provider": self.kind.rawValue, "desired": desired])
                    self.updateMicrophoneIndicator()
                    if self.requestedMicrophone == nil {
                        self.reportMediaStatus(error.localizedDescription)
                        break
                    }
                }
            }
        }
    }

    func toggleCamera() {
        setCamera(!(requestedCamera ?? isCameraOn))
    }

    func setCamera(_ enabled: Bool) {
        guard !leaving, phase == .connected else {
            requestedCamera = nil
            callView?.setCamera(false)
            return
        }
        requestedCamera = enabled
        guard cameraTask == nil else { return }
        cameraTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.cameraTask = nil }
            while !self.leaving, self.phase == .connected, let desired = self.requestedCamera {
                if self.requestedCamera == desired {
                    self.requestedCamera = nil
                }
                do {
                    try await self.session.setCamera(desired)
                    self.renderSnapshot()
                } catch is CancellationError {
                    continue
                } catch {
                    if self.requestedCamera == nil {
                        self.callView?.setCamera(self.session.appliedMediaIntent.cameraOn)
                        self.reportMediaStatus(error.localizedDescription)
                        break
                    }
                }
            }
        }
    }

    func setScreenSharing(_ enabled: Bool, broadcast: Bool = false) {
        guard !leaving else { return }
        if !enabled {
            Task { @MainActor [weak self] in await self?.stopScreenSharing(retirePresenter: true) }
            return
        }
        guard phase == .connected, !isHeld, !quiet else {
            if broadcast, canStartBroadcast?() ?? isForegroundVisible {
                BroadcastManager.shared.requestStop()
            }
            callView?.setSharing(false)
            return
        }
        notifyExternalBoardShareStopped()
        Task { @MainActor [weak self] in
            guard let self, let screenShare = self.screenShare else { return }
            do {
                if broadcast {
                    guard self.canStartBroadcast?() ?? self.isForegroundVisible else { return }
                    self.onBroadcastOwnershipChanged?(true)
                    try await screenShare.start(broadcast: true)
                } else if IOSNativeScreenCaptureAvailability.isAvailable {
                    try await screenShare.start(broadcast: false)
                } else if BroadcastManager.shared.isBroadcasting, self.canStartBroadcast?() ?? self.isForegroundVisible {
                    self.onBroadcastOwnershipChanged?(true)
                    try await screenShare.start(broadcast: true)
                } else {
                    BroadcastManager.shared.requestActivation()
                }
            } catch is CancellationError {
                return
            } catch {
                self.onBroadcastOwnershipChanged?(false)
                self.callView?.setSharing(false)
                self.reportMediaStatus(error.localizedDescription)
            }
        }
    }

    func startBoardSharing(initialSample: CMSampleBuffer) async throws {
        guard canShareBoard else {
            throw MeetingSessionError.unavailable(L("Connect to the meeting before sharing the board."))
        }
        notifyExternalBoardShareStopped()
        await stopScreenSharing(retirePresenter: true)
        guard canShareBoard, let screenShare else {
            throw MeetingSessionError.unavailable(L("Screen sharing is unavailable in this call state."))
        }
        let codec = "h264"
        let profile = GuestVideoProfile(width: 1920, height: 1080, fps: 15, maximumBitrate: 1_500_000)
        AppDiagnostics.log("board-share-start", [
            "provider": kind.rawValue,
            "codec": codec,
            "width": Int(profile.width),
            "height": Int(profile.height),
            "fps": Int(profile.fps)
        ])
        do {
            try await screenShare.startComposed(initialSample: initialSample, profile: profile, codec: codec)
            AppDiagnostics.log("board-share-ready", [
                "provider": kind.rawValue,
                "codec": codec
            ])
        } catch {
            let ns = error as NSError
            AppDiagnostics.log("board-share-error", [
                "provider": kind.rawValue,
                "codec": codec,
                "errorType": String(describing: type(of: error)),
                "errorDomain": ns.domain,
                "errorCode": ns.code,
                "cancelled": error is CancellationError
            ])
            throw error
        }
    }

    func pushBoardShareFrame(_ sample: CMSampleBuffer) {
        guard canShareBoard else { return }
        screenShare?.sendComposed(sample)
    }

    func stopBoardSharing() async {
        onBoardShareInterrupted = nil
        onExternalBoardShareStopped = nil
        AppDiagnostics.log("board-share-stop", [
            "provider": kind.rawValue,
            "reason": "controllerStop"
        ])
        await stopScreenSharing(retirePresenter: false)
    }

    private func notifyBoardShareInterrupted() {
        onExternalBoardShareStopped = nil
        let callback = onBoardShareInterrupted
        onBoardShareInterrupted = nil
        if callback != nil {
            AppDiagnostics.log("board-share-interrupted", [
                "provider": kind.rawValue,
                "phase": String(describing: phase)
            ])
        }
        callback?()
    }

    private func notifyExternalBoardShareStopped() {
        onBoardShareInterrupted = nil
        let callback = onExternalBoardShareStopped
        onExternalBoardShareStopped = nil
        if callback != nil {
            AppDiagnostics.log("board-share-stop", [
                "provider": kind.rawValue,
                "reason": "externalStop"
            ])
        }
        callback?()
    }

    private func stopScreenSharing(retirePresenter: Bool) async {
        notifyExternalBoardShareStopped()
        let wasBroadcast = screenShare?.isBroadcastSharing == true
        if retirePresenter { studio.presenter.sharingEnded() }
        await screenShare?.stop()
        if wasBroadcast { onBroadcastOwnershipChanged?(false) }
        callView?.setSharing(false)
        renderSnapshot()
        if retirePresenter { await studio.presenter.waitForScreenStop() }
    }

    func updateVideoDemand(appActive: Bool? = nil) {
        let active = appActive ?? (videoDemand.foreground || UIApplication.shared.applicationState != .background)
        let pipPresenting = callView?.isFloatingVideoPresenting == true
        let foreground = !leaving && isForegroundVisible && active
        let wantsVideo = !leaving && isForegroundVisible && (pipPresenting || (appActive == nil && videoDemand.wantsVideo))
        let demand: MeetingEngine.MeetingVideoDemand
        if (foreground || wantsVideo) && !isHeld && displayMode != .audioOnly, let callView {
            demand = callView.videoSubscriptionDemand(foreground: foreground, wantsVideo: wantsVideo)
        } else {
            if let callView {
                _ = callView.visibleVideoQualities(foreground: false, wantsVideo: false)
            }
            demand = MeetingEngine.MeetingVideoDemand(
                visibleParticipantIDs: [],
                focusedParticipantID: nil,
                preferredScreenParticipantID: nil,
                receivesCameras: false
            )
        }
        if lastDemand != demand {
            lastDemand = demand
            Task { [weak self] in try? await self?.session.setVideoDemand(demand) }
        }
    }

    // MARK: - CallEngine

    func leave() {
        guard !leaving else { return }
        leaving = true
        cancelVoiceReply(forBargeIn: false)
        let event: CallEvent = everConnected || joinStarted ? .left : .canceled
        Task { @MainActor [weak self] in
            await self?.finish(event: event)
        }
    }

    func resumeSystemCallIfPossible() {
        workspaceAudio?.resumeSystemCallIfPossible()
    }

    func prepareToFloat() {
        callView?.prepareToFloat()
    }

    func restoreFromFloatingVideo() {
        callView?.restoreFromFloatingVideo()
        setForegroundVisible(true)
    }

    func showMediaStatus(_ message: String?) {
        callView?.showMediaStatus(message)
        onMediaStatus?(message)
    }

    func setTransferHeld(_ held: Bool, restoreSending: Bool) async throws {
        _ = restoreSending
        if let workspaceAudio {
            try await workspaceAudio.setTransferHeld(held)
        }
    }

    // MARK: - Private wiring

    private func observeSession() {
        session.onTitle = { [weak self] newTitle in
            self?.setRoomTitle(newTitle)
        }
        session.onSessionSnapshot = { [weak self] snapshot in
            self?.applySessionSnapshot(snapshot)
        }
        session.onVideo = { [weak self] _ in
            self?.renderSnapshot()
        }
        session.onLocalCamera = { [weak self] track in
            guard let self else { return }
            self.localCameraTrack = track
            self.studio.observeLiveCamera(track.map(ObjectIdentifier.init))
            self.renderSnapshot()
            self.refreshCameraReactionStatus()
            if track != nil {
                Task { @MainActor [weak self] in
                    self?.cachedLiveCaptureDevice = await self?.session.cameraCaptureDevice()
                }
            } else {
                self.cachedLiveCaptureDevice = nil
            }
        }
        session.onFeatures = { [weak self] features in
            self?.applyFeaturesSnapshot(features)
        }
        session.onCapturedMessages = { [weak self] messages, isTranscript in
            guard !isTranscript else { return }
            self?.applyCapturedChatMessages(messages)
        }
        session.onFeatureError = { [weak self] error in
            self?.reportMediaStatus(error.localizedDescription)
        }
        session.setTranscriptionAudioHandler { [weak self] sources in
            self?.localTranscriber.updateRemoteSources(sources)
        }
    }

    private func observeWorkspaceAudio(_ workspaceAudio: IOSWorkspaceAudioCoordinator) {
        workspaceAudio.$talkSessionID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] talkID in
                guard let self else { return }
                let talk = talkID == self.id
                self.isTalkRoom = talk
                self.callView?.isTalkRoom = talk
                self.updateMicrophoneIndicator()
                self.renderSnapshot()
            }
            .store(in: &audioSubscriptions)

        workspaceAudio.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMicrophoneIndicator()
                self?.renderSnapshot()
            }
            .store(in: &audioSubscriptions)

        workspaceAudio.$audioOutput
            .receive(on: DispatchQueue.main)
            .sink { [weak self] output in
                self?.callView?.setAudioOutput(output)
                self?.speechActivityTracker.setSpeakerOutput(output.builtInSpeaker == true)
            }
            .store(in: &audioSubscriptions)
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification] {
            appLifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateBackgroundRecoveryTask()
                    self?.updateVideoDemand()
                    self?.refreshCameraReactionStatus()
                }
            })
        }
    }

    private var isRecoveringConnection: Bool {
        phase == .reconnecting || (phase == .connecting && everConnected)
    }

    private func updateBackgroundRecoveryTask() {
        guard !leaving, everConnected, isRecoveringConnection,
              UIApplication.shared.applicationState == .background else {
            endBackgroundRecoveryTask()
            return
        }
        guard backgroundRecoveryTask == .invalid else { return }
        backgroundRecoveryTask = UIApplication.shared.beginBackgroundTask(withName: "Reconnect meeting audio") { [weak self] in
            self?.endBackgroundRecoveryTask()
            AppDiagnostics.log("meeting-background-recovery-expired")
        }
        AppDiagnostics.log("meeting-background-recovery", ["granted": backgroundRecoveryTask != .invalid])
    }

    private func endBackgroundRecoveryTask() {
        guard backgroundRecoveryTask != .invalid else { return }
        let task = backgroundRecoveryTask
        backgroundRecoveryTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private func updateBroadcastObservation() {
        guard broadcastObservation == nil else { return }
        broadcastObservation = BroadcastManager.shared.isBroadcastingPublisher
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self, !self.leaving else { return }
                if active {
                    guard self.joinStarted, self.phase == .connected, !self.isHeld, !self.quiet,
                          self.isForegroundVisible, self.canStartBroadcast?() ?? true else { return }
                    if self.screenShare?.isBroadcastSharing != true {
                        self.setScreenSharing(true, broadcast: true)
                    }
                } else if self.screenShare?.isBroadcastSharing == true {
                    self.setScreenSharing(false, broadcast: true)
                }
            }
    }

    private func applySessionSnapshot(_ snapshot: MeetingSessionSnapshot) {
        guard !leaving else { return }
        let previous = phase
        if !(snapshot.phase == .idle && joinStarted) && !(snapshot.phase == .failed && connectTask != nil) {
            phase = snapshot.phase
        }
        refreshMeetingSoundControl()

        callView?.supportsChat = snapshot.capabilities.supportsChatRead || snapshot.capabilities.supportsChatSend
        isCameraOn = snapshot.effective.cameraOn
        callView?.setCamera(snapshot.effective.cameraOn)
        if snapshot.phase == .connected,
           isTalkRoom,
           !(workspaceAudio?.isMuted ?? true),
           requestedMicrophone == nil,
           microphoneTask == nil,
           !snapshot.intent.microphoneOn,
           !snapshot.effective.microphoneOn {
            workspaceAudio?.suppressMicrophoneImmediately(for: id)
        }
        updateMicrophoneIndicator(snapshot: snapshot)

        let remoteSpeaking = snapshot.participants.contains { !$0.isLocal && $0.speaking == true }
        if remoteSpeaking {
            lastRemoteSpeechUptime = ProcessInfo.processInfo.systemUptime
            if isSpeakingVoiceReply && remoteBargeInTask == nil {
                remoteBargeInTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(280))
                    guard let self, !Task.isCancelled, !self.leaving, self.isSpeakingVoiceReply else { return }
                    let stillSpeaking = self.session.sessionSnapshot.participants.contains { !$0.isLocal && $0.speaking == true }
                    if stillSpeaking {
                        self.handleVoiceReplyBargeIn(source: "remoteSpeaker")
                    }
                }
            }
        } else {
            remoteBargeInTask?.cancel()
            remoteBargeInTask = nil
        }

        if snapshot.phase != .connected {
            requestedMicrophone = nil
            requestedCamera = nil
        }
        if lastLoggedPhase != phase {
            lastLoggedPhase = phase
            AppDiagnostics.log("meeting-phase", [
                "provider": kind.rawValue,
                "phase": phase.rawValue,
                "participants": snapshot.participants.count
            ])
        }
        if previous != phase { updateBackgroundRecoveryTask() }
        callView?.setStagePhase(phase, lobbyMessage: phase == .lobby ? snapshot.lastError : nil)
        callView?.setConnectionRecovering(isRecoveringConnection)

        if let error = snapshot.lastError {
            reportMediaStatus(error)
        } else if snapshot.phase == .connected {
            callView?.showMediaStatus(nil)
        }

        switch snapshot.phase {
        case .idle:
            break
        case .connecting:
            callView?.sharingAvailable = false
            if isRecoveringConnection { callView?.showMediaStatus(L("Restoring meeting media…")) }
            if previous != .connecting { onEvent?(.connecting) }
        case .lobby:
            callView?.sharingAvailable = false
            callView?.showMediaStatus(snapshot.lastError ?? L("Waiting for the host to admit you…"))
            onEvent?(.lobby)
        case .connected:
            everConnected = true
            callView?.sharingAvailable = !isHeld && !quiet
            studio.presenter.supportsVP9 = snapshot.capabilities.supportsScreenShareVP9
            workspaceAudio?.markSessionConnected(id: id)
            if previous == .reconnecting {
                chat.reactionHistory.endGap()
            }
            if previous != .connected {
                catchUp.end(.connection)
                onEvent?(.active)
                if studio.hasSelection {
                    let guestProfile: GuestAudioProfile = studio.profile == .music ? .music : .speech
                    Task { @MainActor [weak self] in
                        try? await self?.session.setAudioProfile(guestProfile)
                    }
                }
                if BroadcastManager.shared.isBroadcasting, screenShare?.isSharing != true,
                   !isHeld, !quiet, isForegroundVisible, canStartBroadcast?() ?? true {
                    setScreenSharing(true, broadcast: true)
                }
                if IOSListenModelStore.shared.autoStartLocalTranscription && !didAutoStartLocalTranscription {
                    didAutoStartLocalTranscription = true
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.phase == .connected,
                              !self.leaving,
                              !(self.providerTranscriptActive && self.providerCanViewTranscript == true) else { return }
                        _ = await self.localTranscriber.start()
                        self.refreshLocalAudioSink()
                        self.syncCatchUpTranscript()
                    }
                }
                syncCatchUpTranscript()
            }
        case .reconnecting:
            callView?.sharingAvailable = false
            callView?.showMediaStatus(L("Restoring meeting media…"))
            if previous != .reconnecting {
                if everConnected { catchUp.begin(.connection) }
                chat.reactionHistory.beginGap()
            }
            onEvent?(.connecting)
        case .leaving:
            break
        case .left:
            let event: CallEvent = snapshot.endedByOrganizer ? .evicted : .left
            Task { @MainActor [weak self] in await self?.finish(event: event) }
            return
        case .failed:
            Task { @MainActor [weak self] in await self?.finish(event: .failed) }
            return
        }

        renderSnapshot(using: snapshot)
        refreshCameraReactionStatus()
    }

    private func applyFeaturesSnapshot(_ features: GuestMeetingSnapshot) {
        guard !leaving else { return }
        chat.reactionHistoryAvailable = features.permissions.canSendReaction || session.capabilities.supportsReactions
        let managesStore = session.chatService?.managesChatStoreSendCallbacks ?? false
        if !managesStore {
            chat.canSend = features.permissions.canSendChat && features.connected
            chat.unavailableReason = features.permissions.canViewChat
                ? nil
                : (session.chatService?.unavailableReason ?? L("Chat is unavailable in this meeting."))
            if !features.messages.isEmpty || chat.items.isEmpty {
                chat.replace(features.messages.map(Self.chatEntry(from:)))
                emitWorkspaceEvents()
            }
        }

        if session.capabilities.supportsProviderTranscript {
            var segments: [TranscriptSegment] = []
            segments.reserveCapacity(features.transcript.count)
            for msg in features.transcript {
                let rawText = String(msg.text.prefix(4_096))
                let occurredAt = msg.sentAt ?? msg.receivedAt
                func appendAssistantIfMissing(_ assistantText: String, segmentID: String) {
                    let cleanAssistant = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanAssistant.isEmpty else { return }
                    let alreadyRecorded = assistantTranscriptSegments.contains { existing in
                        guard let existingAt = existing.spokenAt, let msgAt = occurredAt else {
                            return existing.text == cleanAssistant
                        }
                        return abs(existingAt.timeIntervalSince(msgAt)) <= 25.0 &&
                            AssistantWakePhraseMatcher.isLikelySelfEcho(
                                candidate: rawText,
                                lastSpoken: existing.text,
                                isLocal: true,
                                withinEchoWindow: true
                            )
                    }
                    guard !alreadyRecorded else { return }
                    segments.append(TranscriptSegment(
                        id: segmentID,
                        speaker: AssistantSpeechLedger.canonicalSpeakerName,
                        text: cleanAssistant,
                        spokenAt: occurredAt,
                        isOwn: false,
                        speakerRole: AssistantSpeechLedger.speakerRoleAssistant
                    ))
                }
                if msg.isOwn {
                    switch assistantSpeechLedger.classifyOwnServerSegment(text: rawText, occurredAt: occurredAt) {
                    case .pureUser(let cleanUser):
                        segments.append(TranscriptSegment(
                            id: msg.id,
                            speaker: msg.participantName,
                            text: cleanUser,
                            spokenAt: occurredAt,
                            isOwn: true,
                            speakerRole: AssistantSpeechLedger.speakerRoleUser
                        ))
                    case .mixed(let cleanUser, let assistantText):
                        segments.append(TranscriptSegment(
                            id: msg.id,
                            speaker: msg.participantName,
                            text: cleanUser,
                            spokenAt: occurredAt,
                            isOwn: true,
                            speakerRole: AssistantSpeechLedger.speakerRoleUser
                        ))
                        appendAssistantIfMissing(assistantText, segmentID: msg.id + ":assistant")
                    case .pureAssistant(let assistantText):
                        appendAssistantIfMissing(assistantText, segmentID: msg.id)
                    }
                } else {
                    segments.append(TranscriptSegment(
                        id: msg.id,
                        speaker: msg.participantName,
                        text: rawText,
                        spokenAt: occurredAt,
                        isOwn: false,
                        speakerRole: AssistantSpeechLedger.speakerRoleParticipant
                    ))
                }
            }
            let wasServerVisible = providerTranscriptActive && (providerCanViewTranscript == true)
            providerTranscriptSegments = segments
            providerCanViewTranscript = features.permissions.canViewTranscript
            providerTranscriptActive = (features.transcriptionStatus == .active)
            providerCanManageTranscript = features.permissions.canManageTranscript && features.connected
            let isServerVisible = providerTranscriptActive && (providerCanViewTranscript == true)
            syncCatchUpTranscript()
            if wasServerVisible != isServerVisible {
                Task { @MainActor [weak self] in
                    await self?.reconcileLocalTranscriptionMode()
                }
            }
        } else {
            syncCatchUpTranscript()
        }

        reactions.available = session.capabilities.supportsReactions || features.permissions.canSendReaction
        reactions.ready = features.connected && phase == .connected
        refreshCameraReactionStatus()

        for event in features.reactions where receivedReactionIDs.insert(event.id).inserted {
            guard event.participantID != features.localParticipantID,
                  let kind = MeetingReaction.allCases.first(where: { $0.emoji == event.reaction.symbol }) else {
                continue
            }
            _ = chat.reactionHistory.receive(
                kind: kind,
                participantID: event.participantID,
                displayName: event.participantName,
                receivedAt: event.receivedAt
            )
            callView?.showReaction(kind, from: event.participantName)
        }
        if receivedReactionIDs.count > 1_024 {
            receivedReactionIDs = Set(features.reactions.map(\.id))
        }
    }

    private func applyCapturedChatMessages(_ messages: [GuestMeetingMessage]) {
        guard !leaving, !(session.chatService?.managesChatStoreSendCallbacks ?? false), !messages.isEmpty else { return }
        chat.replace(messages.map(Self.chatEntry(from:)))
        emitWorkspaceEvents()
    }

    private func bindChatCallbacks() {
        guard let chatService = session.chatService else {
            chat.canSend = false
            chat.unavailableReason = L("Chat is unavailable in this meeting.")
            return
        }
        chat.canSend = chatService.canSend
        chat.unavailableReason = chatService.unavailableReason
        guard !chatService.managesChatStoreSendCallbacks else { return }
        chat.onSend = { [weak self] text in
            guard let self, let service = self.session.chatService else { return }
            Task { @MainActor [weak self] in
                do {
                    try await service.send(text)
                } catch {
                    self?.reportMediaStatus(error.localizedDescription)
                }
            }
        }
        chat.onRetry = { [weak self] entry in
            guard let self, let service = self.session.chatService else { return }
            Task { @MainActor [weak self] in
                do {
                    try await service.retry(entry: entry)
                } catch {
                    self?.reportMediaStatus(error.localizedDescription)
                }
            }
        }
    }

    private func bindReactionsCallbacks() {
        reactions.available = session.capabilities.supportsReactions
        reactions.ready = phase == .connected
        reactions.sender = { [weak self] kind in
            guard let self, let service = self.session.reactionService, service.canSendReactions else {
                return false
            }
            let submissionID = UUID().uuidString
            self.reactions.trackSubmission(kind, id: submissionID)
            self.chat.reactionHistory.recordLocalSubmission(
                kind: kind,
                participantID: self.session.sessionSnapshot.participants.first(where: \.isLocal)?.id ?? "local",
                displayName: self.displayName,
                submissionID: submissionID
            )
            Task { @MainActor [weak self] in
                do {
                    try await service.sendReaction(kind, approvedID: nil)
                    self?.reactions.finishSubmission(id: submissionID, succeeded: true)
                    self?.callView?.showReaction(kind, from: L("You"))
                } catch {
                    self?.reactions.finishSubmission(id: submissionID, succeeded: false)
                    self?.reportMediaStatus(error.localizedDescription)
                }
            }
            return true
        }
        IOSCameraCapture.addObserver(
            id: id,
            onCurrentChanged: { [weak self] _ in
                self?.refreshCameraReactionStatus()
            },
            onObservedReaction: { [weak self] kind, effectID in
                self?.handleObservedCameraReaction(kind, effectID: effectID)
            }
        )
        refreshCameraReactionStatus()
    }

    func handleObservedCameraReaction(_ kind: MeetingReaction, effectID: String) {
        guard !leaving, phase == .connected, isCameraOn, isForegroundVisible, !isHeld, !quiet else { return }
        reactions.send(kind, source: .camera, effectID: effectID)
    }

    private func refreshCameraReactionStatus() {
        if !isCameraOn || localCameraTrack == nil {
            reactions.cameraStatus = .off
        } else if !isForegroundVisible || isHeld || quiet {
            reactions.cameraStatus = .paused
        } else {
            reactions.cameraStatus = IOSCameraCapture.current?.cameraReactionStatus ?? .unavailable
        }
    }

    private func bindTranscriptCallbacks() {
        catchUp.onSetTranscriptionEnabled = { [weak self] enabled in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.leaving else { return }
                if enabled {
                    self.assistantTranscriptionConsumers.insert("user")
                    _ = await self.localTranscriber.start()
                    self.refreshLocalAudioSink()
                    self.syncCatchUpTranscript()
                } else {
                    self.assistantTranscriptionConsumers.removeAll()
                    let wasLocalRunning = self.localTranscriber.state.isRunning
                    await self.localTranscriber.stop()
                    self.refreshLocalAudioSink()
                    if !wasLocalRunning && self.providerTranscriptActive && self.providerCanManageTranscript {
                        try? await self.session.transcriptService?.setEnabled(false)
                    }
                    self.syncCatchUpTranscript()
                }
            }
        }
        if session.capabilities.supportsProviderTranscript {
            catchUp.onLoadTranscriptHistory = { [weak self] in
                guard let self, !self.catchUp.isLoadingTranscriptHistory else { return }
                self.catchUp.isLoadingTranscriptHistory = true
                Task { @MainActor [weak self] in
                    defer { self?.catchUp.isLoadingTranscriptHistory = false }
                    try? await self?.session.transcriptService?.loadTranscriptHistory()
                }
            }
        } else {
            catchUp.onLoadTranscriptHistory = nil
        }
    }

    func speakVoiceReply(_ text: String, voiceStore: IOSVoiceStore = .shared) async throws {
        guard !leaving, phase == .connected else {
            AppDiagnostics.log("voice-reply-unavailable", ["reason": "disconnected"])
            throw MeetingSessionError.notConnected
        }
        guard !isHeld else {
            AppDiagnostics.log("voice-reply-unavailable", ["reason": "hold"])
            throw MeetingSessionError.unavailable(L("Cannot send a voice reply while the call is on hold."))
        }
        guard isMeetingSoundAudible else {
            AppDiagnostics.log("voice-reply-unavailable", ["reason": "soundOff"])
            throw MeetingSessionError.unavailable(L("Unmute meeting sound before sending a voice reply."))
        }

        let previous = voiceReplyTask
        previous?.cancel()
        isSpeakingVoiceReply = true
        let task = Task<Void, Error> { @MainActor [weak self] in
            // The previous reply must restore its sender before the next reply can borrow it.
            _ = await previous?.result
            try Task.checkCancellation()
            guard let self, !leaving, phase == .connected, !isHeld else { throw MeetingSessionError.notConnected }
            var stage = "synthesis"
            let engine = voiceStore.engine.rawValue
            AppDiagnostics.log("voice-reply-start", ["engine": engine, "provider": kind.rawValue])
            do {
                if voiceStore.supportsStreaming {
                    let stream = voiceStore.streamSynthesize(text)
                    var iterator = stream.makeAsyncIterator()
                    var firstChunk: AVAudioPCMBuffer?
                    while let candidate = try await iterator.next() {
                        try Task.checkCancellation()
                        if candidate.frameLength > 0 {
                            firstChunk = candidate
                            break
                        }
                    }
                    guard let firstChunk else { throw IOSVoiceSynthesisError.audio }
                    try Task.checkCancellation()
                    guard !leaving, phase == .connected, !isHeld else { throw MeetingSessionError.notConnected }
                    stage = "send"
                    AppDiagnostics.log("voice-reply-prepared", ["frames": Int(firstChunk.frameLength), "sampleRate": firstChunk.format.sampleRate, "streaming": true])
                    let utteranceID = UUID().uuidString
                    let startedAt = Date()
                    self.recordAssistantSpokenUtterance(id: utteranceID, text: text, startedAt: startedAt)
                    localTranscriber.discardPendingLocalAudio()
                    voiceReplyEchoGate.begin()
                    var completedNaturally = false
                    defer {
                        voiceReplyEchoGate.end(tailSeconds: completedNaturally ? 1.8 : 0.25)
                        if completedNaturally {
                            self.localTranscriber.discardPendingLocalAudio()
                        }
                        self.assistantSpeechLedger.endUtterance(id: utteranceID, endedAt: Date())
                    }
                    let playbackStream = AsyncThrowingStream<AVAudioPCMBuffer, Error> { continuation in
                        let feeder = Task {
                            var remaining = iterator
                            continuation.yield(firstChunk)
                            do {
                                while let next = try await remaining.next() {
                                    try Task.checkCancellation()
                                    if next.frameLength > 0 { continuation.yield(next) }
                                }
                                continuation.finish()
                            } catch {
                                continuation.finish(throwing: error)
                            }
                        }
                        continuation.onTermination = { termination in
                            if case .cancelled = termination { feeder.cancel() }
                        }
                    }
                    let played = await session.playVoiceReplyStream(playbackStream)
                    try Task.checkCancellation()
                    guard played else { throw MeetingSessionError.unavailable(L("Could not send the voice reply into this meeting.")) }
                    completedNaturally = true
                    AppDiagnostics.log("voice-reply-finished", ["provider": kind.rawValue])
                } else {
                    let buffer = try await voiceStore.synthesize(text)
                    try Task.checkCancellation()
                    guard !leaving, phase == .connected, !isHeld else { throw MeetingSessionError.notConnected }
                    stage = "send"
                    AppDiagnostics.log("voice-reply-prepared", ["frames": Int(buffer.frameLength), "sampleRate": buffer.format.sampleRate])
                    let utteranceID = UUID().uuidString
                    let startedAt = Date()
                    self.recordAssistantSpokenUtterance(id: utteranceID, text: text, startedAt: startedAt)
                    localTranscriber.discardPendingLocalAudio()
                    voiceReplyEchoGate.begin()
                    var completedNaturally = false
                    defer {
                        voiceReplyEchoGate.end(tailSeconds: completedNaturally ? 1.8 : 0.25)
                        if completedNaturally {
                            self.localTranscriber.discardPendingLocalAudio()
                        }
                        self.assistantSpeechLedger.endUtterance(id: utteranceID, endedAt: Date())
                    }
                    let played = await session.playVoiceReply(buffer)
                    try Task.checkCancellation()
                    guard played else { throw MeetingSessionError.unavailable(L("Could not send the voice reply into this meeting.")) }
                    completedNaturally = true
                    AppDiagnostics.log("voice-reply-finished", ["provider": kind.rawValue])
                }
            } catch {
                AppDiagnostics.log("voice-reply-error", ["stage": stage, "engine": engine, "cancelled": Task.isCancelled])
                throw error
            }
        }
        voiceReplyTask = task
        defer {
            if voiceReplyTask == task {
                voiceReplyTask = nil
                isSpeakingVoiceReply = false
            }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func speakVoiceBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        guard !leaving, phase == .connected else {
            throw MeetingSessionError.notConnected
        }
        guard !isHeld else {
            throw MeetingSessionError.unavailable(L("Cannot send a voice reply while the call is on hold."))
        }
        guard isMeetingSoundAudible else {
            throw MeetingSessionError.unavailable(L("Unmute meeting sound before sending a voice reply."))
        }
        let previous = voiceReplyTask
        previous?.cancel()
        isSpeakingVoiceReply = true
        let task = Task<Void, Error> { @MainActor [weak self] in
            _ = await previous?.result
            try Task.checkCancellation()
            guard let self, !leaving, phase == .connected, !isHeld else { throw MeetingSessionError.notConnected }
            localTranscriber.discardPendingLocalAudio()
            voiceReplyEchoGate.begin()
            var completedNaturally = false
            defer {
                voiceReplyEchoGate.end(tailSeconds: completedNaturally ? 1.8 : 0.25)
                if completedNaturally {
                    self.localTranscriber.discardPendingLocalAudio()
                }
            }
            let played = await session.playVoiceReply(buffer)
            try Task.checkCancellation()
            guard played else { throw MeetingSessionError.unavailable(L("Could not send the voice reply into this meeting.")) }
            completedNaturally = true
        }
        voiceReplyTask = task
        defer {
            if voiceReplyTask == task {
                voiceReplyTask = nil
                isSpeakingVoiceReply = false
            }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func cancelVoiceReply(forBargeIn: Bool = false) {
        remoteBargeInTask?.cancel()
        remoteBargeInTask = nil
        voiceReplyTask?.cancel()
        voiceReplyEchoGate.end(tailSeconds: forBargeIn ? 0.25 : 1.8)
        isSpeakingVoiceReply = false
    }

    private func handleVoiceReplyBargeIn(source: String) {
        guard isSpeakingVoiceReply || isVoiceReplyInFlight else { return }
        AppDiagnostics.log("voice-reply-barge-in", ["source": source])
        cancelVoiceReply(forBargeIn: true)
        onVoiceReplyBargeIn?()
    }

    var canSendAssistantChat: Bool {
        session.chatService?.canSend == true || chat.canSend
    }

    var isLocalMicrophoneUnmuted: Bool {
        isMicrophoneOn && isTalkRoom && !isHeld && !quiet
    }

    var participantDisplayNames: [String] {
        session.sessionSnapshot.participants.compactMap { $0.isLocal ? nil : $0.name }
    }

    func ensureTranscriptionRunningForAssistant() async {
        await ensureTranscriptionRunning(consumer: "assistant")
    }

    func releaseAssistantTranscription() async {
        await releaseTranscription(consumer: "assistant")
    }

    func recordAssistantSpokenUtterance(
        id: String = UUID().uuidString,
        text: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil
    ) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let endedAt {
            assistantSpeechLedger.recordCompletedUtterance(id: id, text: clean, startedAt: startedAt, endedAt: endedAt)
        } else {
            assistantSpeechLedger.beginUtterance(id: id, text: clean, startedAt: startedAt)
        }
        let segID = "assistant:" + id
        let seg = TranscriptSegment(
            id: segID,
            speaker: AssistantSpeechLedger.canonicalSpeakerName,
            text: clean,
            spokenAt: startedAt,
            isOwn: false,
            speakerRole: AssistantSpeechLedger.speakerRoleAssistant
        )
        if let idx = assistantTranscriptSegments.firstIndex(where: { $0.id == segID }) {
            assistantTranscriptSegments[idx] = seg
        } else {
            assistantTranscriptSegments.append(seg)
            if assistantTranscriptSegments.count > 200 {
                assistantTranscriptSegments.removeFirst(assistantTranscriptSegments.count - 200)
            }
        }
        syncCatchUpTranscript()
    }

    func ensureTranscriptionRunning(consumer: String) async {
        guard !leaving, phase == .connected else { return }
        assistantTranscriptionConsumers.insert(consumer)
        if providerTranscriptActive && providerCanViewTranscript == true {
            if !assistantTranscriptionConsumers.contains("user") {
                localTranscriber.setLocalMicrophoneOnly(true)
                if localTranscriber.canStartWithoutPermissionPrompt && !localTranscriber.state.isRunning {
                    _ = await localTranscriber.start()
                    refreshLocalAudioSink()
                    syncCatchUpTranscript()
                } else if consumer == "facilitator" && !localTranscriber.isCapturingAudio {
                    _ = await localTranscriber.startAudioTapOnly()
                    refreshLocalAudioSink()
                }
            }
            return
        }
        localTranscriber.setLocalMicrophoneOnly(false)
        guard !localTranscriber.state.isRunning else { return }
        _ = await localTranscriber.start()
        refreshLocalAudioSink()
        syncCatchUpTranscript()
    }

    func releaseTranscription(consumer: String) async {
        assistantTranscriptionConsumers.remove(consumer)
        guard !leaving else { return }
        if assistantTranscriptionConsumers.isEmpty && !didAutoStartLocalTranscription {
            if localTranscriber.isCapturingAudio {
                await localTranscriber.stop()
                refreshLocalAudioSink()
                syncCatchUpTranscript()
            }
        } else if !assistantTranscriptionConsumers.contains("facilitator") && localTranscriber.isAudioTapOnly {
            await localTranscriber.stopAudioTapOnly()
            refreshLocalAudioSink()
        }
    }

    private func reconcileLocalTranscriptionMode() async {
        guard !leaving, phase == .connected else { return }
        let serverVisible = providerTranscriptActive && (providerCanViewTranscript == true)
        if serverVisible {
            if assistantTranscriptionConsumers.contains("user") {
                localTranscriber.setLocalMicrophoneOnly(false)
                if !localTranscriber.state.isRunning {
                    _ = await localTranscriber.start()
                    refreshLocalAudioSink()
                    syncCatchUpTranscript()
                }
                return
            }
            if localTranscriber.canStartWithoutPermissionPrompt || localTranscriber.state.isRunning {
                localTranscriber.setLocalMicrophoneOnly(true)
                if !localTranscriber.state.isRunning {
                    _ = await localTranscriber.start()
                }
                refreshLocalAudioSink()
                syncCatchUpTranscript()
            } else if assistantTranscriptionConsumers.contains("facilitator") && !localTranscriber.isCapturingAudio {
                _ = await localTranscriber.startAudioTapOnly()
                refreshLocalAudioSink()
            }
        } else if (!assistantTranscriptionConsumers.isEmpty || didAutoStartLocalTranscription) {
            localTranscriber.setLocalMicrophoneOnly(false)
            if !localTranscriber.state.isRunning {
                _ = await localTranscriber.start()
                refreshLocalAudioSink()
                syncCatchUpTranscript()
            }
        }
    }

    func setRealtimeAudioTap(_ handler: (@Sendable (String, Data) -> Void)?) {
        localTranscriber.setPCM16AudioHandler(handler)
    }

    func sendAssistantChat(_ text: String) async throws {
        guard !leaving, phase == .connected else {
            throw MeetingSessionError.notConnected
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let service = session.chatService, service.canSend {
            try await service.send(clean)
        } else if chat.canSend, let onSend = chat.onSend {
            onSend(clean)
        } else {
            throw MeetingSessionError.unavailable(L("Chat is unavailable in this meeting."))
        }
    }

    func updateAssistantBadge(
        mode: IOSMeetingAssistantMode,
        isPaused: Bool,
        alertCount: Int,
        facilitatorSkillName: String? = nil
    ) {
        lastAssistantBadge = (mode, isPaused, alertCount, facilitatorSkillName)
        callView?.updateAssistantBadge(
            mode: mode,
            isPaused: isPaused,
            alertCount: alertCount,
            facilitatorSkillName: facilitatorSkillName
        )
    }

    func showAssistantBanner(title: String, reason: String, onTap: @escaping () -> Void) {
        callView?.showAssistantAlert(title: title, reason: reason, onTap: onTap)
    }

    private func setPrivateCheckAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        privateCheckAudioSink = sink
        refreshLocalAudioSink()
    }

    private func refreshLocalAudioSink() {
        let privateSink = privateCheckAudioSink
        let transcribeLocal = localTranscriber.isCapturingAudio
        if privateSink == nil && !transcribeLocal {
            session.setLocalAudioSink(nil)
            return
        }
        let transcriber = localTranscriber
        let echoGate = voiceReplyEchoGate
        let tracker = speechActivityTracker
        session.setLocalAudioSink { [weak self] buffer in
            privateSink?(buffer)
            let suppressing = echoGate.isSuppressing
            let inFlight = self?.isVoiceReplyInFlightThreadSafe() == true
            if tracker.observeLocalBuffer(buffer, isEchoSuppressing: suppressing, isVoiceReplyInFlight: inFlight) {
                Task { @MainActor [weak self] in
                    self?.handleVoiceReplyBargeIn(source: "localMic")
                }
            }
            if transcribeLocal && !suppressing {
                transcriber.enqueueLocalAudio(buffer)
            }
        }
    }

    private func sanitizedLocalSegmentsForEmission() -> [TranscriptSegment] {
        localTranscriber.segments.compactMap { seg -> TranscriptSegment? in
            guard seg.isOwn == true else { return seg }
            switch assistantSpeechLedger.classifyOwnServerSegment(text: seg.text, occurredAt: seg.spokenAt) {
            case .pureAssistant:
                return nil
            case .mixed(let userText, _):
                return TranscriptSegment(
                    id: seg.id,
                    speaker: seg.speaker,
                    text: userText,
                    spokenAt: seg.spokenAt,
                    isOwn: seg.isOwn,
                    speakerRole: seg.speakerRole
                )
            case .pureUser:
                return seg
            }
        }
    }

    private func syncCatchUpTranscript() {
        guard !leaving else { return }
        let localRunning = localTranscriber.state.isRunning
        let ownServerSegments = providerTranscriptSegments.filter { $0.isOwn == true }
        let visibleLocalSegments = sanitizedLocalSegmentsForEmission().filter { localSeg in
            guard localSeg.isOwn == true, !ownServerSegments.isEmpty else { return true }
            let localAt = localSeg.spokenAt
            return !ownServerSegments.contains { srv in
                if let localAt, let srvAt = srv.spokenAt, abs(localAt.timeIntervalSince(srvAt)) > 6.0 {
                    return false
                }
                return AssistantWakePhraseMatcher.isLikelySelfEcho(
                    candidate: localSeg.text,
                    lastSpoken: srv.text,
                    isLocal: true,
                    withinEchoWindow: true
                )
            }
        }
        let merged = providerTranscriptSegments + assistantTranscriptSegments + visibleLocalSegments
        catchUp.observe(
            messages: merged,
            canView: true,
            enabled: providerTranscriptActive || localRunning || !assistantTranscriptSegments.isEmpty
        )
        catchUp.canManageTranscript = (phase == .connected)
        if case .unavailable(let reason) = localTranscriber.state {
            catchUp.transcriptUnavailableReason = reason
        } else {
            catchUp.transcriptUnavailableReason = nil
        }
        emitWorkspaceEvents()
    }

    private func emitWorkspaceEvents() {
        guard !leaving, let handler = onWorkspaceEventsChanged else { return }
        let device = workspaceDeviceID.isEmpty ? "ios" : workspaceDeviceID
        var out: [SyncedTranscriptEvent] = []
        for seg in providerTranscriptSegments {
            let role = seg.speakerRole ?? (seg.isOwn == true ? AssistantSpeechLedger.speakerRoleUser : AssistantSpeechLedger.speakerRoleParticipant)
            out.append(SyncedTranscriptEvent(
                id: seg.id,
                providerMessageID: seg.id,
                kind: "transcript",
                sourceTier: 3,
                occurredAt: seg.spokenAt ?? Date(),
                speaker: seg.speaker,
                isOwn: seg.isOwn ?? false,
                speakerRole: role,
                text: seg.text,
                deviceID: device
            ))
        }
        for seg in assistantTranscriptSegments {
            out.append(SyncedTranscriptEvent(
                id: seg.id,
                providerMessageID: nil,
                kind: "transcript",
                sourceTier: 3,
                occurredAt: seg.spokenAt ?? Date(),
                speaker: seg.speaker ?? AssistantSpeechLedger.canonicalSpeakerName,
                isOwn: false,
                speakerRole: AssistantSpeechLedger.speakerRoleAssistant,
                text: seg.text,
                deviceID: device
            ))
        }
        for seg in sanitizedLocalSegmentsForEmission() {
            let isOwn = seg.isOwn ?? false
            out.append(SyncedTranscriptEvent(
                id: "local:" + seg.id,
                providerMessageID: nil,
                kind: "transcript",
                sourceTier: 2,
                occurredAt: seg.spokenAt ?? Date(),
                speaker: seg.speaker,
                isOwn: isOwn,
                speakerRole: seg.speakerRole ?? (isOwn ? AssistantSpeechLedger.speakerRoleUser : AssistantSpeechLedger.speakerRoleParticipant),
                text: seg.text,
                deviceID: device
            ))
        }
        for msg in chat.items {
            out.append(SyncedTranscriptEvent(
                id: "chat:" + msg.id,
                providerMessageID: msg.id,
                kind: "chat",
                sourceTier: 3,
                occurredAt: msg.sentAt,
                speaker: msg.sender,
                isOwn: msg.isOwn,
                speakerRole: msg.isOwn ? AssistantSpeechLedger.speakerRoleUser : AssistantSpeechLedger.speakerRoleParticipant,
                text: msg.text,
                deviceID: device
            ))
        }
        let partialEventIDs = Set(localTranscriber.partialSegmentIDs.map { "local:" + $0 })
        handler(id, out, micActiveIntervals, partialEventIDs)
    }

    func latestTranscriptExcerpt() -> String {
        let merged = providerTranscriptSegments + assistantTranscriptSegments + sanitizedLocalSegmentsForEmission()
        for seg in merged.reversed() {
            let clean = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return String(clean.prefix(120)) }
        }
        return ""
    }

    func configureAssistantHUD(talk: IOSAssistantTalkController, speech: IOSAssistantSpeechCoordinator) {
        assistantHUDContext = (talk, speech)
        callView?.attachAssistantVoiceHUD(talk: talk, speech: speech) { [weak self] in
            if let onOpenAsk = self?.onOpenAsk {
                onOpenAsk()
            } else {
                self?.onOpenAssistant?()
            }
        }
    }

    func presentAskRockSheet(talk: IOSAssistantTalkController, speech: IOSAssistantSpeechCoordinator) {
        guard let host = topPresentedCallController() else { return }
        let view = DismissableNavigationSheet(title: L("Ask Rock")) {
            IOSAssistantTalkView(talk: talk, speech: speech)
        }
        let sheet = UIHostingController(rootView: view)
        sheet.overrideUserInterfaceStyle = .dark
        sheet.modalPresentationStyle = .formSheet
        host.present(sheet, animated: true)
    }

    func presentBoardSheet(controller: IOSAssistantBoardController, defaultBoardURL: String) {
        guard presentedBoardController?.presentingViewController == nil,
              let host = topPresentedCallController() else { return }
        let view = IOSAssistantBoardSheet(controller: controller, defaultBoardURL: defaultBoardURL)
        let sheet = UIHostingController(rootView: view)
        sheet.overrideUserInterfaceStyle = .dark
        sheet.modalPresentationStyle = .formSheet
        presentedBoardController = sheet
        host.present(sheet, animated: true)
    }

    func presentNotesSheet(workspace: IOSWorkspaceCoordinator) {
        guard let sid = workspaceSessionID, let host = topPresentedCallController() else { return }
        let view = IOSInCallNotesView(workspace: workspace, sessionID: sid, title: title, roomURL: invitationURL)
        let sheet = UIHostingController(rootView: view)
        sheet.overrideUserInterfaceStyle = .dark
        sheet.modalPresentationStyle = .formSheet
        host.present(sheet, animated: true)
    }

    func presentAssistantSheet(
        assistant: IOSAssistantCoordinator,
        speech: IOSAssistantSpeechCoordinator? = nil,
        skills: IOSAssistantSkillsController? = nil,
        facilitator: IOSAutonomousMeetingFacilitator? = nil,
        board: IOSAssistantBoardController? = nil
    ) {
        guard let host = topPresentedCallController() else { return }
        let view = IOSAssistantModeSheet(
            controllerID: id,
            meetingTitle: title,
            canSendChat: canSendAssistantChat,
            assistant: assistant,
            speech: speech,
            skills: skills,
            facilitator: facilitator,
            board: board
        )
        let sheet = UIHostingController(rootView: view)
        sheet.overrideUserInterfaceStyle = .dark
        sheet.modalPresentationStyle = .formSheet
        host.present(sheet, animated: true)
    }

    private func presentVoiceReplySheet() {
        guard let host = topPresentedCallController(), !isHeld else { return }
        let targets = voiceReplyTargetsProvider?() ?? [
            VoiceReplyTargetRoom(id: id, title: title, isTalk: isTalkRoom, isCurrent: true)
        ]
        guard !targets.isEmpty else { return }
        let sheet = UIHostingController(
            rootView: VoiceReplySheetView(
                targets: targets,
                initialTargetID: id,
                onSpeak: { [weak self] targetID, message in
                    guard let self else { return }
                    if let route = self.onSpeakVoiceReplyInRoom {
                        try await route(targetID, message)
                    } else if targetID == self.id {
                        try await self.speakVoiceReply(message)
                    }
                },
                onStop: { [weak self] targetID in
                    guard let self else { return }
                    if let cancel = self.onCancelVoiceReplyInRoom {
                        cancel(targetID)
                    } else if targetID == self.id {
                        self.cancelVoiceReply()
                    }
                }
            )
        )
        sheet.overrideUserInterfaceStyle = .dark
        sheet.modalPresentationStyle = .formSheet
        host.present(sheet, animated: true)
    }

    private func presentTranscriptionSettingsSheet() {
        guard let host = topPresentedCallController() else { return }
        let view = NavigationStack {
            TranscriptionAndVoiceSettingsView(onDone: { [weak host] in
                host?.dismiss(animated: true)
            })
        }
        let sheet = UIHostingController(rootView: view)
        sheet.overrideUserInterfaceStyle = .dark
        sheet.modalPresentationStyle = .formSheet
        host.present(sheet, animated: true)
    }

    private func topPresentedCallController() -> UIViewController? {
        var top: UIViewController? = callView
        while let next = top?.presentedViewController {
            top = next
        }
        return top
    }

    private func configureStudio() {
        if UserDefaults.standard.object(forKey: GuestAudioProfile.preferenceKey) == nil, studio.hasSelection {
            let initialProfile: GuestAudioProfile = studio.profile == .music ? .music : .speech
            UserDefaults.standard.set(initialProfile.rawValue, forKey: GuestAudioProfile.preferenceKey)
        }
        studio.applyProfile = { [weak self] studioProfile in
            let guestProfile: GuestAudioProfile = (studioProfile == .music) ? .music : .speech
            UserDefaults.standard.set(guestProfile.rawValue, forKey: GuestAudioProfile.preferenceKey)
            guard let self, self.phase == .connected else { return }
            try await self.session.setAudioProfile(guestProfile)
        }
        studio.onCameraSelectionChanged = { device in
            guard let device, !device.uniqueID.isEmpty else { return }
            UserDefaults.standard.set(device.uniqueID, forKey: "nativeDesktop.cameraID")
        }
        studio.enableCamera = { [weak self] in self?.setCamera(true) }
        studio.enableMicrophone = { [weak self] in self?.setMicrophone(true) }
        studio.willChooseAudioOutput = { [weak self] in self?.workspaceAudio?.audio.userWillSelectOutput() }
        studio.selectLiveCamera = { [weak self] device in
            UserDefaults.standard.set(device.uniqueID, forKey: "nativeDesktop.cameraID")
            try await IOSCameraCapture.current?.selectDevice(uniqueID: device.uniqueID, position: device.position)
            guard let self, self.isCameraOn else { return }
            try await self.session.setCamera(true)
        }
        studio.liveCaptureDevice = { [weak self] in
            self?.cachedLiveCaptureDevice
        }
        studio.makeLivePreview = { [weak self] in
            guard let track = self?.localCameraTrack else { return nil }
            let preview = CallVideoView()
            preview.track = .native(track)
            preview.isMirrored = (IOSCameraCapture.current?.currentPosition ?? .front) == .front
            return StudioLivePreview(view: preview, stop: { preview.track = nil })
        }
        studio.soundCheck.verifyMuted = { [weak self] in
            guard let self, self.phase == .connected, !self.leaving, !self.isHeld, !self.quiet else {
                throw CancellationError()
            }
            if let workspaceAudio = self.workspaceAudio {
                try await workspaceAudio.setTalkMicrophone(false, for: self.id)
            }
        }
        studio.presenter.supportsVP9 = session.capabilities.supportsScreenShareVP9
        studio.presenter.preparePrivateCamera = { [weak self] in
            await self?.studio.releasePreviewCamera()
        }
        studio.presenter.onPreviewVisibilityChanged = { [weak self] visible in
            self?.callView?.sharePreview.setEditorVisible(visible)
        }
        studio.presenter.makeCameraSource = { [weak self] onFrame in
            guard let track = self?.localCameraTrack else { return nil }
            return TrackPresenterCamera(source: .native(track), onFrame: onFrame)
        }
        #if canImport(ScreenCaptureKit)
        if IOSNativeScreenCaptureAvailability.isAvailable, #available(iOS 27.0, *) {
            studio.presenter.makeScreenSource = { onFrame, onEffect, onSelection, onEnd in
                IOSNativeScreenCaptureAvailability.makePresenterSource(
                    onFrame: onFrame,
                    onEffect: onEffect,
                    onSelection: onSelection,
                    onEnd: onEnd
                )
            }
        }
        #endif
        studio.presenter.shareOtherApps = { [weak self] in
            guard let self else { return }
            self.studio.close()
            Task { @MainActor [weak self] in
                guard let self, !self.leaving else { return }
                await self.stopScreenSharing(retirePresenter: true)
                guard !self.leaving else { return }
                self.setScreenSharing(true)
            }
        }
        studio.presenter.startSharing = { [weak self] sample, request in
            guard let self, !self.leaving, self.phase == .connected, !self.isHeld, !self.quiet else {
                throw CancellationError()
            }
            try request.checkCancellation()
            await self.stopScreenSharing(retirePresenter: false)
            try request.checkCancellation()
            guard !self.leaving, self.phase == .connected, !self.isHeld, !self.quiet,
                  let screenShare = self.screenShare else {
                throw CancellationError()
            }
            let useVP9 = self.studio.presenter.encodingPreference == .textDetail
                && self.session.capabilities.supportsScreenShareVP9
            try await screenShare.startComposed(
                initialSample: sample,
                codec: useVP9 ? "vp9" : "h264"
            )
        }
        studio.presenter.sendSample = { [weak self] sample in
            guard let self, !self.isHeld, !self.quiet, !self.leaving else { return }
            self.screenShare?.sendComposed(sample)
        }
        studio.presenter.stopSharing = { [weak self] in
            await self?.stopScreenSharing(retirePresenter: true)
        }
    }

    private func callVideoStreams(for videos: [NativeDesktopExternalVideo],
                                  activeCompositeIDs: inout Set<String>) -> [CallVideoStream] {
        videos.map { video in
            let source: CallVideoSource
            if let crop = video.crop {
                activeCompositeIDs.insert(video.id)
                if let existing = compositeSources[video.id] {
                    existing.update(crop)
                    source = .composite(existing)
                } else {
                    let created = CompositeVideoSource(track: video.track, rectangle: crop)
                    compositeSources[video.id] = created
                    source = .composite(created)
                }
            } else {
                source = .native(video.track)
            }
            return CallVideoStream(
                id: video.id,
                source: video.source == .screen ? .screenShareVideo : .camera,
                track: source
            )
        }
    }

    private func renderSnapshot(using explicitSnapshot: MeetingSessionSnapshot? = nil) {
        guard !leaving else { return }
        let snapshot = explicitSnapshot ?? session.sessionSnapshot
        let videos = session.incomingVideo
        let byParticipant = Dictionary(grouping: videos, by: \.participantID)
        if videos.count != lastLoggedVideoCount {
            lastLoggedVideoCount = videos.count
            AppDiagnostics.log("meeting-video", [
                "provider": kind.rawValue,
                "tracks": videos.count,
                "screens": videos.filter { $0.source == .screen }.count
            ])
        }

        var activeCompositeIDs = Set<String>()
        var knownParticipantIDs = Set<String>()
        var participants: [CallParticipant] = snapshot.participants.map { person in
            knownParticipantIDs.insert(person.id)
            var streams: [CallVideoStream] = []
            if person.isLocal {
                if let localCameraTrack {
                    streams.append(.init(id: person.id + ".camera", source: .camera, track: .native(localCameraTrack)))
                }
            } else {
                streams = callVideoStreams(for: byParticipant[person.id] ?? [], activeCompositeIDs: &activeCompositeIDs)
            }
            let hasCameraStream = streams.contains { $0.source == .camera && !$0.isMuted }
            let hasScreenStream = streams.contains { $0.source == .screenShareVideo && !$0.isMuted }
            let micOn = person.isLocal
                ? (isTalkRoom && snapshot.effective.microphoneOn && !(workspaceAudio?.isMuted ?? true))
                : (person.microphoneOn ?? false)
            let camOn = person.isLocal
                ? (localCameraTrack != nil || snapshot.effective.cameraOn)
                : ((person.cameraOn ?? false) || hasCameraStream)
            let shareOn = person.isLocal
                ? snapshot.effective.sharing
                : ((person.sharing ?? false) || hasScreenStream)
            return CallParticipant(
                id: person.id,
                name: person.name,
                isLocal: person.isLocal,
                microphoneOn: micOn,
                cameraOn: camOn,
                screenShareOn: shareOn,
                isSpeaking: person.speaking ?? false,
                videoTracks: streams
            )
        }

        // Preserve remote video/screen streams whose tracks arrive before roster metadata
        // or in restricted rooms where remote participants are omitted from roster snapshots.
        for participantID in byParticipant.keys.filter({ !knownParticipantIDs.contains($0) }).sorted() {
            let streams = callVideoStreams(for: byParticipant[participantID] ?? [], activeCompositeIDs: &activeCompositeIDs)
            guard !streams.isEmpty else { continue }
            participants.append(CallParticipant(
                id: participantID,
                name: nil,
                isLocal: false,
                microphoneOn: false,
                cameraOn: streams.contains { $0.source == .camera && !$0.isMuted },
                screenShareOn: streams.contains { $0.source == .screenShareVideo && !$0.isMuted },
                isSpeaking: false,
                videoTracks: streams
            ))
        }
        compositeSources = compositeSources.filter { activeCompositeIDs.contains($0.key) }

        if participants.isEmpty {
            participants = [
                CallParticipant(
                    id: "local",
                    name: displayName.isEmpty ? L("Musician") : displayName,
                    isLocal: true,
                    microphoneOn: false,
                    cameraOn: false,
                    screenShareOn: isSharingScreen,
                    isSpeaking: false,
                    videoTracks: localCameraTrack.map { [.init(id: "local.camera", source: .camera, track: .native($0))] } ?? []
                )
            ]
        }

        callView?.render(snapshot: CallMediaSnapshot(participants: participants))
        if phase == .connected {
            updateVideoDemand()
        }
    }

    private func updateMicrophoneIndicator(snapshot explicit: MeetingSessionSnapshot? = nil) {
        let snapshot = explicit ?? session.sessionSnapshot
        let previousMic = isMicrophoneOn
        let unmuted = isTalkRoom && snapshot.effective.microphoneOn && !(workspaceAudio?.isMuted ?? true) && !isHeld && !quiet
        isMicrophoneOn = unmuted
        callView?.setMicrophone(unmuted)
        if previousMic != unmuted {
            onMicrophoneStateChanged?(id, unmuted)
        }
        let now = Date()
        if unmuted {
            if micActiveStart == nil { micActiveStart = now }
        } else if let start = micActiveStart {
            micActiveStart = nil
            if now > start { micActiveIntervals.append(DateInterval(start: start, end: now)) }
        }

        let status: PiPMicrophoneStatus
        if isHeld || quiet || phase != .connected {
            status = .unavailable
        } else if unmuted {
            if let rms = snapshot.effective.microphoneLevel {
                studio.microphoneActivity.receive(rms: rms)
            }
            status = .on
        } else {
            status = .muted
        }
        studio.microphoneActivity.setStatus(status)
        callView?.setFloatingMicrophoneStatus(status)
    }

    private func reportMediaStatus(_ message: String?) {
        callView?.showMediaStatus(message)
        onMediaStatus?(message)
    }

    private func finish(event: CallEvent) async {
        guard !terminalDelivered else { return }
        terminalDelivered = true
        if let start = micActiveStart {
            micActiveStart = nil
            let end = Date()
            if end > start { micActiveIntervals.append(DateInterval(start: start, end: end)) }
        }
        emitWorkspaceEvents()
        leaving = true
        endBackgroundRecoveryTask()
        connectTask?.cancel()
        connectTask = nil
        microphoneTask?.cancel()
        microphoneTask = nil
        requestedMicrophone = nil
        cameraTask?.cancel()
        cameraTask = nil
        requestedCamera = nil
        cancelVoiceReply()
        privateCheckAudioSink = nil
        session.setTranscriptionAudioHandler(nil)
        session.setLocalAudioSink(nil)
        broadcastObservation = nil
        IOSCameraCapture.removeObserver(id: id)
        appLifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        appLifecycleObservers = []

        notifyExternalBoardShareStopped()
        let wasBroadcast = screenShare?.isBroadcastSharing == true
        await localTranscriber.reset()
        await screenShare?.stop()
        screenShare = nil
        if wasBroadcast { onBroadcastOwnershipChanged?(false) }
        compositeSources.removeAll()
        callView?.endFloatingVideo()
        studio.end()
        chat.clear()

        workspaceAudio?.unregisterSession(id: id)
        _ = await session.leave()
        _ = await catchUp.finishMeeting().value

        if let view = callView, view.presentingViewController != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                view.dismiss(animated: false) {
                    continuation.resume()
                }
            }
        }
        callView = nil
        onEvent?(event)
    }

    private static func chatEntry(from message: GuestMeetingMessage) -> ChatEntry {
        let delivery: ChatDelivery
        switch message.delivery {
        case .pending: delivery = .pending
        case .sent: delivery = .sent
        case .failed: delivery = .failed
        }
        return ChatEntry(
            id: message.id,
            sender: message.participantName,
            text: message.text,
            sentAt: message.sentAt ?? message.receivedAt ?? Date(),
            isOwn: message.isOwn,
            delivery: delivery
        )
    }
}

private struct DismissableNavigationSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Done")) { dismiss() }
                    }
                }
        }
    }
}

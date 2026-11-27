#if NATIVE_DIRECT_UPDATES
import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor struct NativeDesktopUpdateMediaGate {
    var claimIfDrained: (UUID) -> Bool
    var drain: (UUID) async -> Bool
    var release: (UUID) -> Void
    static var live: Self { .init(
        claimIfDrained: { NativeDesktopForegroundMedia.shared.prepareForUpdateIfDrained($0) },
        drain: { await NativeDesktopForegroundMedia.shared.prepareForUpdate($0) },
        release: { NativeDesktopForegroundMedia.shared.cancelUpdatePreparation($0) }) }
}

/// Direct-distribution only. Meeting admission and Sparkle callbacks share MainActor.
@MainActor final class NativeDesktopUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    struct StagedUpdate: Equatable {
        let version: String
        let build: Int
        let diff: UpdateChangelogDiff
    }

    let safety: NativeUpdateSafety
    @Published private(set) var status = L("Updates install only when no meeting is active.")
    @Published private(set) var beta = UserDefaults.standard.bool(forKey: "native.updates.beta")
    @Published private(set) var stagedUpdate: StagedUpdate?
    @Published private(set) var recoveryChangelog: UpdateChangelogDiff?
    @Published private(set) var changelogHistory: [UpdateChangelogSection] = []
    @Published var showingChangelogSheet = false
    @Published private(set) var bannerDismissedBuild: Int?
    private var subscriptions = Set<AnyCancellable>()
    private var deferred: [() -> Void] = []
    private var installWhenIdle: (() -> Void)?
    private var stagedInstallAction: (() -> Void)?
    private var stagedAppcastItem: SUAppcastItem?
    private var driver: MeetingSafeUpdateDriver!
    private(set) var updater: SPUUpdater!
    var busy: () -> Bool = { true }
    var channelLocked: Bool { safety.recoveryTargetBuild != nil || prepared || updater?.sessionInProgress == true }
    var activeChangelog: UpdateChangelogDiff? { stagedUpdate?.diff ?? recoveryChangelog }
    var showsBanner: Bool {
        !mayStartMeeting || (stagedUpdate != nil && bannerDismissedBuild != stagedUpdate?.build)
    }
    var canTriggerCheckOrReview: Bool { updater.canCheckForUpdates || stagedUpdate != nil }
    private var prepared = false
    private var stage2Requested = false
    private var cycleActive = false
    private var cycleEpoch = UUID()
    private var mediaPreparedForInstall = false
    private var mediaPreparation: Task<Bool, Never>?
    private let mediaGate: NativeDesktopUpdateMediaGate
    private let currentBuild: Int
    private let currentVersion: String
    private let changelogDefaults: UserDefaults
    private var loadedBundledChangelog: [UpdateChangelogSection]?
    @Published private(set) var availableChangelogBuild: Int?
    var installedBuild: Int { currentBuild }
    var installedVersion: String { currentVersion }
    var mayStartMeeting: Bool { safety.mayStartMeeting }

    init(
        safety: NativeUpdateSafety,
        mediaGate: NativeDesktopUpdateMediaGate? = nil,
        currentBuild: Int? = nil,
        currentVersion: String? = nil,
        changelogDefaults: UserDefaults = .standard,
        bundledChangelog: [UpdateChangelogSection]? = nil
    ) {
        self.safety = safety
        self.mediaGate = mediaGate ?? .live
        self.currentBuild = currentBuild ?? (Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0)
        self.currentVersion = currentVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0")
        self.changelogDefaults = changelogDefaults
        self.loadedBundledChangelog = bundledChangelog
        super.init()
        driver = MeetingSafeUpdateDriver(owner: self)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        safety.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        if let target = safety.recoveryTargetBuild {
            status = L("Finish updating to build %ld before joining a meeting.", target)
            prepared = true
            if let cached = UpdateChangelogCache.load(targetBuild: target, defaults: changelogDefaults) {
                recoveryChangelog = UpdateChangelogParser.slice(
                    markdown: cached.markdown,
                    installedBuild: self.currentBuild,
                    targetBuild: target,
                    installedVersion: self.currentVersion,
                    targetVersion: cached.targetVersion,
                    targetChannel: cached.channel
                )
            }
        }
        if bundledChangelog != nil {
            refreshChangelogHistory()
        }
    }
    /// A newer published build than the update Sparkle already downloaded.
    @Published private(set) var newerThanDownloaded: (build: Int, url: URL)?
    static let launchedBuildKey = "native.updates.lastLaunchedBuild"

    func start() {
        do { try updater.start() } catch { status = error.localizedDescription; return }
        // Right after an update installs, look again: a newer build may have been
        // published while the previous one waited to install on quit.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let previous = UserDefaults.standard.string(forKey: Self.launchedBuildKey)
        UserDefaults.standard.set(build, forKey: Self.launchedBuildKey)
        if let previous, previous != build, updater.canCheckForUpdates { updater.checkForUpdatesInBackground() }
    }

    /// Sparkle offers an update it downloaded earlier without reading the feed
    /// again. Compares it with the published inventory and says when it is stale.
    func compareWithPublished(_ item: SUAppcastItem) {
        guard let staged = Int(item.versionString), let feed = updater.feedURL,
              let inventory = URL(string: "latest.json", relativeTo: feed) else { return }
        let beta = self.beta
        Task { @MainActor [weak self] in
            guard let (data, response) = try? await URLSession.shared.data(from: inventory),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let latest = Self.latestBuild(in: data, beta: beta), latest.build > staged else { return }
            self?.newerThanDownloaded = latest
            self?.status = L("Build %ld was downloaded earlier. Build %ld is newer: install %ld now and the app checks again after it restarts, or download %ld directly.",
                             staged, latest.build, staged, latest.build)
        }
    }
    nonisolated static func latestBuild(in data: Data, beta: Bool) -> (build: Int, url: URL)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let channels = beta ? ["stable", "beta"] : ["stable"]
        return channels.compactMap { name -> (build: Int, url: URL)? in
            guard let entry = object[name] as? [String: Any], let build = (entry["build"] as? String).flatMap(Int.init),
                  let url = (entry["downloadURL"] as? String).flatMap(URL.init(string:)),
                  url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "rock.glowsoft.ru",
                  url.path.hasPrefix("/mac/releases/RockNRoll-"),
                  url.path.hasSuffix("-arm64.dmg") else { return nil }
            return (build, url)
        }.max { $0.build < $1.build }
    }
    func check() {
        if stagedUpdate != nil {
            if let item = stagedAppcastItem { compareWithPublished(item) }
            showingChangelogSheet = true
            return
        }
        guard updater.canCheckForUpdates else { return }
        if busy() {
            status = L("Checking in the background. Installation will wait until the meeting ends.")
            updater.checkForUpdatesInBackground()
        } else { updater.checkForUpdates() }
    }
    func installStagedUpdate() {
        guard let stagedInstallAction else { return }
        showingChangelogSheet = false
        stagedInstallAction()
    }
    func dismissBannerForCurrentUpdate() {
        bannerDismissedBuild = stagedUpdate?.build
    }
    func ensureChangelogHistoryLoaded() {
        guard loadedBundledChangelog == nil else { return }
        loadedBundledChangelog = UpdateChangelogLedger.loadBundled()
        refreshChangelogHistory()
    }

    private func refreshChangelogHistory() {
        guard let bundled = loadedBundledChangelog else { return }
        var supplemental: [UpdateChangelogSection] = []
        var activeAvailableBuild = stagedUpdate?.build ?? safety.recoveryTargetBuild
        if let stagedSections = stagedUpdate?.diff.sections {
            supplemental.append(contentsOf: stagedSections)
        }
        if let recoverySections = recoveryChangelog?.sections {
            supplemental.append(contentsOf: recoverySections)
        }
        if let cached = UpdateChangelogCache.loadLatest(defaults: changelogDefaults),
           cached.targetBuild > currentBuild,
           beta || cached.channel != "beta" || safety.recoveryTargetBuild == cached.targetBuild {
            if activeAvailableBuild == nil {
                activeAvailableBuild = cached.targetBuild
            }
            supplemental.append(
                contentsOf: UpdateChangelogParser.parseSections(
                    cached.markdown,
                    targetBuild: cached.targetBuild,
                    targetChannel: cached.channel
                )
            )
        }
        if availableChangelogBuild != activeAvailableBuild {
            availableChangelogBuild = activeAvailableBuild
        }
        let merged = UpdateChangelogLedger.merge(bundled: bundled, supplemental: supplemental)
        if changelogHistory != merged {
            changelogHistory = merged
        }
    }

    private func makeDiff(for item: SUAppcastItem, targetBuild: Int) -> UpdateChangelogDiff {
        let itemChannel = (item.channel == "beta") ? "beta" : "stable"
        if let description = item.itemDescription, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UpdateChangelogCache.save(
                markdown: description,
                targetBuild: targetBuild,
                targetVersion: item.displayVersionString,
                channel: itemChannel,
                defaults: changelogDefaults
            )
            return UpdateChangelogParser.slice(
                markdown: description,
                installedBuild: currentBuild,
                targetBuild: targetBuild,
                installedVersion: currentVersion,
                targetVersion: item.displayVersionString,
                targetChannel: itemChannel
            )
        }
        if let cached = UpdateChangelogCache.load(targetBuild: targetBuild, defaults: changelogDefaults) {
            return UpdateChangelogParser.slice(
                markdown: cached.markdown,
                installedBuild: currentBuild,
                targetBuild: targetBuild,
                installedVersion: currentVersion,
                targetVersion: item.displayVersionString,
                targetChannel: cached.channel ?? itemChannel
            )
        }
        return UpdateChangelogDiff(
            installedVersion: currentVersion,
            installedBuild: currentBuild,
            targetVersion: item.displayVersionString,
            targetBuild: targetBuild,
            sections: [],
            fallbackMarkdown: nil,
            hasOlderUnshownChanges: false
        )
    }
    func setBeta(_ value: Bool) {
        guard !channelLocked else { return }
        beta = value; newerThanDownloaded = nil; UserDefaults.standard.set(value, forKey: "native.updates.beta")
        updater.resetUpdateCycle()
        refreshChangelogHistory()
    }
    func showWhenIdle(_ action: @escaping () -> Void) {
        if busy() { deferred.append(action); status = L("An update is waiting until the meeting ends.") }
        else { action() }
    }
    func activityChanged() {
        guard !busy(), !safety.installationReserved else { return }
        if let action = installWhenIdle { installWhenIdle = nil; action(); return }
        while !deferred.isEmpty, !busy(), !safety.installationReserved {
            deferred.removeFirst()()
        }
    }
    private func reserve() -> Bool {
        guard cycleActive, !busy() else { return false }
        if !mediaPreparedForInstall { mediaPreparedForInstall = mediaGate.claimIfDrained(cycleEpoch) }
        guard mediaPreparedForInstall else { return false }
        do { return try safety.reserveInstallation(busy: busy()) }
        catch { status = error.localizedDescription; return false }
    }
    func prepareChoice(_ item: SUAppcastItem) -> Bool {
        guard cycleActive else { return false }
        do {
            guard let target = Int(item.versionString) else { throw NativeUpdateSafety.SafetyError.invalidBuild }
            try safety.prepareUpdate(targetBuild: target); prepared = true; return true
        } catch { status = error.localizedDescription; return false }
    }
    func installChoice(_ choice: SPUUserUpdateChoice, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard cycleActive else { return }
        guard choice == .install else { reply(choice); return }
        if reserve() { reply(choice); return }
        if busy() {
            let epoch = cycleEpoch
            installWhenIdle = { [weak self] in
                guard let self, self.cycleActive, self.cycleEpoch == epoch else { return }
                self.installChoice(choice, reply: reply)
            }
            status = L("The update will install after the meeting ends.")
            return
        }
        let epoch = cycleEpoch
        Task { @MainActor [weak self] in
            guard let self, cycleActive, cycleEpoch == epoch else { return }
            if mediaPreparation == nil {
                mediaPreparation = Task { await self.mediaGate.drain(epoch) }
            }
            let clean = await mediaPreparation?.value == true
            guard cycleActive, cycleEpoch == epoch else { return }
            mediaPreparation = nil; mediaPreparedForInstall = clean
            guard clean, reserve() else {
                status = L("Media could not stop safely for the update. Leave any private check and try again.")
                reply(.dismiss); return
            }
            reply(choice)
        }
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !safety.installationReserved else { throw NativeUpdateSafety.SafetyError.installerMayRun }
        status = L("Checking for updates…")
        cycleActive = true; cycleEpoch = UUID(); installWhenIdle = nil; deferred.removeAll(); driver.invalidate()
    }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { beta ? ["beta"] : [] }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard let target = Int(item.versionString) else { return }
        _ = makeDiff(for: item, targetBuild: target)
        refreshChangelogHistory()
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard cycleActive, let target = Int(item.versionString) else { throw NativeUpdateSafety.SafetyError.invalidBuild }
        try safety.prepareUpdate(targetBuild: target); prepared = true
    }
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) { safety.markInstallerMayRun() }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { stage2Requested = true }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { reserve() }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock action: @escaping () -> Void) -> Bool {
        guard cycleActive, prepareChoice(item), let target = Int(item.versionString) else { return true }
        let epoch = cycleEpoch
        let diff = makeDiff(for: item, targetBuild: target)
        stagedAppcastItem = item
        stagedUpdate = StagedUpdate(version: item.displayVersionString, build: target, diff: diff)
        bannerDismissedBuild = nil
        refreshChangelogHistory()
        stagedInstallAction = { [weak self] in
            guard let self, self.cycleActive, self.cycleEpoch == epoch else { return }
            self.installChoice(.install) { if $0 == .install { action() } }
        }
        compareWithPublished(item)
        status = L("Version %@ (%ld) is ready to install.", item.displayVersionString, target)
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        status = error.localizedDescription
        if !stage2Requested { safety.releaseReservationAfterVerifiedStage2NotRequested() }
        invalidateCycle()
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        invalidateCycle()
        clearPreparedIfSafe()
        if error == nil, !prepared { status = L("Updates install only when no meeting is active.") }
    }
    private func invalidateCycle() {
        let epoch = cycleEpoch
        cycleActive = false; cycleEpoch = UUID(); installWhenIdle = nil; stagedInstallAction = nil
        stagedUpdate = nil; stagedAppcastItem = nil; showingChangelogSheet = false; newerThanDownloaded = nil
        deferred.removeAll(); driver.invalidate()
        refreshChangelogHistory()
        if !safety.installationReserved {
            mediaPreparedForInstall = false
            // A native operation may outlive cancellation. Release its exclusion
            // only after that retained drain task has actually completed.
            let pending = mediaPreparation; mediaPreparation = nil
            if let pending { Task { _ = await pending.value; self.mediaGate.release(epoch) } }
            else { mediaGate.release(epoch) }
        }
    }
    func clearPreparedIfSafe() {
        do { if try safety.clearPreparedUpdateIfSafe() { prepared = false } }
        catch { status = error.localizedDescription }
    }
    func willTerminate() { clearPreparedIfSafe() }
}

@MainActor private final class MeetingSafeUpdateDriver: NSObject, SPUUserDriver, SPUStandardUserDriverDelegate {
    weak var owner: NativeDesktopUpdates?
    private var generation = 0
    private lazy var standard = SPUStandardUserDriver(hostBundle: .main, delegate: self)
    init(owner: NativeDesktopUpdates) {
        self.owner = owner
        super.init()
    }
    nonisolated func standardUserDriverWillShowReleaseNotesText(
        _ releaseNotesAttributedString: NSAttributedString,
        forUpdate update: SUAppcastItem,
        withBundleDisplayVersion bundleDisplayVersion: String,
        bundleVersion: String
    ) -> NSAttributedString? {
        guard let targetBuild = Int(update.versionString) else { return nil }
        let installedBuild = Int(bundleVersion) ?? 0
        let diff = UpdateChangelogParser.slice(
            markdown: update.itemDescription,
            installedBuild: installedBuild,
            targetBuild: targetBuild,
            installedVersion: bundleDisplayVersion,
            targetVersion: update.displayVersionString
        )
        guard !diff.isEmpty else { return nil }
        return diff.attributedString()
    }
    private func present(_ action: @escaping () -> Void) {
        let token = generation
        owner?.showWhenIdle { [weak self] in guard self?.generation == token else { return }; action() }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { present { self.standard.show(request, reply: reply) } }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { present { self.standard.showUserInitiatedUpdateCheck(cancellation: cancellation) } }
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let token = generation
        if state.stage != .notDownloaded { owner?.compareWithPublished(item) }
        present { self.standard.showUpdateFound(with: item, state: state) { choice in
            guard self.generation == token else { return }
            guard choice != .install || self.owner?.prepareChoice(item) == true else { reply(.dismiss); return }
            if state.stage == .installing { self.owner?.installChoice(choice, reply: reply) } else { reply(choice) }
        } }
    }
    func showUpdateReleaseNotes(with data: SPUDownloadData) { present { self.standard.showUpdateReleaseNotes(with: data) } }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { present { self.standard.showUpdateReleaseNotesFailedToDownloadWithError(error) } }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { present { self.standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) } }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { present { self.standard.showUpdaterError(error, acknowledgement: acknowledgement) } }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { present { self.standard.showDownloadInitiated(cancellation: cancellation) } }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) { standard.showDownloadDidReceiveExpectedContentLength(length) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { standard.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() { present { self.standard.showDownloadDidStartExtractingUpdate() } }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let token = generation
        present { self.standard.showReady { choice in
            guard self.generation == token else { return }; self.owner?.installChoice(choice, reply: reply)
        } }
    }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication retry: @escaping () -> Void) {
        let token = generation
        present { self.standard.showInstallingUpdate(withApplicationTerminated: terminated) {
            guard self.generation == token, !terminated else { return }
            self.owner?.installChoice(.install) { if $0 == .install { retry() } }
        } }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement) }
    func invalidate() { generation += 1 }
    func dismissUpdateInstallation() { invalidate(); standard.dismissUpdateInstallation() }
}

struct NativeDesktopUpdateBanner: View {
    @ObservedObject var updates: NativeDesktopUpdates
    var body: some View {
        Group {
            if !updates.mayStartMeeting {
                HStack(spacing: 10) {
                    Label(updates.status, systemImage: "arrow.down.circle")
                    Spacer()
                    if updates.recoveryChangelog != nil {
                        Button(L("What's Changed…")) { updates.showingChangelogSheet = true }
                    }
                    Button(L("Finish update…")) { updates.check() }.disabled(!updates.updater.canCheckForUpdates)
                }
                .padding(12)
                .background(.regularMaterial)
            } else if let staged = updates.stagedUpdate, updates.bannerDismissedBuild != staged.build {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Update %@ (%ld) is ready", staged.version, staged.build))
                            .font(.subheadline.weight(.medium))
                        if let summary = staged.diff.bannerSummary() {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(L("What's Changed…")) { updates.showingChangelogSheet = true }
                    Button(L("Restart & Update")) { updates.installStagedUpdate() }
                        .buttonStyle(.borderedProminent)
                    Button(L("Later")) { updates.dismissBannerForCurrentUpdate() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
        }
        .sheet(isPresented: $updates.showingChangelogSheet) {
            NativeDesktopChangelogSheet(updates: updates)
        }
    }
}

struct NativeDesktopChangelogSheet: View {
    @ObservedObject var updates: NativeDesktopUpdates
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(updates.stagedUpdate != nil ? L("Update Ready") : L("What's Changed"))
                        .font(.title3.bold())
                    if let diff = updates.activeChangelog {
                        if diff.installedBuild > 0 {
                            Text("\(diff.installedVersion ?? "?") (\(diff.installedBuild)) → \(diff.targetVersion) (\(diff.targetBuild))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(diff.targetVersion) (\(diff.targetBuild))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }

            if let newer = updates.newerThanDownloaded {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(L("Build %ld is now available.", newer.build))
                        .font(.caption)
                    Spacer()
                    Link(L("Download build %ld", newer.build), destination: newer.url)
                        .font(.caption)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let diff = updates.activeChangelog, !diff.isEmpty {
                        if diff.sections.isEmpty, let fallback = diff.fallbackMarkdown {
                            Text(fallback)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(diff.sections) { section in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(section.date.map { "\(section.version) (\(section.build)) — \($0)" }
                                         ?? "\(section.version) (\(section.build))")
                                        .font(.headline)
                                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("•").foregroundStyle(.secondary)
                                            Text(item)
                                                .font(.callout)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }
                            if diff.hasOlderUnshownChanges, let oldestBuild = diff.sections.last?.build {
                                Text(L("Older release notes before build %ld are omitted.", oldestBuild))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(L("No release notes are available for this update."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(2)
            }
            .frame(minHeight: 200, maxHeight: 360)

            HStack {
                Button(L("Later")) {
                    dismiss()
                    updates.showingChangelogSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if updates.stagedUpdate != nil {
                    Button(L("Restart & Update")) {
                        updates.installStagedUpdate()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

struct NativeDesktopUpdatesView: View {
    @ObservedObject var updates: NativeDesktopUpdates
    var body: some View {
        Form {
            Section(L("Software updates")) {
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                   let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                    LabeledContent(L("Installed version"), value: "\(version) (\(build))").nativeSettingAnchor("settings.version")
                }
                NativeSettingsButton(
                    title: updates.stagedUpdate != nil ? L("Review Pending Update…") : L("Check for Updates…"),
                    id: "settings.check-updates"
                ) {
                    updates.check()
                }
                .disabled(!updates.canTriggerCheckOrReview)
                Text(updates.status).font(.caption).foregroundStyle(.secondary)
                if let newer = updates.newerThanDownloaded {
                    Link(L("Download build %ld", newer.build), destination: newer.url)
                }
            }
            if let staged = updates.stagedUpdate {
                Section(L("Ready to install: %@ (%ld)", staged.version, staged.build)) {
                    if !staged.diff.sections.isEmpty {
                        ForEach(staged.diff.sections) { section in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.date.map { "\(section.version) (\(section.build)) — \($0)" }
                                     ?? "\(section.version) (\(section.build))")
                                    .font(.subheadline.weight(.semibold))
                                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(item).font(.caption)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } else if let fallback = staged.diff.fallbackMarkdown, !fallback.isEmpty {
                        Text(fallback).font(.caption)
                    } else {
                        Text(L("No release notes are available for this update.")).font(.caption).foregroundStyle(.secondary)
                    }
                    NativeSettingsButton(title: L("Restart & Update"), id: "settings.restart-update") {
                        updates.installStagedUpdate()
                    }
                }
            }
            Section(L("Automatic updates")) {
                NativeSettingsSwitch(
                    title: L("Automatically check for updates"),
                    isOn: Binding(get: { updates.updater.automaticallyChecksForUpdates }, set: {
                        updates.updater.automaticallyChecksForUpdates = $0
                        updates.objectWillChange.send()
                    }),
                    id: "settings.update-check"
                )
                NativeSettingsSwitch(
                    title: L("Automatically download updates"),
                    isOn: Binding(get: { updates.updater.automaticallyDownloadsUpdates }, set: {
                        updates.updater.automaticallyDownloadsUpdates = $0
                        updates.objectWillChange.send()
                    }),
                    id: "settings.update-download"
                )
            }
            Section(L("Release channel")) {
                NativeSettingsPopup(
                    title: L("Release channel"),
                    selection: Binding(get: { updates.beta }, set: { updates.setBeta($0) }),
                    choices: [false, true],
                    titleForChoice: { $0 ? L("Beta") : L("Stable") },
                    id: "settings.update-channel"
                )
                .disabled(updates.channelLocked)
                if updates.channelLocked {
                    Text(L("The release channel cannot be changed while an update is in progress.")).font(.caption).foregroundStyle(.secondary)
                }
                Text(L("Beta updates include early changes. Turning this off waits for a newer stable release; it does not downgrade your app.")).font(.caption).foregroundStyle(.secondary)
            }
            NativeDesktopChangelogHistorySection(updates: updates)
        }.nativeSettingsReveal().formStyle(.grouped)
    }
}

private struct NativeDesktopChangelogHistorySection: View {
    @ObservedObject var updates: NativeDesktopUpdates
    @State private var filterQuery = ""
    @State private var channelFilter: UpdateChangelogLedger.ChannelFilter = .all
    @State private var visibleLimit = 10

    private var hasChannelMetadata: Bool {
        updates.changelogHistory.contains { $0.channel != nil }
    }

    private var filteredSections: [UpdateChangelogSection] {
        UpdateChangelogLedger.filter(updates.changelogHistory, channel: channelFilter, query: filterQuery)
    }

    var body: some View {
        let filtered = filteredSections
        let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = trimmed.isEmpty ? visibleLimit : max(visibleLimit, 50)
        let displayed = Array(filtered.prefix(cap))
        Section(L("Release notes")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        TextField(L("Filter release notes…"), text: $filterQuery)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("settings.changelog.filter")
                        if !filterQuery.isEmpty {
                            Button {
                                filterQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("Clear filters"))
                        }
                    }
                    if hasChannelMetadata {
                        Picker(L("Channel"), selection: $channelFilter) {
                            Text(L("All")).tag(UpdateChangelogLedger.ChannelFilter.all)
                            Text(L("Stable")).tag(UpdateChangelogLedger.ChannelFilter.stable)
                            Text(L("Beta")).tag(UpdateChangelogLedger.ChannelFilter.beta)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("settings.changelog.channel")
                    }
                }
            }
            .nativeSettingAnchor("settings.changelog")
            .onAppear {
                updates.ensureChangelogHistoryLoaded()
            }
            .onChange(of: channelFilter) { _ in
                visibleLimit = 10
            }
            .onChange(of: filterQuery) { _ in
                visibleLimit = 10
            }

            if updates.changelogHistory.isEmpty {
                Text(L("No release notes available."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if filtered.isEmpty {
                Text(L("No matching release notes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayed) { section in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(section.date.map { "\(section.version) (\(section.build)) — \($0)" }
                                 ?? "\(section.version) (\(section.build))")
                                .font(.subheadline.weight(.semibold))
                            if section.build == updates.installedBuild {
                                changelogBadge(L("Installed"), foreground: Color.accentColor, background: Color.accentColor.opacity(0.16), emphasized: true)
                            } else if updates.installedBuild > 0,
                                      let available = updates.availableChangelogBuild,
                                      section.build > updates.installedBuild,
                                      section.build <= available {
                                changelogBadge(L("Available"), foreground: .green, background: Color.green.opacity(0.16), emphasized: true)
                            }
                            if section.channel == "beta" {
                                changelogBadge(L("Beta"), foreground: .secondary, background: Color.secondary.opacity(0.14), emphasized: false)
                            } else if section.channel == "stable" {
                                changelogBadge(L("Stable"), foreground: .secondary, background: Color.secondary.opacity(0.14), emphasized: false)
                            }
                        }
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(item)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }

                if filtered.count > displayed.count {
                    HStack(spacing: 12) {
                        Button(L("Show more (%ld remaining)", filtered.count - displayed.count)) {
                            visibleLimit = displayed.count + 20
                        }
                        Button(L("Show all (%ld)", filtered.count)) {
                            visibleLimit = filtered.count
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func changelogBadge(_ title: String, foreground: Color, background: Color, emphasized: Bool) -> some View {
        Text(title)
            .font(emphasized ? .caption2.weight(.medium) : .caption2)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }
}
#endif

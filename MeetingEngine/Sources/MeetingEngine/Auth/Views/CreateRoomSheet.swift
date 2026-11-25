import ConferenceCore
import Foundation
import SwiftUI

public struct CreateRoomSheet: View {
    private enum SignInRequest: Identifiable {
        case origin(URL)
        case newSite

        var id: String {
            switch self {
            case .origin(let url): return "origin:\(url.absoluteString)"
            case .newSite: return "newSite"
            }
        }
    }

    private static var lastOriginKey: String { InstantRoomPreferences.lastOriginKey }

    public let initialOrigin: URL?
    public let suggestedOrigins: [URL]
    public let defaultDisplayName: String
    public let onJoinCreatedRoom: @MainActor (CreatedMeetingRoom, Bool) -> Void
    public let onSaveFavoriteOnly: (@MainActor (CreatedMeetingRoom) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SiteAccountStore.shared

    @State private var sitePickerValue: String = "__custom__"
    @State private var customOriginText: String = ""
    @State private var selectedEngineOverride: MeetingEngineKind?

    @State private var roomTitle: String = ""
    @State private var allowGuests = true
    @State private var enableLobby = false
    @State private var saveToFavorites = false

    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var signInRequiredOrigin: URL?
    @State private var signInRequest: SignInRequest?
    @State private var retryAfterSignInJoin = false
    @State private var lastAttemptJoinImmediately = true
    @State private var createdRoom: CreatedMeetingRoom?
    @State private var copiedFeedback = false

    public init(
        initialOrigin: URL? = nil,
        suggestedOrigins: [URL] = [],
        defaultDisplayName: String = "",
        onJoinCreatedRoom: @escaping @MainActor (CreatedMeetingRoom, Bool) -> Void,
        onSaveFavoriteOnly: (@MainActor (CreatedMeetingRoom) -> Void)? = nil
    ) {
        self.initialOrigin = initialOrigin
        self.suggestedOrigins = suggestedOrigins
        self.defaultDisplayName = defaultDisplayName
        self.onJoinCreatedRoom = onJoinCreatedRoom
        self.onSaveFavoriteOnly = onSaveFavoriteOnly
    }

    private var availableSites: [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        var candidates: [URL] = []
        if let initialOrigin { candidates.append(initialOrigin) }
        for account in store.accounts where account.engine != .community {
            if let url = account.originURL { candidates.append(url) }
        }
        candidates.append(contentsOf: suggestedOrigins)
        for url in candidates {
            guard let canonical = SiteOrigin.canonicalOrigin(for: url) else { continue }
            if seen.insert(canonical.absoluteString).inserted {
                result.append(canonical)
            }
        }
        return result
    }

    private var useCustomOrigin: Bool {
        sitePickerValue == "__custom__"
    }

    private var activeOrigin: URL? {
        if useCustomOrigin {
            return SiteOrigin.normalize(customOriginText)
        }
        return SiteOrigin.normalize(sitePickerValue)
    }

    private var activeAccount: SiteAccountRecord? {
        activeOrigin.flatMap { store.account(for: $0) }
    }

    private var effectiveEngine: MeetingEngineKind? {
        if let selectedEngineOverride { return selectedEngineOverride }
        if let account = activeAccount { return account.engine }
        if let host = activeOrigin?.host?.lowercased(), TelemostTarget.hosts.contains(host) { return .telemost }
        return nil
    }

    public var body: some View {
        Group {
            #if os(macOS)
            VStack(spacing: 0) {
                HStack {
                    Text(L("New room"))
                        .font(.headline)
                    Spacer()
                    Button(createdRoom == nil ? L("Cancel") : L("Done")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                roomFormContent
                    .formStyle(.grouped)
            }
            .frame(minWidth: 520, idealWidth: 560, minHeight: 460, idealHeight: 520)
            #else
            NavigationStack {
                roomFormContent
                    .navigationTitle(L("New room"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(createdRoom == nil ? L("Cancel") : L("Done")) { dismiss() }
                        }
                    }
            }
            #endif
        }
        .onAppear {
            initializeOriginSelection()
        }
        .sheet(item: $signInRequest) { request in
            switch request {
            case .origin(let url):
                SiteSignInSheet(initialOrigin: url, suggestedOrigins: suggestedOrigins) { account in
                    handleSignedIn(account)
                }
            case .newSite:
                SiteSignInSheet(initialOrigin: nil, suggestedOrigins: suggestedOrigins) { account in
                    handleSignedIn(account)
                }
            }
        }
    }

    private var roomFormContent: some View {
        Form {
            if let created = createdRoom {
                createdSection(created)
            } else {
                siteSelectionSection
                roomOptionsSection
                errorAndActionsSection
            }
        }
    }

    private var siteSelectionSection: some View {
        Section {
            Picker(L("Website"), selection: $sitePickerValue) {
                ForEach(availableSites, id: \.absoluteString) { origin in
                    let account = store.account(for: origin)
                    let host = origin.host ?? origin.absoluteString
                    let label = account.map { "\(host) · \($0.displayAccountSummary)" } ?? host
                    Text(label).tag(origin.absoluteString)
                }
                Text(L("Another website…")).tag("__custom__")
            }
            .accessibilityIdentifier("createRoom.site")
            .onChange(of: sitePickerValue) { value in
                errorMessage = nil
                signInRequiredOrigin = nil
                if value != "__custom__" {
                    selectedEngineOverride = nil
                    UserDefaults.standard.set(value, forKey: Self.lastOriginKey)
                }
            }

            if useCustomOrigin {
                TextField("https://meetings.example.com", text: $customOriginText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                Picker(L("Service"), selection: $selectedEngineOverride) {
                    Text(L("Auto-detect")).tag(MeetingEngineKind?.none)
                    Text(SiteAuthEngineLabel.title(for: .trueconf)).tag(MeetingEngineKind?.some(.trueconf))
                    Text(SiteAuthEngineLabel.title(for: .telemost)).tag(MeetingEngineKind?.some(.telemost))
                }
            }

            if let account = activeAccount {
                HStack {
                    Label(
                        account.needsReauthentication
                            ? L("Session expired for %@", account.hostDisplayName)
                            : L("Signed in as %@", account.displayAccountSummary),
                        systemImage: account.needsReauthentication ? "exclamationmark.triangle" : "person.crop.circle.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(account.needsReauthentication ? .orange : .secondary)
                    Spacer()
                    Button(account.needsReauthentication ? L("Sign in…") : L("Switch…")) {
                        if let origin = activeOrigin {
                            retryAfterSignInJoin = false
                            signInRequest = .origin(origin)
                        }
                    }
                    .font(.caption)
                }
            } else if let origin = activeOrigin {
                HStack {
                    Text(L("Not signed in on %@", origin.host ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Sign in…")) {
                        retryAfterSignInJoin = false
                        signInRequest = .origin(origin)
                    }
                    .font(.caption)
                }
            }

            Button {
                retryAfterSignInJoin = false
                signInRequest = .newSite
            } label: {
                Label(L("Sign in to another website…"), systemImage: "person.badge.plus")
            }
        } header: {
            Text(L("Meeting website"))
        }
    }

    private var roomOptionsSection: some View {
        Section(L("Room details")) {
            TextField(defaultTitlePlaceholder, text: $roomTitle)
                .accessibilityIdentifier("createRoom.title")
            Toggle(L("Allow guests by link"), isOn: $allowGuests)
            if effectiveEngine == .guest && activeAccount?.isSignedIn == true {
                Toggle(L("Enable waiting room (lobby)"), isOn: $enableLobby)
            }
            Toggle(L("Save to Favorites"), isOn: $saveToFavorites)
        }
    }

    private var errorAndActionsSection: some View {
        Section {
            if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    if let required = signInRequiredOrigin {
                        Button {
                            retryAfterSignInJoin = true
                            signInRequest = .origin(required)
                        } label: {
                            Label(L("Sign in to %@…", required.host ?? required.absoluteString), systemImage: "person.badge.key")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("createRoom.signIn")
                    }
                }
            }

            Button {
                Task { await submit(joinImmediately: true) }
            } label: {
                HStack {
                    if isCreating { ProgressView().controlSize(.small) }
                    Text(isCreating ? L("Creating room…") : L("Create & Join"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCreating || activeOrigin == nil)
            .accessibilityIdentifier("createRoom.createAndJoin")

            Button {
                Task { await submit(joinImmediately: false) }
            } label: {
                Text(L("Create & Copy Link"))
                    .frame(maxWidth: .infinity)
            }
            .disabled(isCreating || activeOrigin == nil)
            .accessibilityIdentifier("createRoom.createOnly")
        }
    }

    private func createdSection(_ created: CreatedMeetingRoom) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(created.title)
                    .font(.headline)
                Text(created.invitationURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if copiedFeedback {
                    Label(L("Invitation link copied to clipboard"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)

            Button {
                onJoinCreatedRoom(created, saveToFavorites)
                dismiss()
            } label: {
                Label(L("Join Now"), systemImage: "video.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                SiteAuthClipboard.copy(created.invitationURL.absoluteString)
                copiedFeedback = true
            } label: {
                Label(L("Copy Link"), systemImage: "doc.on.doc")
            }

            ShareLink(item: created.invitationURL) {
                Label(L("Share Invitation…"), systemImage: "square.and.arrow.up")
            }
        } header: {
            Text(L("Room ready"))
        }
    }

    private var defaultTitlePlaceholder: String {
        let clean = defaultDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? L("Room name (optional)") : L("%@’s meeting", clean)
    }

    private func initializeOriginSelection() {
        let preferred = initialOrigin.flatMap { SiteOrigin.canonicalOrigin(for: $0) }
            ?? UserDefaults.standard.string(forKey: Self.lastOriginKey).flatMap { SiteOrigin.normalize($0) }
            ?? availableSites.first
        if let preferred {
            if availableSites.contains(preferred) {
                sitePickerValue = preferred.absoluteString
            } else {
                customOriginText = preferred.absoluteString
                sitePickerValue = "__custom__"
            }
        } else if availableSites.isEmpty {
            sitePickerValue = "__custom__"
        }
    }

    private func handleSignedIn(_ account: SiteAccountRecord) {
        if let url = account.originURL {
            sitePickerValue = url.absoluteString
            selectedEngineOverride = account.engine
            UserDefaults.standard.set(url.absoluteString, forKey: Self.lastOriginKey)
        }
        errorMessage = nil
        signInRequiredOrigin = nil
        if retryAfterSignInJoin {
            retryAfterSignInJoin = false
            Task { await submit(joinImmediately: lastAttemptJoinImmediately) }
        }
    }

    private func submit(joinImmediately: Bool) async {
        lastAttemptJoinImmediately = joinImmediately
        guard let origin = activeOrigin else {
            errorMessage = RoomCreationError.invalidSiteURL.localizedDescription
            return
        }
        isCreating = true
        errorMessage = nil
        signInRequiredOrigin = nil
        defer { isCreating = false }

        let fallbackTitle = defaultDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L("New meeting")
            : L("%@’s meeting", defaultDisplayName.trimmingCharacters(in: .whitespacesAndNewlines))
        let chosenTitle = roomTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackTitle : roomTitle

        do {
            let created = try await MeetingRoomCreator(auth: .shared).createRoom(
                on: origin,
                engine: useCustomOrigin ? selectedEngineOverride : effectiveEngine,
                options: RoomCreationOptions(
                    title: chosenTitle,
                    allowGuests: allowGuests,
                    enableLobby: enableLobby
                )
            )
            UserDefaults.standard.set(origin.absoluteString, forKey: Self.lastOriginKey)
            SiteAuthClipboard.copy(created.invitationURL.absoluteString)
            if joinImmediately {
                onJoinCreatedRoom(created, saveToFavorites)
                dismiss()
            } else {
                if saveToFavorites {
                    onSaveFavoriteOnly?(created)
                }
                copiedFeedback = true
                createdRoom = created
            }
        } catch {
            if let challengeOrigin = SiteAuthError.challengeOrigin(from: error, attemptedURL: origin, store: store) {
                signInRequiredOrigin = challengeOrigin
            }
            errorMessage = error.localizedDescription
        }
    }
}

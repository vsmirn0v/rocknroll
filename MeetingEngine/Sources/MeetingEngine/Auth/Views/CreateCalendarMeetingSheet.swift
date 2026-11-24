import ConferenceCore
import Foundation
import SwiftUI

public struct FavoriteRoomOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let invitationURL: URL

    public init(id: String, title: String, invitationURL: URL) {
        self.id = id
        self.title = title
        self.invitationURL = invitationURL
    }
}

public enum CalendarMeetingLinkMode: String, CaseIterable, Identifiable {
    case autoCreateRoom
    case customLink

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .autoCreateRoom: return L("Create new room")
        case .customLink: return L("Custom link")
        }
    }
}

public struct CreateCalendarMeetingSheet: View {
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

    private static let lastOriginKey = "siteAuth.lastCreateRoomOrigin"

    public let initialDate: Date
    public let suggestedOrigins: [URL]
    public let favoriteRooms: [FavoriteRoomOption]
    public let preferredCalendarIDs: Set<String>
    public let defaultDisplayName: String
    public let writer: any CalendarMeetingWriting
    public let onOpenCalendarSettings: (() -> Void)?
    public let onCreated: @MainActor (CreatedCalendarEventResult, CreatedMeetingRoom?, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SiteAccountStore.shared

    @State private var title: String = ""
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var durationMinutes: Int = 30
    @State private var writableCalendars: [WritableEventCalendarInfo] = []
    @State private var selectedCalendarID: String = ""
    @State private var loadingCalendars = false
    @State private var calendarPermissionDenied = false
    @State private var calendarLoadError: String?
    @State private var alarmMinutes: Int? = 10

    @State private var linkMode: CalendarMeetingLinkMode = .autoCreateRoom

    // Auto-create room state
    @State private var sitePickerValue: String = "__custom__"
    @State private var customOriginText: String = ""
    @State private var selectedEngineOverride: MeetingEngineKind?
    @State private var allowGuests = true
    @State private var enableLobby = false
    @State private var saveToFavorites = false
    @State private var signInRequiredOrigin: URL?
    @State private var signInRequest: SignInRequest?
    @State private var retryAfterSignIn = false
    @State private var createdRoom: CreatedMeetingRoom?
    @State private var copiedFeedback = false

    // Custom link state
    @State private var customLinkText: String = ""
    @State private var notes: String = ""

    @State private var isSaving = false
    @State private var errorMessage: String?

    public init(
        initialDate: Date = Date(),
        suggestedOrigins: [URL] = [],
        favoriteRooms: [FavoriteRoomOption] = [],
        preferredCalendarIDs: Set<String> = [],
        defaultDisplayName: String = "",
        writer: any CalendarMeetingWriting = CalendarMeetingWriter(),
        onOpenCalendarSettings: (() -> Void)? = nil,
        onCreated: @escaping @MainActor (CreatedCalendarEventResult, CreatedMeetingRoom?, Bool) -> Void
    ) {
        self.initialDate = initialDate
        self.suggestedOrigins = suggestedOrigins
        self.favoriteRooms = favoriteRooms
        self.preferredCalendarIDs = preferredCalendarIDs
        self.defaultDisplayName = defaultDisplayName
        self.writer = writer
        self.onOpenCalendarSettings = onOpenCalendarSettings
        self.onCreated = onCreated

        let defaultStart = Self.defaultStartDate(for: initialDate)
        _startDate = State(initialValue: defaultStart)
        _endDate = State(initialValue: defaultStart.addingTimeInterval(30 * 60))
    }

    private static func defaultStartDate(for date: Date, calendar: Calendar = .current) -> Date {
        let now = Date()
        if calendar.isDate(date, inSameDayAs: now) {
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
            let minute = comps.minute ?? 0
            let nextQuarter = ((minute / 15) + 1) * 15
            let base = calendar.date(bySetting: .minute, value: 0, of: now) ?? now
            return calendar.date(byAdding: .minute, value: nextQuarter, to: base) ?? now.addingTimeInterval(900)
        }
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: date) ?? date
    }

    private var availableSites: [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        for account in store.accounts where account.engine != .community {
            if let url = account.originURL, let canonical = SiteOrigin.canonicalOrigin(for: url),
               seen.insert(canonical.absoluteString).inserted {
                result.append(canonical)
            }
        }
        for url in suggestedOrigins {
            if let canonical = SiteOrigin.canonicalOrigin(for: url),
               seen.insert(canonical.absoluteString).inserted {
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
                    Text(L("New meeting"))
                        .font(.headline)
                    Spacer()
                    Button(L("Cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                formContent
                    .formStyle(.grouped)
            }
            .frame(minWidth: 540, idealWidth: 580, minHeight: 540, idealHeight: 620)
            #else
            NavigationStack {
                formContent
                    .navigationTitle(L("New meeting"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L("Cancel")) { dismiss() }
                        }
                    }
            }
            #endif
        }
        .onAppear {
            initializeRoomModeAndOrigin()
        }
        .task {
            await loadWritableCalendars()
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

    private var formContent: some View {
        Form {
            detailsSection
            calendarSection
            roomSection
            notesSection
            if let createdRoom {
                createdRoomRecoverySection(createdRoom)
            }
            submitSection
        }
    }

    private var detailsSection: some View {
        Section(L("Meeting details")) {
            TextField(L("New meeting"), text: $title)
                .accessibilityIdentifier("createCalendarMeeting.title")

            DatePicker(L("Starts"), selection: $startDate)
                .onChange(of: startDate) { newStart in
                    endDate = newStart.addingTimeInterval(TimeInterval(max(5, durationMinutes) * 60))
                }

            Picker(L("Duration"), selection: $durationMinutes) {
                Text(L("15 min")).tag(15)
                Text(L("30 min")).tag(30)
                Text(L("45 min")).tag(45)
                Text(L("60 min")).tag(60)
                if ![15, 30, 45, 60].contains(durationMinutes) {
                    Text(L("%ld min", durationMinutes)).tag(durationMinutes)
                }
            }
            .onChange(of: durationMinutes) { minutes in
                endDate = startDate.addingTimeInterval(TimeInterval(max(5, minutes) * 60))
            }

            DatePicker(L("Ends"), selection: $endDate, in: startDate.addingTimeInterval(300)...)
                .onChange(of: endDate) { newEnd in
                    let computed = max(5, Int((newEnd.timeIntervalSince(startDate) / 60).rounded()))
                    if computed != durationMinutes {
                        durationMinutes = computed
                    }
                }
        }
    }

    private var calendarSection: some View {
        Section(L("Calendar")) {
            if loadingCalendars {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Checking calendar…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if calendarPermissionDenied {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Calendar access is disabled. Allow Calendar access in System Settings or Settings app."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    HStack {
                        if let onOpenCalendarSettings {
                            Button(L("Review calendar access")) {
                                dismiss()
                                onOpenCalendarSettings()
                            }
                        }
                        Button(L("Try Again")) {
                            Task { await loadWritableCalendars() }
                        }
                    }
                    .font(.caption)
                }
            } else if let calendarLoadError {
                Text(calendarLoadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if writableCalendars.isEmpty {
                Text(L("No writable calendar is available on this device."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker(L("Calendar"), selection: $selectedCalendarID) {
                    ForEach(writableCalendars) { item in
                        Text("\(item.title) (\(item.sourceTitle))").tag(item.id)
                    }
                }
            }

            Picker(L("Calendar reminder"), selection: $alarmMinutes) {
                Text(L("None")).tag(Int?.none)
                Text(L("5 min before")).tag(Int?.some(5))
                Text(L("10 min before")).tag(Int?.some(10))
                Text(L("15 min before")).tag(Int?.some(15))
                Text(L("30 min before")).tag(Int?.some(30))
            }
        }
    }

    private var roomSection: some View {
        Section(L("Meeting room")) {
            Picker(L("Room source"), selection: $linkMode) {
                ForEach(CalendarMeetingLinkMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(createdRoom != nil)

            if linkMode == .autoCreateRoom {
                Picker(L("Website"), selection: $sitePickerValue) {
                    ForEach(availableSites, id: \.absoluteString) { origin in
                        let account = store.account(for: origin)
                        let host = origin.host ?? origin.absoluteString
                        let label = account.map { "\(host) · \($0.displayAccountSummary)" } ?? host
                        Text(label).tag(origin.absoluteString)
                    }
                    Text(L("Another website…")).tag("__custom__")
                }
                .disabled(createdRoom != nil)
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
                        .disabled(createdRoom != nil)
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
                    .disabled(createdRoom != nil)
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
                                retryAfterSignIn = false
                                signInRequest = .origin(origin)
                            }
                        }
                        .font(.caption)
                        .disabled(createdRoom != nil)
                    }
                } else if let origin = activeOrigin {
                    HStack {
                        Text(L("Not signed in on %@", origin.host ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Sign in…")) {
                            retryAfterSignIn = false
                            signInRequest = .origin(origin)
                        }
                        .font(.caption)
                        .disabled(createdRoom != nil)
                    }
                }

                Button {
                    retryAfterSignIn = false
                    signInRequest = .newSite
                } label: {
                    Label(L("Sign in to another website…"), systemImage: "person.badge.plus")
                }
                .disabled(createdRoom != nil)

                Toggle(L("Allow guests by link"), isOn: $allowGuests)
                    .disabled(createdRoom != nil)
                if effectiveEngine == .guest && activeAccount?.isSignedIn == true {
                    Toggle(L("Enable waiting room (lobby)"), isOn: $enableLobby)
                        .disabled(createdRoom != nil)
                }
                Toggle(L("Save to Favorites"), isOn: $saveToFavorites)
            } else {
                TextField(L("Invitation link (optional)"), text: $customLinkText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                if !favoriteRooms.isEmpty {
                    Menu {
                        ForEach(favoriteRooms) { room in
                            Button(room.title) {
                                customLinkText = room.invitationURL.absoluteString
                                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    title = room.title
                                }
                            }
                        }
                    } label: {
                        Label(L("Choose from Favorites"), systemImage: "star")
                    }
                }
                Text(L("Paste any meeting link, pick from Favorites, or leave blank for an event without a link."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notesSection: some View {
        Section(L("Agenda / notes")) {
            TextField(L("Agenda or meeting notes (optional)"), text: $notes, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    private func createdRoomRecoverySection(_ room: CreatedMeetingRoom) -> some View {
        Section(L("Room ready")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(room.title)
                    .font(.subheadline.weight(.semibold))
                Text(room.invitationURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if copiedFeedback {
                    Label(L("Invitation link copied to clipboard"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                HStack {
                    Button {
                        SiteAuthClipboard.copy(room.invitationURL.absoluteString)
                        copiedFeedback = true
                    } label: {
                        Label(L("Copy invitation link"), systemImage: "doc.on.doc")
                    }
                    Spacer()
                    Button(L("Reset room")) {
                        createdRoom = nil
                        copiedFeedback = false
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var submitSection: some View {
        Section {
            if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    if let required = signInRequiredOrigin {
                        Button {
                            retryAfterSignIn = true
                            signInRequest = .origin(required)
                        } label: {
                            Label(L("Sign in to %@…", required.host ?? required.absoluteString), systemImage: "person.badge.key")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            Button {
                Task { await submit() }
            } label: {
                HStack {
                    if isSaving { ProgressView().controlSize(.small) }
                    Text(buttonLabel)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitDisabled)
            .accessibilityIdentifier("createCalendarMeeting.submit")
        }
    }

    private var buttonLabel: String {
        if isSaving { return L("Creating meeting…") }
        if createdRoom != nil { return L("Retry saving to Calendar") }
        return L("Create meeting")
    }

    private var isSubmitDisabled: Bool {
        if isSaving || calendarPermissionDenied || writableCalendars.isEmpty {
            return true
        }
        if linkMode == .autoCreateRoom && createdRoom == nil && activeOrigin == nil {
            return true
        }
        return false
    }

    private func initializeRoomModeAndOrigin() {
        let preferred = UserDefaults.standard.string(forKey: Self.lastOriginKey).flatMap { SiteOrigin.normalize($0) }
            ?? availableSites.first
        if let preferred {
            if availableSites.contains(preferred) {
                sitePickerValue = preferred.absoluteString
            } else {
                customOriginText = preferred.absoluteString
                sitePickerValue = "__custom__"
            }
        } else {
            sitePickerValue = "__custom__"
            if availableSites.isEmpty {
                linkMode = .customLink
            }
        }
    }

    private func loadWritableCalendars() async {
        loadingCalendars = true
        calendarLoadError = nil
        calendarPermissionDenied = false
        defer { loadingCalendars = false }
        do {
            let list = try await writer.requestAccessAndFetchWritableCalendars()
            writableCalendars = list
            if selectedCalendarID.isEmpty || !list.contains(where: { $0.id == selectedCalendarID }) {
                selectedCalendarID = list.first(where: { preferredCalendarIDs.contains($0.id) })?.id
                    ?? list.first?.id
                    ?? ""
            }
        } catch CalendarMeetingWriteError.permissionDenied {
            calendarPermissionDenied = true
        } catch {
            calendarLoadError = error.localizedDescription
        }
    }

    private func handleSignedIn(_ account: SiteAccountRecord) {
        if let url = account.originURL {
            let canonical = SiteOrigin.canonicalOrigin(for: url) ?? url
            sitePickerValue = canonical.absoluteString
            selectedEngineOverride = account.engine
            UserDefaults.standard.set(canonical.absoluteString, forKey: Self.lastOriginKey)
        }
        errorMessage = nil
        signInRequiredOrigin = nil
        if retryAfterSignIn {
            retryAfterSignIn = false
            Task { await submit() }
        }
    }

    private func resolvedCustomLink() throws -> URL? {
        let trimmed = customLinkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = try? JoinTarget.parse(trimmed) {
            return parsed.invitationURL
        }
        if let candidate = URL(string: trimmed),
           let scheme = candidate.scheme?.lowercased(),
           ["https", "http"].contains(scheme),
           candidate.host?.isEmpty == false {
            return candidate
        }
        if !trimmed.contains("://"),
           let candidate = URL(string: "https://" + trimmed),
           candidate.host?.contains(".") == true {
            return candidate
        }
        throw RoomCreationError.invalidSiteURL
    }

    private func submit() async {
        errorMessage = nil
        signInRequiredOrigin = nil
        guard endDate > startDate else {
            errorMessage = CalendarMeetingWriteError.invalidDateRange.localizedDescription
            return
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = defaultDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L("New meeting")
            : L("%@’s meeting", defaultDisplayName.trimmingCharacters(in: .whitespacesAndNewlines))
        let chosenTitle = cleanTitle.isEmpty ? fallbackTitle : cleanTitle

        isSaving = true
        defer { isSaving = false }

        let finalMeetingURL: URL?
        if linkMode == .autoCreateRoom {
            if let existing = createdRoom {
                finalMeetingURL = existing.invitationURL
            } else {
                guard let origin = activeOrigin else {
                    errorMessage = RoomCreationError.invalidSiteURL.localizedDescription
                    return
                }
                do {
                    let room = try await MeetingRoomCreator(auth: .shared).createRoom(
                        on: origin,
                        engine: useCustomOrigin ? selectedEngineOverride : effectiveEngine,
                        options: RoomCreationOptions(
                            title: chosenTitle,
                            allowGuests: allowGuests,
                            enableLobby: enableLobby
                        )
                    )
                    UserDefaults.standard.set(origin.absoluteString, forKey: Self.lastOriginKey)
                    SiteAuthClipboard.copy(room.invitationURL.absoluteString)
                    copiedFeedback = true
                    createdRoom = room
                    finalMeetingURL = room.invitationURL
                } catch {
                    if let challengeOrigin = SiteAuthError.challengeOrigin(from: error, attemptedURL: origin, store: store) {
                        signInRequiredOrigin = challengeOrigin
                    }
                    errorMessage = error.localizedDescription
                    return
                }
            }
        } else {
            do {
                finalMeetingURL = try resolvedCustomLink()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        do {
            let draft = CalendarMeetingDraft(
                calendarIdentifier: selectedCalendarID.isEmpty ? nil : selectedCalendarID,
                title: chosenTitle,
                startAt: startDate,
                endAt: endDate,
                meetingURL: finalMeetingURL,
                notes: notes,
                alarmOffsetMinutesBefore: alarmMinutes
            )
            let result = try await writer.createEvent(draft)
            onCreated(result, createdRoom, linkMode == .autoCreateRoom ? saveToFavorites : false)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

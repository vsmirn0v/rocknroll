import ConferenceCore
import Foundation
import SwiftUI

public struct RoomPoolSheet: View {
    public let initialPool: RoomPoolRecord?
    public let onPoolConfigured: (@MainActor (RoomPoolRecord) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var poolStore = RoomPoolStore.shared
    @ObservedObject private var accountStore = SiteAccountStore.shared

    @State private var coordinationLinkText: String = ""
    @State private var writeTokenText: String = ""
    @State private var newPoolIDText: String = ""
    @State private var newPoolLabelText: String = ""

    @State private var bulkLinksText: String = ""
    @State private var selectedGeneratorOrigin: String = ""
    @State private var generateCount: Int = 5

    @State private var activeStatus: RoomPoolStatus?
    @State private var queuedLinks: [QueuedPoolLink] = []
    @State private var hasLoadedQueuedLinks = false

    @State private var isBusy = false
    @State private var infoMessage: String?
    @State private var errorMessage: String?
    @State private var showCreateNewPool = false

    private let client = RoomPoolClient()

    public init(
        initialPool: RoomPoolRecord? = nil,
        onPoolConfigured: (@MainActor (RoomPoolRecord) -> Void)? = nil
    ) {
        self.initialPool = initialPool
        self.onPoolConfigured = onPoolConfigured
    }

    private var signedInGuestAccounts: [SiteAccountRecord] {
        accountStore.accounts.filter { $0.engine == .guest && !$0.needsReauthentication }
    }

    private var parsedLink: RoomPoolLink? {
        RoomPoolLink.parseOptional(coordinationLinkText)
    }

    private var currentRecord: RoomPoolRecord? {
        if let parsed = parsedLink {
            return poolStore.pools.first(where: { $0.poolKey == parsed.poolKey })
        }
        return initialPool ?? poolStore.activePool
    }

    public var body: some View {
        Group {
            #if os(macOS)
            VStack(spacing: 0) {
                HStack {
                    Text(L("Room coordination pool"))
                        .font(.headline)
                    Spacer()
                    Button(L("Done")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                formContent
                    .formStyle(.grouped)
            }
            .frame(minWidth: 520, idealWidth: 580, minHeight: 500, idealHeight: 620)
            #else
            NavigationStack {
                formContent
                    .navigationTitle(L("Room coordination pool"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L("Done")) { dismiss() }
                        }
                    }
            }
            #endif
        }
        .onAppear {
            initializeFields()
        }
    }

    private var formContent: some View {
        Form {
            if !poolStore.pools.isEmpty {
                savedPoolsSection
            }
            coordinationLinkSection
            if parsedLink != nil || currentRecord != nil {
                manageLinksSection
            }
            createPoolSection
            if errorMessage != nil || infoMessage != nil {
                Section {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let infoMessage {
                        Text(infoMessage)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private var savedPoolsSection: some View {
        Section(L("Saved pools")) {
            ForEach(poolStore.pools) { pool in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(pool.displayTitle)
                                .font(.subheadline.weight(.semibold))
                            if pool.poolKey == poolStore.activePool?.poolKey {
                                Text(L("Active"))
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }
                        let countText = pool.lastKnownAvailable.map { L("%ld available", $0) } ?? L("Status unknown")
                        Text("\(pool.serviceOrigin) · \(countText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if pool.poolKey != poolStore.activePool?.poolKey {
                        Button(L("Use")) {
                            selectPool(pool)
                        }
                        .font(.caption)
                    }
                    Button(role: .destructive) {
                        poolStore.removePool(poolKey: pool.poolKey)
                        if parsedLink?.poolKey == pool.poolKey {
                            coordinationLinkText = poolStore.activePool.flatMap { poolStore.link(for: $0)?.canonicalURL.absoluteString } ?? ""
                            activeStatus = nil
                            queuedLinks = []
                            hasLoadedQueuedLinks = false
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var coordinationLinkSection: some View {
        Section {
            TextField("https://rock.glowsoft.ru/pools/363636#auth=...", text: $coordinationLinkText)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif
                .accessibilityIdentifier("roomPool.linkField")

            if let status = activeStatus {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(status.label.isEmpty ? L("Pool %@", status.poolID) : "\(status.poolID) · \(status.label)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(L("%ld unused · %ld used", status.availableCount, status.usedCount))
                            .font(.caption)
                            .foregroundStyle(status.availableCount > 0 ? Color.green : Color.orange)
                    }
                    if !status.origins.isEmpty {
                        Text(
                            status.origins
                                .sorted { $0.key < $1.key }
                                .map { "\($0.key.replacingOccurrences(of: "https://", with: "")): \($0.value)" }
                                .joined(separator: " · ")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                Task { await saveAndUsePool() }
            } label: {
                HStack {
                    if isBusy { ProgressView().controlSize(.small) }
                    Text(onPoolConfigured != nil ? L("Save & Use Pool") : L("Verify & Save Pool"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || parsedLink == nil)
            .accessibilityIdentifier("roomPool.saveAndUse")

            if let link = parsedLink {
                Button {
                    SiteAuthClipboard.copy(link.canonicalURL.absoluteString)
                    infoMessage = L("Coordination link copied to clipboard.")
                    errorMessage = nil
                } label: {
                    Label(L("Copy Coordination Link"), systemImage: "doc.on.doc")
                }
            }
        } header: {
            Text(L("Coordination link"))
        } footer: {
            Text(L("When anonymous room creation is unavailable, the app claims one pre-created link from this pool and marks it used."))
                .font(.caption)
        }
    }

    private var manageLinksSection: some View {
        Section {
            SecureField(L("Write password (for adding/removing links)"), text: $writeTokenText)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .accessibilityIdentifier("roomPool.writeToken")

            TextField(L("Paste room invitation links (one per line)"), text: $bulkLinksText, axis: .vertical)
                .lineLimit(3...6)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .accessibilityIdentifier("roomPool.bulkLinks")

            HStack {
                Button {
                    Task { await addPastedLinks() }
                } label: {
                    Label(L("Add Links"), systemImage: "plus.circle")
                }
                .disabled(isBusy || parsedLink == nil || bulkLinksText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button {
                    Task { await loadQueuedLinks() }
                } label: {
                    Label(L("Load Queued"), systemImage: "arrow.clockwise")
                }
                .disabled(isBusy || parsedLink == nil)
            }

            if !signedInGuestAccounts.isEmpty {
                Divider()
                Picker(L("Generate from account"), selection: $selectedGeneratorOrigin) {
                    ForEach(signedInGuestAccounts, id: \.originKey) { account in
                        Text("\(account.hostDisplayName) · \(account.displayAccountSummary)")
                            .tag(account.originKey)
                    }
                }
                Picker(L("Rooms to generate"), selection: $generateCount) {
                    Text("+5").tag(5)
                    Text("+10").tag(10)
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await generateAndAddRooms() }
                } label: {
                    Label(L("Generate & Add %ld Rooms", generateCount), systemImage: "wand.and.stars")
                }
                .disabled(isBusy || parsedLink == nil || selectedGeneratorOrigin.isEmpty)
            }

            if hasLoadedQueuedLinks {
                if queuedLinks.isEmpty {
                    Text(L("No unused links queued in this pool."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(queuedLinks) { item in
                        HStack(spacing: 8) {
                            Text(item.url.absoluteString)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(L("Remove"), role: .destructive) {
                                Task { await removeQueuedLink(id: item.id) }
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                    }

                    Button(L("Clear All Unused Links"), role: .destructive) {
                        Task { await clearUnusedLinks() }
                    }
                    .font(.caption)
                }
            }
        } header: {
            Text(L("Add or remove pool links"))
        } footer: {
            Text(L("Adding or removing links requires the server write password. Claiming a room only uses the coordination link."))
                .font(.caption)
        }
    }

    private var createPoolSection: some View {
        Section {
            DisclosureGroup(L("Create a new coordination pool"), isExpanded: $showCreateNewPool) {
                SecureField(L("Write password"), text: $writeTokenText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField(L("Custom pool ID (optional)"), text: $newPoolIDText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField(L("Label (optional)"), text: $newPoolLabelText)
                Button {
                    Task { await createNewPool() }
                } label: {
                    Label(L("Create Pool on rock.glowsoft.ru"), systemImage: "plus.rectangle.on.folder")
                }
                .disabled(isBusy || writeTokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func initializeFields() {
        let seedRecord = initialPool ?? poolStore.activePool
        if let seedRecord, let link = poolStore.link(for: seedRecord) {
            coordinationLinkText = link.canonicalURL.absoluteString
            writeTokenText = poolStore.writeToken(for: seedRecord.poolKey) ?? ""
            Task { await refreshStatus(for: link) }
        }
        if selectedGeneratorOrigin.isEmpty {
            selectedGeneratorOrigin = signedInGuestAccounts.first?.originKey ?? ""
        }
    }

    private func selectPool(_ record: RoomPoolRecord) {
        poolStore.setActivePool(poolKey: record.poolKey)
        if let link = poolStore.link(for: record) {
            coordinationLinkText = link.canonicalURL.absoluteString
            writeTokenText = poolStore.writeToken(for: record.poolKey) ?? ""
            queuedLinks = []
            hasLoadedQueuedLinks = false
            Task { await refreshStatus(for: link) }
        }
    }

    private func refreshStatus(for link: RoomPoolLink) async {
        do {
            let status = try await client.fetchStatus(link: link)
            activeStatus = status
            poolStore.updateCounts(
                poolKey: link.poolKey,
                availableCount: status.availableCount,
                usedCount: status.usedCount,
                origins: status.origins
            )
        } catch {
            // Non-fatal on initial load
        }
    }

    private func saveAndUsePool() async {
        errorMessage = nil
        infoMessage = nil
        guard let link = parsedLink else {
            errorMessage = RoomPoolError.invalidCoordinationLink.localizedDescription
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let status = try await client.fetchStatus(link: link)
            activeStatus = status
            let record = poolStore.upsertPool(
                link,
                status: status,
                writeToken: writeTokenText,
                makeActive: true
            )
            coordinationLinkText = link.canonicalURL.absoluteString
            if let onPoolConfigured {
                onPoolConfigured(record)
                dismiss()
            } else {
                infoMessage = L("Saved pool %@ (%ld available).", status.poolID, status.availableCount)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addPastedLinks() async {
        errorMessage = nil
        infoMessage = nil
        guard let link = parsedLink else {
            errorMessage = RoomPoolError.invalidCoordinationLink.localizedDescription
            return
        }
        let urls = RoomPoolLink.extractCandidateInvitationURLs(from: bulkLinksText)
        guard !urls.isEmpty else {
            errorMessage = L("No valid HTTPS meeting links were found in the pasted text.")
            return
        }
        let writeToken = writeTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !writeToken.isEmpty else {
            errorMessage = RoomPoolError.writeTokenRequired.localizedDescription
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await client.addLinks(link: link, urls: urls, writeToken: writeToken)
            poolStore.upsertPool(link, writeToken: writeToken, makeActive: true)
            poolStore.updateCounts(poolKey: link.poolKey, availableCount: result.availableCount)
            bulkLinksText = ""
            infoMessage = L("Added %ld link(s), skipped %ld duplicate(s).", result.added, result.skippedDuplicates)
            await refreshStatus(for: link)
            if hasLoadedQueuedLinks {
                queuedLinks = try await client.listLinks(link: link, writeToken: writeToken)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateAndAddRooms() async {
        errorMessage = nil
        infoMessage = nil
        guard let link = parsedLink else {
            errorMessage = RoomPoolError.invalidCoordinationLink.localizedDescription
            return
        }
        guard let account = signedInGuestAccounts.first(where: { $0.originKey == selectedGeneratorOrigin }),
              let origin = account.originURL else {
            errorMessage = L("Select a signed-in Guest website first.")
            return
        }
        let writeToken = writeTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !writeToken.isEmpty else {
            errorMessage = RoomPoolError.writeTokenRequired.localizedDescription
            return
        }
        isBusy = true
        defer { isBusy = false }

        do {
            var generated: [URL] = []
            let creator = MeetingRoomCreator(auth: .shared)
            for idx in 1...generateCount {
                let room = try await creator.createRoom(
                    on: origin,
                    engine: .guest,
                    options: RoomCreationOptions(
                        title: L("Meeting room %ld", idx),
                        allowGuests: true,
                        enableLobby: false
                    ),
                    allowPoolFallback: false
                )
                generated.append(room.invitationURL)
                if idx < generateCount {
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            let result = try await client.addLinks(link: link, urls: generated, writeToken: writeToken)
            poolStore.upsertPool(link, writeToken: writeToken, makeActive: true)
            poolStore.updateCounts(poolKey: link.poolKey, availableCount: result.availableCount)
            infoMessage = L("Generated and added %ld room(s). %ld available.", result.added, result.availableCount)
            await refreshStatus(for: link)
            if hasLoadedQueuedLinks {
                queuedLinks = try await client.listLinks(link: link, writeToken: writeToken)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadQueuedLinks() async {
        errorMessage = nil
        infoMessage = nil
        guard let link = parsedLink else {
            errorMessage = RoomPoolError.invalidCoordinationLink.localizedDescription
            return
        }
        let writeToken = writeTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !writeToken.isEmpty else {
            errorMessage = RoomPoolError.writeTokenRequired.localizedDescription
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let items = try await client.listLinks(link: link, writeToken: writeToken)
            poolStore.upsertPool(link, writeToken: writeToken, makeActive: true)
            queuedLinks = items
            hasLoadedQueuedLinks = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeQueuedLink(id: Int) async {
        guard let link = parsedLink else { return }
        let writeToken = writeTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !writeToken.isEmpty else {
            errorMessage = RoomPoolError.writeTokenRequired.localizedDescription
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await client.removeLinks(link: link, ids: [id], writeToken: writeToken)
            queuedLinks.removeAll { $0.id == id }
            poolStore.updateCounts(poolKey: link.poolKey, availableCount: result.availableCount)
            await refreshStatus(for: link)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearUnusedLinks() async {
        guard let link = parsedLink else { return }
        let writeToken = writeTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !writeToken.isEmpty else {
            errorMessage = RoomPoolError.writeTokenRequired.localizedDescription
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await client.removeLinks(link: link, clearAvailable: true, writeToken: writeToken)
            queuedLinks = []
            poolStore.updateCounts(poolKey: link.poolKey, availableCount: result.availableCount)
            infoMessage = L("Removed %ld unused link(s).", result.removed)
            await refreshStatus(for: link)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createNewPool() async {
        errorMessage = nil
        infoMessage = nil
        let writeToken = writeTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !writeToken.isEmpty else {
            errorMessage = RoomPoolError.writeTokenRequired.localizedDescription
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let created = try await client.createPool(
                serviceOrigin: RoomPoolLink.defaultServiceOrigin,
                poolID: newPoolIDText,
                label: newPoolLabelText,
                writeToken: writeToken
            )
            let status = RoomPoolStatus(
                poolID: created.poolID,
                label: newPoolLabelText.trimmingCharacters(in: .whitespacesAndNewlines),
                availableCount: 0,
                usedCount: 0,
                origins: [:]
            )
            poolStore.upsertPool(created, status: status, writeToken: writeToken, makeActive: true)
            coordinationLinkText = created.canonicalURL.absoluteString
            SiteAuthClipboard.copy(created.canonicalURL.absoluteString)
            activeStatus = status
            queuedLinks = []
            hasLoadedQueuedLinks = true
            newPoolIDText = ""
            newPoolLabelText = ""
            showCreateNewPool = false
            infoMessage = L("Created pool %@ and copied its coordination link.", created.poolID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

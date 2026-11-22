import ConferenceCore
import Foundation
import SwiftUI

public struct SiteAccountsSettingsSections: View {
    public let suggestedOrigins: [URL]
    public let onCreateRoom: (@MainActor (URL) -> Void)?

    @ObservedObject private var store = SiteAccountStore.shared

    public init(
        suggestedOrigins: [URL] = [],
        onCreateRoom: (@MainActor (URL) -> Void)? = nil
    ) {
        self.suggestedOrigins = suggestedOrigins
        self.onCreateRoom = onCreateRoom
    }

    public var body: some View {
        SiteAccountsSection(suggestedOrigins: suggestedOrigins, onCreateRoom: onCreateRoom)
        SiteCertificatesSection()
    }
}

public struct SiteAccountsSection: View {
    public let suggestedOrigins: [URL]
    public let onCreateRoom: (@MainActor (URL) -> Void)?

    @ObservedObject private var store = SiteAccountStore.shared
    @State private var signInTarget: IdentifiableSiteOrigin?
    @State private var showingBlankSignIn = false
    @State private var showingCertPickerForAccount: SiteAccountRecord?

    public init(
        suggestedOrigins: [URL] = [],
        onCreateRoom: (@MainActor (URL) -> Void)? = nil
    ) {
        self.suggestedOrigins = suggestedOrigins
        self.onCreateRoom = onCreateRoom
    }

    public var body: some View {
        Section {
            if store.accounts.isEmpty {
                Text(L("No websites signed in yet. Sign in to keep credentials across websites, use mTLS client certificates, and create rooms."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.accounts) { account in
                    accountRow(account)
                }
            }

            Button {
                showingBlankSignIn = true
            } label: {
                Label(L("Sign in to a website…"), systemImage: "person.badge.plus")
            }
            .accessibilityIdentifier("settings.site-accounts.add")
        } header: {
            Text(L("Site logins & SSO"))
        } footer: {
            Text(L("Keeps one saved login and optional mTLS client certificate per website for automatic relogin and token renewal."))
                .font(.caption)
        }
        .sheet(isPresented: $showingBlankSignIn) {
            SiteSignInSheet(initialOrigin: nil, suggestedOrigins: suggestedOrigins)
        }
        .sheet(item: $signInTarget) { target in
            SiteSignInSheet(initialOrigin: target.url, suggestedOrigins: suggestedOrigins)
        }
    }

    @ViewBuilder
    private func accountRow(_ account: SiteAccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.hostDisplayName)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(SiteAuthEngineLabel.title(for: account.engine))
                        Text("·")
                        Text(account.displayAccountSummary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(for: account)
            }

            if let certLabel = store.certificateSummary(for: account) {
                let expired = account.clientCertificateID.flatMap { store.certificate(for: $0) }?.isExpired == true
                let expiringSoon = account.clientCertificateID.flatMap { store.certificate(for: $0) }?.isExpiringSoon() == true
                Label(
                    expired
                        ? L("mTLS: %@ (Expired)", certLabel)
                        : (expiringSoon ? L("mTLS: %@ (Expiring soon)", certLabel) : L("mTLS: %@", certLabel)),
                    systemImage: expired ? "exclamationmark.triangle.fill" : "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(expired || expiringSoon ? .orange : .secondary)
            }

            HStack(spacing: 12) {
                if account.engine != .community, let origin = account.originURL, let onCreateRoom {
                    Button(L("New room")) {
                        onCreateRoom(origin)
                    }
                    .font(.caption.weight(.semibold))
                }
                Button(account.needsReauthentication ? L("Sign in again…") : L("Edit / Re-sign in…")) {
                    if let origin = account.originURL {
                        signInTarget = IdentifiableSiteOrigin(origin)
                    }
                }
                .font(.caption)
                Spacer()
                if account.hasClientCertificate && account.authMethod != .mtlsOnly {
                    Button(L("Sign out")) {
                        store.signOut(originKey: account.originKey, keepCertificate: true)
                    }
                    .font(.caption)
                }
                Button(L("Remove"), role: .destructive) {
                    store.removeSite(originKey: account.originKey)
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(for account: SiteAccountRecord) -> some View {
        if account.needsReauthentication {
            Text(L("Expired"))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        } else if account.authMethod == .mtlsOnly {
            Text(L("mTLS"))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
        } else {
            Text(L("Signed in"))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.18), in: Capsule())
                .foregroundStyle(.green)
        }
    }
}

public struct SiteCertificatesSection: View {
    @ObservedObject private var store = SiteAccountStore.shared
    @StateObject private var certImport = PKCS12ImportFlow()
    @State private var infoMessage: String?

    public init() {}

    public var body: some View {
        Section {
            if store.certificates.isEmpty {
                Text(L("No client certificates imported. Import a .p12 or .pfx certificate to use mTLS on supported websites."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.certificates) { cert in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cert.label)
                                .font(.subheadline.weight(.medium))
                            Text(certificateDetails(cert))
                                .font(.caption)
                                .foregroundStyle(cert.isExpired ? .red : .secondary)
                        }
                        Spacer()
                        Button(L("Remove"), role: .destructive) {
                            store.deleteCertificate(id: cert.id)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }

            #if os(macOS)
            if !store.systemCertificates.isEmpty {
                DisclosureGroup(L("macOS Keychain identities (%ld)", store.systemCertificates.count)) {
                    ForEach(store.systemCertificates) { cert in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cert.label).font(.subheadline)
                            Text(certificateDetails(cert)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            #endif

            if certImport.isAwaitingPassphrase {
                PKCS12PassphraseInlineCard(flow: certImport, store: store) { record in
                    infoMessage = L("Imported certificate %@.", record.label)
                }
            } else {
                if let error = certImport.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let infoMessage {
                    Text(infoMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Button {
                infoMessage = nil
                certImport.showingFileImporter = true
            } label: {
                Label(L("Import .p12 / .pfx certificate…"), systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("settings.mtls.import")
        } header: {
            Text(L("Client certificates (mTLS)"))
        } footer: {
            Text(L("Imported certificates are stored in your device Keychain and never synced to iCloud."))
                .font(.caption)
        }
        .fileImporter(
            isPresented: $certImport.showingFileImporter,
            allowedContentTypes: PKCS12ImportFlow.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            certImport.handleFileResult(result, store: store) { record in
                infoMessage = L("Imported certificate %@.", record.label)
            }
        }
    }

    private func certificateDetails(_ cert: ClientCertificateRecord) -> String {
        var parts = [cert.shortFingerprint]
        if let issuer = cert.issuerSummary, !issuer.isEmpty {
            parts.append(issuer)
        }
        if let expiresAt = cert.expiresAt {
            let formatted = expiresAt.formatted(date: .abbreviated, time: .omitted)
            parts.append(cert.isExpired ? L("Expired %@", formatted) : L("Expires %@", formatted))
        }
        return parts.joined(separator: " · ")
    }
}

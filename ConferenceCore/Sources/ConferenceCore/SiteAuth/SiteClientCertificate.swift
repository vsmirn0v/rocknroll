import CryptoKit
import Foundation
import Security

public enum ClientCertificateSource: Codable, Equatable, Sendable {
    case importedPKCS12(id: UUID)
    case systemIdentity(sha256Fingerprint: String)
}

public struct ClientCertificateRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var subjectSummary: String
    public var commonName: String?
    public var issuerSummary: String?
    public var issuerDERBase64: String?
    public var sha256Fingerprint: String
    public var expiresAt: Date?
    public var source: ClientCertificateSource
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        subjectSummary: String,
        commonName: String? = nil,
        issuerSummary: String? = nil,
        issuerDERBase64: String? = nil,
        sha256Fingerprint: String,
        expiresAt: Date? = nil,
        source: ClientCertificateSource,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.subjectSummary = subjectSummary
        self.commonName = commonName
        self.issuerSummary = issuerSummary
        self.issuerDERBase64 = issuerDERBase64
        self.sha256Fingerprint = sha256Fingerprint
        self.expiresAt = expiresAt
        self.source = source
        self.createdAt = createdAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    public func isExpiringSoon(within days: Int = 30, now: Date = Date()) -> Bool {
        guard let expiresAt, expiresAt > now else { return false }
        return expiresAt.timeIntervalSince(now) <= TimeInterval(days * 86_400)
    }

    public var shortFingerprint: String {
        String(sha256Fingerprint.prefix(12)).uppercased()
    }

    public var issuerDER: Data? {
        issuerDERBase64.flatMap { Data(base64Encoded: $0) }
    }
}

public struct UnlockedClientIdentity: @unchecked Sendable {
    public let record: ClientCertificateRecord
    public let identity: SecIdentity
    public let certificateChain: [SecCertificate]
    public let issuerDER: Data?

    public init(
        record: ClientCertificateRecord,
        identity: SecIdentity,
        certificateChain: [SecCertificate],
        issuerDER: Data?
    ) {
        self.record = record
        self.identity = identity
        self.certificateChain = certificateChain
        self.issuerDER = issuerDER
    }

    public func matches(distinguishedNames: [Data]) -> Bool {
        guard !distinguishedNames.isEmpty else { return true }
        if let issuerDER, distinguishedNames.contains(issuerDER) {
            return true
        }
        var leaf: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else {
            return false
        }
        if let normalized = SecCertificateCopyNormalizedIssuerSequence(leaf) as Data?,
           distinguishedNames.contains(normalized) {
            return true
        }
        return false
    }
}

public enum ClientCertificateError: LocalizedError, Equatable {
    case emptyData
    case oversizedData
    case authenticationFailed
    case invalidPKCS12
    case noIdentityFound

    public var errorDescription: String? {
        switch self {
        case .emptyData:
            return L("The selected certificate file is empty.")
        case .oversizedData:
            return L("The selected certificate file is too large.")
        case .authenticationFailed:
            return L("The certificate passphrase is incorrect.")
        case .invalidPKCS12:
            return L("Could not read this PKCS#12 (.p12 / .pfx) certificate.")
        case .noIdentityFound:
            return L("This file does not contain a client certificate with a private key.")
        }
    }
}

public enum ClientCertificateLoader {
    public static let maxPKCS12Bytes = 4_194_304

    public static func importPKCS12(
        data: Data,
        passphrase: String,
        id: UUID = UUID(),
        customLabel: String? = nil
    ) throws -> UnlockedClientIdentity {
        guard !data.isEmpty else { throw ClientCertificateError.emptyData }
        guard data.count <= maxPKCS12Bytes else { throw ClientCertificateError.oversizedData }

        var options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase
        ]
        #if os(macOS)
        // Sandbox-safe in-memory import avoids writing into the legacy login keychain.
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        } else {
            options[kSecUseDataProtectionKeychain as String] = true
        }
        #endif

        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure {
            throw ClientCertificateError.authenticationFailed
        }
        guard status == errSecSuccess else {
            throw ClientCertificateError.invalidPKCS12
        }
        guard let items = rawItems as? [[String: Any]] else {
            throw ClientCertificateError.noIdentityFound
        }
        for item in items {
            guard let rawIdentity = item[kSecImportItemIdentity as String] else { continue }
            let identity = rawIdentity as! SecIdentity
            let rawChain = (item[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
            return try buildUnlockedIdentity(
                identity: identity,
                rawChain: rawChain,
                id: id,
                customLabel: customLabel,
                source: .importedPKCS12(id: id)
            )
        }
        throw ClientCertificateError.noIdentityFound
    }

    #if os(macOS)
    /// Discovers existing `SecIdentity` entries accessible to the macOS user (Keychain / SmartCard / MDM).
    public static func availableSystemIdentities() -> [UnlockedClientIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true
        ]
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        guard status == errSecSuccess, let list = raw as? [SecIdentity] else {
            return []
        }
        var seen = Set<String>()
        var results: [UnlockedClientIdentity] = []
        for identity in list {
            var leaf: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else { continue }
            let fingerprint = sha256Hex(of: leaf)
            guard seen.insert(fingerprint).inserted else { continue }
            if let unlocked = try? buildUnlockedIdentity(
                identity: identity,
                rawChain: [leaf],
                id: UUID(),
                customLabel: nil,
                source: .systemIdentity(sha256Fingerprint: fingerprint)
            ) {
                results.append(unlocked)
            }
        }
        return results.sorted { $0.record.label.localizedCaseInsensitiveCompare($1.record.label) == .orderedAscending }
    }
    #endif

    public static func buildUnlockedIdentity(
        identity: SecIdentity,
        rawChain: [SecCertificate],
        id: UUID,
        customLabel: String?,
        source: ClientCertificateSource
    ) throws -> UnlockedClientIdentity {
        var leaf: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else {
            throw ClientCertificateError.noIdentityFound
        }
        let leafDER = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: leafDER).map { String(format: "%02x", $0) }.joined()
        let subjectSummary = (SecCertificateCopySubjectSummary(leaf) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = X509DERInspector.inspect(leafDER)

        var chain: [SecCertificate] = [leaf]
        for cert in rawChain {
            let certData = SecCertificateCopyData(cert) as Data
            if certData != leafDER {
                chain.append(cert)
            }
        }

        let cleanCustom = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = metadata.commonName ?? subjectSummary ?? String(fingerprint.prefix(12))
        let label = (cleanCustom?.isEmpty == false) ? cleanCustom! : fallbackName
        let record = ClientCertificateRecord(
            id: id,
            label: label,
            subjectSummary: (subjectSummary?.isEmpty == false) ? subjectSummary! : fallbackName,
            commonName: metadata.commonName,
            issuerSummary: metadata.issuerSummary,
            issuerDERBase64: metadata.issuerDER?.base64EncodedString(),
            sha256Fingerprint: fingerprint,
            expiresAt: metadata.expiresAt,
            source: source
        )
        return UnlockedClientIdentity(
            record: record,
            identity: identity,
            certificateChain: chain,
            issuerDER: metadata.issuerDER
        )
    }

    private static func sha256Hex(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Bounds-checked minimal ASN.1 DER X.509 parser extracting subject CN, issuer CN/O,
/// raw issuer DN DER TLV (for TLS `CertificateRequest` DN matching), and `notAfter`.
enum X509DERInspector {
    struct Metadata {
        var commonName: String?
        var issuerSummary: String?
        var issuerDER: Data?
        var expiresAt: Date?
    }

    private struct TLV {
        let tag: UInt8
        let fullRange: Range<Int>
        let contentRange: Range<Int>
    }

    static func inspect(_ der: Data) -> Metadata {
        var result = Metadata()
        guard let cert = readTLV(in: der, at: 0), cert.tag == 0x30 else { return result }
        let certChildren = children(of: cert, in: der)
        guard let tbs = certChildren.first, tbs.tag == 0x30 else { return result }
        let tbsFields = children(of: tbs, in: der)
        guard !tbsFields.isEmpty else { return result }

        var idx = 0
        // Optional explicit [0] version
        if tbsFields[idx].tag == 0xA0 {
            idx += 1
        }
        // serialNumber (INTEGER), signature (AlgorithmIdentifier)
        idx += 2
        guard idx < tbsFields.count else { return result }

        // issuer (Name SEQUENCE)
        let issuerTLV = tbsFields[idx]
        if issuerTLV.tag == 0x30 {
            result.issuerDER = der.subdata(in: issuerTLV.fullRange)
            let names = extractDistinguishedNames(from: issuerTLV, in: der)
            result.issuerSummary = names.commonName ?? names.organization
        }
        idx += 1
        guard idx < tbsFields.count else { return result }

        // validity (SEQUENCE { notBefore, notAfter })
        let validityTLV = tbsFields[idx]
        if validityTLV.tag == 0x30 {
            let times = children(of: validityTLV, in: der)
            if times.count >= 2 {
                result.expiresAt = parseASN1Time(times[1], in: der)
            }
        }
        idx += 1
        guard idx < tbsFields.count else { return result }

        // subject (Name SEQUENCE)
        let subjectTLV = tbsFields[idx]
        if subjectTLV.tag == 0x30 {
            let names = extractDistinguishedNames(from: subjectTLV, in: der)
            result.commonName = names.commonName ?? names.organization
        }
        return result
    }

    private static func readTLV(in data: Data, at offset: Int) -> TLV? {
        guard offset < data.count else { return nil }
        let tag = data[offset]
        var cursor = offset + 1
        guard cursor < data.count else { return nil }
        let lenByte = data[cursor]
        cursor += 1
        let length: Int
        if lenByte & 0x80 == 0 {
            length = Int(lenByte)
        } else {
            let octets = Int(lenByte & 0x7F)
            guard octets > 0, octets <= 4, cursor + octets <= data.count else { return nil }
            var acc = 0
            for i in 0..<octets {
                acc = (acc << 8) | Int(data[cursor + i])
            }
            cursor += octets
            length = acc
        }
        guard length >= 0, cursor + length <= data.count else { return nil }
        return TLV(tag: tag, fullRange: offset..<(cursor + length), contentRange: cursor..<(cursor + length))
    }

    private static func children(of parent: TLV, in data: Data) -> [TLV] {
        var result: [TLV] = []
        var cursor = parent.contentRange.lowerBound
        while cursor < parent.contentRange.upperBound {
            guard let child = readTLV(in: data, at: cursor),
                  child.fullRange.upperBound <= parent.contentRange.upperBound else {
                break
            }
            result.append(child)
            cursor = child.fullRange.upperBound
        }
        return result
    }

    private static func extractDistinguishedNames(from nameTLV: TLV, in data: Data) -> (commonName: String?, organization: String?) {
        var cn: String?
        var org: String?
        let cnOID: [UInt8] = [0x55, 0x04, 0x03]
        let orgOID: [UInt8] = [0x55, 0x04, 0x0A]
        for rdn in children(of: nameTLV, in: data) where rdn.tag == 0x31 {
            for atv in children(of: rdn, in: data) where atv.tag == 0x30 {
                let pair = children(of: atv, in: data)
                guard pair.count >= 2, pair[0].tag == 0x06 else { continue }
                let oid = Array(data.subdata(in: pair[0].contentRange))
                let rawValue = data.subdata(in: pair[1].contentRange)
                let text = decodeASN1String(tag: pair[1].tag, data: rawValue)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let text, !text.isEmpty else { continue }
                if oid == cnOID, cn == nil { cn = text }
                else if oid == orgOID, org == nil { org = text }
            }
        }
        return (cn, org)
    }

    private static func decodeASN1String(tag: UInt8, data: Data) -> String? {
        switch tag {
        case 0x0C, 0x13, 0x16: // UTF8String, PrintableString, IA5String
            return String(data: data, encoding: .utf8)
        case 0x1E: // BMPString (UTF-16BE)
            return String(data: data, encoding: .utf16BigEndian)
        case 0x1C: // UniversalString (UTF-32BE)
            return String(data: data, encoding: .utf32BigEndian)
        default:
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        }
    }

    private static func parseASN1Time(_ tlv: TLV, in data: Data) -> Date? {
        guard let text = String(data: data.subdata(in: tlv.contentRange), encoding: .ascii) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if tlv.tag == 0x17, text.hasSuffix("Z") { // UTCTime YYMMDDHHMMSSZ
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            formatter.twoDigitStartDate = Date(timeIntervalSince1970: -631_152_000) // 1950-01-01 per RFC 5280
            return formatter.date(from: text)
        }
        if tlv.tag == 0x18, text.hasSuffix("Z") { // GeneralizedTime YYYYMMDDHHMMSSZ
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return formatter.date(from: text)
        }
        return nil
    }
}

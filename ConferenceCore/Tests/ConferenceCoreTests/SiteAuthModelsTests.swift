import Foundation
import XCTest
@testable import ConferenceCore

final class SiteAuthModelsTests: XCTestCase {
    // Disposable self-signed EC P-256 fixture (/O=ExampleCorp/CN=Fixture Client Cert, pass: "testpass")
    private static let fixtureP12Base64 =
        "MIIERAIBAzCCA/IGCSqGSIb3DQEHAaCCA+MEggPfMIID2zCCAooGCSqGSIb3DQEHBqCCAnswggJ3" +
        "AgEAMIICcAYJKoZIhvcNAQcBMF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBA5KJEJRi+6" +
        "WvUO6OX1a9IFAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQYfdfCOw7dxxl0YzXfbMp" +
        "poCCAgDsJEhukl0gUyeMAbyUL3vCPLKyhgP+9rKr7DI7f7ssufObrcJe6Pxf5gH9axlyAEQXvZmG" +
        "bFB2Z5p13Vp6hfn5YEnKly/vDk69JS17bJgXiMO9iiDpZK9rp1LqFO2IVlR66vdSbvsFy3FmYd3i" +
        "yNA86q4eC0YywLRSLHy1I2Aj7ryvzp2naCp4Mb9Uiy8ip5FFYMEaSbq6IUHi853dydu6Nm2E8D6e" +
        "W0SdjGwps5DcrMLtyNJ1M63RCM6SoBi/3ucIx7RqLIjnHuuPuKR4cRDW7TvNvzB72Qf+D1sWSBHW" +
        "pAlb++kaRMBLjPvK5SI3uHECUGdJVQehJSUB87aXq9mVru1jdZxbIQVsRTTngWtgCnkmY5uyJ1qe" +
        "KD41OsRtgSLSIhmxAtAovgR+Ll7kJJ2Po6d4KxiZD9JAQpc87MVQthN8fNBkAznXLrVeuTCivPnc" +
        "nrM7UVq8bRQbGEbNfGQNgSXoSNbi8gRq2PVrkoFheAP0yTmLWNf3pIGqT+fGEavxCyyhxnyRxCpF" +
        "F1smj0iuBr2VJDjq54JjhQnBiDLp8FrADudU3N8U6ds2yFBqz8aruwVL+JEfOI2OldGimbpFYnos" +
        "adZ3T1ldhJOWT36uz7m2mTRxmZiqTx8RF7J5+RJX//Xu61eErp4gbdVw4LO4W3c8RAOqJbYe6Or9" +
        "SHMDwTCCAUkGCSqGSIb3DQEHAaCCAToEggE2MIIBMjCCAS4GCyqGSIb3DQEMCgECoIH3MIH0MF8G" +
        "CSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBDjpB7CcchpizqFdKGCvLofAgIIADAMBggqhkiG" +
        "9w0CCQUAMB0GCWCGSAFlAwQBKgQQoYPMIzBiTS//qJaYElVa6QSBkISFUhEdAIbtUSyfZwvOu6Eq" +
        "kL+YV+eYVyp4HQmFuH4HFbjeGTn9AJiEeRFu71EQHZg0jZoBngV2QDdTF/qsNi4cvuePlOEuJrBj" +
        "7pDAlBvWeFs0sCSJFbEgHYVcfltqCfiGvT2AtKNJDuccdws3Xlpagh6kb6G7LNt9OLeEb9RRa9Fc" +
        "KgNIvIE7KeH5rGPzAzElMCMGCSqGSIb3DQEJFTEWBBTAvCcF9SSsuSsuwlDSeGpZpPnrRzBJMDEw" +
        "DQYJYIZIAWUDBAIBBQAEIFn+kDtGZjOpHcvf2DwQSwYTB0o8nAWTWaBaEI2ZbNjPBBBonPSTPl7O" +
        "NFFY9Mrr8idFAgIIAA=="

    func testCanonicalSiteOriginNormalizationAndTelemostAliases() {
        XCTAssertEqual(SiteOrigin.normalize("Jazz.Corp.RU:443/calls/abc?psw=1")?.absoluteString, "https://jazz.corp.ru")
        XCTAssertEqual(SiteOrigin.normalize("https://Meet.Example.Test:8443/c/123")?.absoluteString, "https://meet.example.test:8443")
        XCTAssertEqual(SiteOrigin.normalize("https://telemost.360.yandex.ru/j/abc")?.absoluteString, "https://telemost.yandex.ru")
        XCTAssertEqual(SiteOrigin.canonicalKey(for: URL(string: "wss://telemost.360.yandex.ru/ws")!), "https://telemost.yandex.ru")
        XCTAssertNil(SiteOrigin.normalize("http://insecure.example.test"))
        XCTAssertNil(SiteOrigin.normalize("https://user:pass@example.test"))
        XCTAssertTrue(SiteOrigin.hostMatches("api.jazz.corp.ru", siteHost: "jazz.corp.ru"))
        XCTAssertTrue(SiteOrigin.hostMatches("telemost.360.yandex.ru", siteHost: "telemost.yandex.ru"))
        XCTAssertFalse(SiteOrigin.hostMatches("other.example.net", siteHost: "jazz.corp.ru"))
    }

    func testJWTClaimsInspection() throws {
        let header = base64URL(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8))
        let exp = Int(Date(timeIntervalSince1970: 1_900_000_000).timeIntervalSince1970)
        let payload = base64URL(Data("{\"sub\":\"user-42\",\"name\":\"Ada Lovelace\",\"email\":\"ada@example.test\",\"azp\":\"s2b\",\"iss\":\"https://meet.example.test/realms/s2b\",\"exp\":\(exp)}".utf8))
        let claims = try XCTUnwrap(JWTClaims.inspect("\(header).\(payload).sig"))
        XCTAssertEqual(claims.subject, "user-42")
        XCTAssertEqual(claims.displayName, "Ada Lovelace")
        XCTAssertEqual(claims.email, "ada@example.test")
        XCTAssertEqual(claims.authorizedParty, "s2b")
        XCTAssertEqual(claims.issuer, "https://meet.example.test/realms/s2b")
        XCTAssertEqual(claims.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertFalse(claims.isLicenseToken)

        let licensePayload = base64URL(Data("{\"jazz_premium_user\":true,\"graceExp\":1900000000}".utf8))
        let licenseClaims = try XCTUnwrap(JWTClaims.inspect("\(header).\(licensePayload).sig"))
        XCTAssertTrue(licenseClaims.isLicenseToken)

        XCTAssertNil(JWTClaims.inspect("opaque-token"))
    }

    func testPKCS12ImportAndX509MetadataExtraction() throws {
        let p12 = try XCTUnwrap(Data(base64Encoded: Self.fixtureP12Base64))
        XCTAssertThrowsError(try ClientCertificateLoader.importPKCS12(data: Data(), passphrase: "")) { error in
            XCTAssertEqual(error as? ClientCertificateError, .emptyData)
        }
        XCTAssertThrowsError(try ClientCertificateLoader.importPKCS12(data: p12, passphrase: "wrong")) { error in
            XCTAssertEqual(error as? ClientCertificateError, .authenticationFailed)
        }

        let unlocked = try ClientCertificateLoader.importPKCS12(data: p12, passphrase: "testpass")
        XCTAssertEqual(unlocked.record.commonName, "Fixture Client Cert")
        XCTAssertEqual(unlocked.record.issuerSummary, "Fixture Client Cert")
        XCTAssertNotNil(unlocked.issuerDER)
        XCTAssertNotNil(unlocked.record.expiresAt)
        XCTAssertFalse(unlocked.record.isExpired)
        XCTAssertFalse(unlocked.certificateChain.isEmpty)
        let issuer = try XCTUnwrap(unlocked.issuerDER)
        XCTAssertTrue(unlocked.matches(distinguishedNames: [issuer]))
        XCTAssertFalse(unlocked.matches(distinguishedNames: [Data([0x30, 0x00])]))
    }

    func testSerializedCookieMatchingAndInMemorySecretStore() throws {
        let cookie = SerializedHTTPCookie(name: "Session_id", value: "abc", domain: ".yandex.ru", path: "/telemost", isSecure: true)
        let matching = URL(string: "https://cloud-api.yandex.ru/telemost/v2")!
        let wrongPath = URL(string: "https://cloud-api.yandex.ru/other")!
        let wrongHost = URL(string: "https://evil.example.test/telemost")!
        XCTAssertEqual(SerializedHTTPCookie.cookieHeader(from: [cookie], for: matching), "Session_id=abc")
        XCTAssertNil(SerializedHTTPCookie.cookieHeader(from: [cookie], for: wrongPath))
        XCTAssertNil(SerializedHTTPCookie.cookieHeader(from: [cookie], for: wrongHost))

        let store = InMemorySiteSecretStore()
        let key = "https://meet.example.test"
        XCTAssertTrue(store.writeSiteSecret(SiteSecretPayload(accessToken: "t1", savedPassword: "pw"), originKey: key))
        XCTAssertEqual(store.readSiteSecret(originKey: key)?.accessToken, "t1")
        XCTAssertTrue(store.writeSiteSecret(nil, originKey: key))
        XCTAssertNil(store.readSiteSecret(originKey: key))

        let certID = UUID()
        XCTAssertTrue(store.writeCertificateBlob(StoredPKCS12Blob(data: Data([1, 2, 3]), passphrase: "p"), id: certID))
        XCTAssertEqual(store.readCertificateBlob(id: certID)?.passphrase, "p")
    }

    func testTrueConfTargetAuthenticatedSupportAndPasswordExtraction() throws {
        let target = try TrueConfTarget.parse("https://tc.example.test/c/room42?psw=secret99")
        XCTAssertEqual(target.invitationPassword, "secret99")
        let noGuestPayload = try JSONSerialization.data(withJSONObject: [
            "conference": [
                "id": "room42",
                "web_client_url": "https://tc.example.test/webrtc/room42",
                "allow_guests": false
            ]
        ])
        XCTAssertFalse(target.supportsBrowser(in: noGuestPayload))
        XCTAssertTrue(target.supportsBrowser(in: noGuestPayload, allowAuthenticated: true))
    }

    func testSuggestedOriginsDerivedFromUserDataWithoutPrefilledDomains() {
        XCTAssertTrue(SiteOrigin.suggestedOrigins(rooms: [], calendarMeetings: [], fallbackOrigin: nil).isEmpty)
        XCTAssertTrue(SiteOrigin.suggestedOrigins(rooms: [], calendarMeetings: [], fallbackOrigin: "   ").isEmpty)
        XCTAssertTrue(SiteOrigin.suggestedOrigins(rooms: [], calendarMeetings: [], fallbackOrigin: "https://rock.glowsoft.ru").isEmpty)

        let now = Date()
        var communityRoom = RecentRoom(
            invitationURL: URL(string: "https://rock.glowsoft.ru/jams/test")!,
            title: "Practice",
            identifier: "test",
            isStarred: true,
            lastJoined: now
        )
        communityRoom.engine = .community

        let favoriteRoom = RecentRoom(
            invitationURL: URL(string: "https://meet.corp.example/calls/fav1?psw=1")!,
            title: "Fav",
            identifier: "fav1",
            isStarred: true,
            lastJoined: now
        )
        let recentTelemost = RecentRoom(
            invitationURL: URL(string: "https://telemost.360.yandex.ru/j/999")!,
            title: "Sync",
            identifier: "999",
            isStarred: false,
            lastJoined: now.addingTimeInterval(-60)
        )
        let calendarEvent = CalendarMeeting(
            id: "ev1",
            seriesID: "s1",
            calendarID: "c1",
            calendarTitle: "Work",
            title: "Standup",
            start: now,
            end: now.addingTimeInterval(1800),
            links: [URL(string: "https://tc.example.org/c/standup")!]
        )

        let origins = SiteOrigin.suggestedOrigins(
            rooms: [communityRoom, recentTelemost, favoriteRoom],
            calendarMeetings: [calendarEvent],
            fallbackOrigin: "jazz.internal.example"
        )
        XCTAssertEqual(
            origins.map(\.absoluteString),
            [
                "https://jazz.internal.example",
                "https://meet.corp.example",
                "https://telemost.yandex.ru",
                "https://tc.example.org"
            ]
        )

        var joinedTrueConf = RecentRoom(
            invitationURL: URL(string: "https://tc.example.test/c/0100110011")!,
            title: "TrueConf Room",
            identifier: "0100110011",
            isStarred: false,
            lastJoined: now.addingTimeInterval(60)
        )
        joinedTrueConf.engine = .trueconf
        let extraCalendarMeetings = (1...10).map { index in
            CalendarMeeting(
                id: "cal-\(index)",
                seriesID: "series-\(index)",
                calendarID: "cal",
                calendarTitle: "Work",
                title: "Sync \(index)",
                start: now,
                end: now.addingTimeInterval(1800),
                links: [URL(string: "https://meet-\(index).example.org/calls/room\(index)")!]
            )
        }
        let manyOrigins = SiteOrigin.suggestedOrigins(
            rooms: [joinedTrueConf, favoriteRoom],
            calendarMeetings: extraCalendarMeetings,
            fallbackOrigin: "jazz.internal.example"
        )
        XCTAssertEqual(manyOrigins.count, 13)
        XCTAssertEqual(
            Array(manyOrigins.prefix(3).map(\.absoluteString)),
            [
                "https://jazz.internal.example",
                "https://meet.corp.example",
                "https://tc.example.test"
            ]
        )
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

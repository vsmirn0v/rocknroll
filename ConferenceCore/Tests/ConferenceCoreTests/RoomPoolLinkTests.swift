import Foundation
import XCTest
@testable import ConferenceCore

final class RoomPoolLinkTests: XCTestCase {
    func testParsesFragmentQueryAndAmpersandPathForms() throws {
        let ampersand = try RoomPoolLink.parse("https://rock.glowsoft.ru/pools/363636&auth=dhdbdhBvVv75b")
        let query = try RoomPoolLink.parse("https://rock.glowsoft.ru/pools/363636?auth=dhdbdhBvVv75b")
        let fragment = try RoomPoolLink.parse("https://rock.glowsoft.ru/pools/363636#auth=dhdbdhBvVv75b")

        XCTAssertEqual(ampersand.serviceOrigin.absoluteString, "https://rock.glowsoft.ru")
        XCTAssertEqual(ampersand.poolID, "363636")
        XCTAssertEqual(ampersand.authToken, "dhdbdhBvVv75b")
        XCTAssertEqual(ampersand, query)
        XCTAssertEqual(query, fragment)
        XCTAssertEqual(
            ampersand.canonicalURL.absoluteString,
            "https://rock.glowsoft.ru/pools/363636#auth=dhdbdhBvVv75b"
        )
    }

    func testUnwrapsHandoffLinksAndAllowsLocalTestLoopback() throws {
        let target = "https://rock.glowsoft.ru/pools/Team_42#auth=SecretToken1234"
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let parsed = try RoomPoolLink.parse("conferenceguest://join?url=\(encoded)")
        XCTAssertEqual(parsed.poolID, "team_42")
        XCTAssertEqual(parsed.authToken, "SecretToken1234")

        let local = try RoomPoolLink.parse("http://127.0.0.1:18793/pools/localpool#auth=Token_9999")
        XCTAssertEqual(local.serviceOrigin.absoluteString, "http://127.0.0.1:18793")
        XCTAssertEqual(local.poolID, "localpool")
    }

    func testRejectsMalformedPoolLinks() {
        for invalid in [
            "",
            "https://rock.glowsoft.ru/jams/test",
            "https://rock.glowsoft.ru/pools/363636",
            "https://rock.glowsoft.ru/pools/ab&auth=dhdbdhBvVv75b",
            "http://rock.glowsoft.ru/pools/363636#auth=dhdbdhBvVv75b",
            "https://user:pass@rock.glowsoft.ru/pools/363636#auth=dhdbdhBvVv75b",
            "https://rock.glowsoft.ru/pools/363636?auth=a#auth=b"
        ] {
            XCTAssertThrowsError(try RoomPoolLink.parse(invalid), invalid)
        }
    }

    func testExtractsCandidateInvitationURLsAndExcludesPoolAndRockLinks() {
        let text = """
        Join here: https://jazz.sber.ru/calls/room-a?psw=MQo, or https://jazz.corp.ru/calls/room-b?psw=MQo!
        Pool: https://rock.glowsoft.ru/pools/363636&auth=dhdbdhBvVv75b
        Test jam: https://rock.glowsoft.ru/jams/test
        Duplicate: https://jazz.sber.ru/calls/room-a?psw=MQo
        """
        let extracted = RoomPoolLink.extractCandidateInvitationURLs(from: text)
        XCTAssertEqual(
            extracted.map(\.absoluteString),
            [
                "https://jazz.sber.ru/calls/room-a?psw=MQo",
                "https://jazz.corp.ru/calls/room-b?psw=MQo"
            ]
        )
    }

    func testInMemorySecretStorePoolSecrets() {
        let store = InMemorySiteSecretStore()
        let key = "https://rock.glowsoft.ru#363636"
        XCTAssertNil(store.readPoolSecret(poolKey: key))
        XCTAssertTrue(store.writePoolSecret(StoredRoomPoolSecret(authToken: "auth1234", writeToken: "write5678"), poolKey: key))
        let loaded = store.readPoolSecret(poolKey: key)
        XCTAssertEqual(loaded?.authToken, "auth1234")
        XCTAssertEqual(loaded?.writeToken, "write5678")
        XCTAssertTrue(store.writePoolSecret(nil, poolKey: key))
        XCTAssertNil(store.readPoolSecret(poolKey: key))
    }
}

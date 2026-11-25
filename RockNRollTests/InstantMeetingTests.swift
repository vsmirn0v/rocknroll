import ConferenceCore
import MeetingEngine
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class InstantMeetingTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func makeModel(suiteName: String) -> (ConferenceModel, UserDefaults, UIViewController) {
        let preferences = UserDefaults(suiteName: suiteName)!
        preferences.set("Alex", forKey: "savedDisplayName")
        let detector = VendorEndpointResolver.makeDetector()
        let reminders = CalendarReminderCoordinator(
            preferences: preferences,
            storage: CalendarReminderTests.Storage(),
            notifications: CalendarReminderTests.Notifications()
        )
        let calendar = CalendarMeetingStore(
            reader: CalendarMeetingStoreTests.Reader(events: []),
            detector: detector,
            preferences: preferences,
            storage: RoomSyncCoordinatorTests.Storage(),
            reminders: reminders
        )
        let model = ConferenceModel(
            history: RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage()),
            preferences: preferences,
            engineDetector: detector,
            calendar: calendar
        )
        model.installSyncFixture(
            RoomSyncCoordinator(
                history: model.history,
                name: model.displayName,
                preferences: preferences,
                storage: RoomSyncCoordinatorTests.Storage(),
                transport: RoomSyncCoordinatorTests.Cloud()
            )
        )
        model.installContinuationFixture(model.makeContinuationCoordinator(preferences: preferences))
        model.setup.suspendForMeeting()
        let container = UIViewController()
        model.configure(container: container)
        return (model, preferences, container)
    }

    func testStartInstantRoomCopiesLinkSavesOriginAndStartsJoin() async throws {
        let suiteName = "InstantMeetingTests.Success.\(UUID().uuidString)"
        let (model, preferences, container) = makeModel(suiteName: suiteName)
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let origin = URL(string: "https://salutejazz.ru")!
        let invitation = URL(string: "https://salutejazz.ru/calls/instant42?psw=secret")!
        let destination = try JoinDestination.verified(invitation, engine: .guest)

        var copiedURLs: [URL] = []
        var joinedTargets: [JoinDestination] = []
        var capturedOptions: RoomCreationOptions?
        let joinedExpectation = expectation(description: "Instant room starts join transport")

        model.copyInvitationToClipboard = { url in
            copiedURLs.append(url)
        }
        model.createInstantRoomHandler = { passedOrigin, _, options in
            XCTAssertEqual(passedOrigin, origin)
            capturedOptions = options
            return CreatedMeetingRoom(
                origin: passedOrigin,
                engine: .guest,
                roomID: "instant42",
                title: options.title,
                invitationURL: invitation,
                destination: destination
            )
        }
        model.joinTransportForTesting = { target, _ in
            joinedTargets.append(target)
            joinedExpectation.fulfill()
        }

        await model.startInstantRoom(on: origin, explicitEngine: .guest)
        await fulfillment(of: [joinedExpectation], timeout: 5)
        withExtendedLifetime(container) {}

        XCTAssertFalse(model.isCreatingInstantRoom)
        XCTAssertNil(model.instantRoomError)
        XCTAssertNil(model.instantRoomAuthChallengeOrigin)
        XCTAssertEqual(capturedOptions?.allowGuests, true)
        XCTAssertEqual(capturedOptions?.enableLobby, false)
        XCTAssertEqual(capturedOptions?.title, L("%@’s meeting", "Alex"))
        XCTAssertEqual(copiedURLs, [invitation])
        XCTAssertEqual(joinedTargets, [destination])
        XCTAssertEqual(model.invite, invitation.absoluteString)
        XCTAssertEqual(InstantRoomPreferences.loadLastOrigin(defaults: preferences), origin)
    }

    func testStartInstantRoomSignInRequiredSetsChallengeOriginAndError() async {
        let suiteName = "InstantMeetingTests.Auth.\(UUID().uuidString)"
        let (model, preferences, container) = makeModel(suiteName: suiteName)
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let origin = URL(string: "https://meet.corp.example.test")!
        model.createInstantRoomHandler = { requestedOrigin, _, _ in
            throw RoomCreationError.signInRequired(origin: requestedOrigin, engine: .trueconf)
        }

        await model.startInstantRoom(on: origin, explicitEngine: .trueconf)
        withExtendedLifetime(container) {}

        XCTAssertFalse(model.isCreatingInstantRoom)
        XCTAssertEqual(model.instantRoomAuthChallengeOrigin, origin)
        XCTAssertEqual(model.pendingInstantRoomOrigin, origin)
        XCTAssertNotNil(model.instantRoomError)
    }

    func testStartInstantRoomFailureClearsBusyAndSurfacesError() async {
        let suiteName = "InstantMeetingTests.Failure.\(UUID().uuidString)"
        let (model, preferences, container) = makeModel(suiteName: suiteName)
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let origin = URL(string: "https://salutejazz.ru")!
        model.createInstantRoomHandler = { _, _, _ in
            throw RoomCreationError.requestFailed(503, "Service unavailable")
        }

        await model.startInstantRoom(on: origin, explicitEngine: .guest)
        withExtendedLifetime(container) {}

        XCTAssertFalse(model.isCreatingInstantRoom)
        XCTAssertNil(model.instantRoomAuthChallengeOrigin)
        XCTAssertEqual(model.instantRoomError, "Service unavailable")
    }

    func testWaitingRoomCardShowsCopiedBadgeAndCopyToast() throws {
        let url = URL(string: "https://salutejazz.ru/calls/instant99?psw=abc")!
        let call = RockCallViewController(
            title: "Alex’s meeting",
            catchUp: CatchUpStore(),
            chat: ChatStore(),
            invitationURL: url,
            roomIdentifier: "instant99",
            invitationCopiedOnJoin: true
        )
        call.loadViewIfNeeded()
        call.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        call.render(snapshot: CallMediaSnapshot(participants: []))
        call.view.layoutIfNeeded()

        let allViews = descendants(call.view)
        let labels = allViews.compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(labels.contains(L("You're connected. Waiting for others.")))
        XCTAssertTrue(labels.contains(L("Link copied · Ready to paste")))

        let buttons = allViews.compactMap { $0 as? UIButton }
        let titles = buttons.compactMap { $0.configuration?.title ?? $0.currentTitle }
        XCTAssertTrue(titles.contains(L("Invite musicians")))
        XCTAssertTrue(titles.contains(L("Copy link")))

        XCTAssertTrue(allViews.contains { $0.accessibilityIdentifier == "waiting.copied-badge" })

        let toast = try XCTUnwrap(allViews.first { $0.accessibilityIdentifier == "call.copied-link-toast" })
        XCTAssertTrue(toast.isHidden)

        let copyButton = try XCTUnwrap(buttons.first { ($0.configuration?.title ?? $0.currentTitle) == L("Copy link") })
        copyButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(UIPasteboard.general.url, url)
        XCTAssertFalse(toast.isHidden)
    }
}

import UIKit
import CloudKit
import ConferenceCore

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    static let instantMeetingShortcutType = "dev.vsmirn0v.conferenceguest.instantRoom"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        AppDiagnostics.start()
        #if DEBUG
        ColdJoinDeviceFixture.bootstrap()
        #endif
        NativeH264ColorEncoder.prepare()
        CalendarReminderBroker.shared.install()
        application.shortcutItems = [
            UIApplicationShortcutItem(
                type: Self.instantMeetingShortcutType,
                localizedTitle: L("Instant meeting"),
                localizedSubtitle: L("Create, copy link & join"),
                icon: UIApplicationShortcutIcon(systemImageName: "video.badge.plus")
            )
        ]
        return true
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let subscription = CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID
        guard subscription == "SavedJamsChanges" ||
                subscription == "ActiveJamsChanges" ||
                subscription == "MeetingLibraryChanges" ||
                subscription == "MeetingTranscriptsChanges" ||
                subscription == "MeetingScheduleChanges" else {
            completionHandler(.noData); return
        }
        Task { @MainActor in
            if subscription == "ActiveJamsChanges" {
                await MeetingContinuationCoordinator.active?.refresh()
                completionHandler(.newData); return
            }
            if subscription == "MeetingLibraryChanges" ||
                subscription == "MeetingTranscriptsChanges" ||
                subscription == "MeetingScheduleChanges" {
                let zones: Set<IOSWorkspaceCoordinator.SyncZoneKind> = switch subscription {
                case "MeetingLibraryChanges": [.library]
                case "MeetingTranscriptsChanges": [.transcripts]
                default: [.schedule]
                }
                if let workspace = IOSWorkspaceCoordinator.active {
                    if let savedAt = workspace.lastCloudSaveCompletedAt, Date().timeIntervalSince(savedAt) < 5 {
                        completionHandler(.noData); return
                    }
                    workspace.scheduleSync(zones: zones, delayMilliseconds: 250)
                }
                completionHandler(.newData); return
            }
            guard let sync = RoomSyncCoordinator.active, sync.enabled else { completionHandler(.noData); return }
            await sync.synchronizeForNotification()
            completionHandler(.newData)
        }
    }
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

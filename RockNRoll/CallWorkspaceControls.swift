import Combine
import Foundation
import LinkPresentation
import UIKit

/// Shared actions and visible media state for the call and its conversation view.
@MainActor
final class CallWorkspaceControls: ObservableObject {
    @Published var microphoneAvailable = true
    @Published var microphoneOn = false
    @Published var cameraOn = false
    @Published var onHold = false
    @Published var speakerOn = true
    @Published var usesBuiltInOutput = false
    @Published var routeName = L("Audio output")
    @Published var meetingSoundEnabled = true
    @Published var canSetMeetingSound = false
    @Published var meetingVolume = 1.0
    @Published var assistantMode: IOSMeetingAssistantMode = .off
    @Published var assistantPaused = false

    var invitationURL: URL?
    var roomIdentifier: String?
    var meetingTitle: String?
    var onInvitationCopied: (() -> Void)?
    var toggleMicrophone: (() -> Void)?
    var toggleCamera: (() -> Void)?
    var toggleSpeaker: (() -> Void)?
    var willChooseAudioOutput: (() -> Void)?
    var setMeetingSound: ((Bool) -> Void)?
    var setMeetingVolume: ((Double) -> Void)?
    var leave: (() -> Void)?
    var openReactions: ((UIView, @escaping (Bool) -> Void) -> Void)?
    var openVoiceReply: (() -> Void)?
    var openTranscriptionSettings: (() -> Void)?
    var openNotes: (() -> Void)?
    var openBoard: (() -> Void)?

    func copyInvitation() {
        guard let invitationURL else { return }
        UIPasteboard.general.url = invitationURL
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onInvitationCopied?()
    }

    func shareInvitation(from view: UIView) {
        guard let invitationURL else { return }
        guard let presenter = view.callActionPresenter else { return }
        let source = InvitationActivityItemSource(url: invitationURL, title: meetingTitle)
        let sheet = UIActivityViewController(activityItems: [source], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController { popover.sourceView = view.callActionPresentationAnchor }
        presenter.present(sheet, animated: true) { [weak sheet] in
            sheet?.view.accessibilityIdentifier = "Invitation sharing"
        }
    }

    func showDetails(from view: UIView, presenter: UIViewController?, title: String, lines: [String],
                     actions: [(String, () -> Void)] = []) {
        guard let presenter, presenter.presentedViewController == nil else { return }
        let sheet = UIAlertController(title: title, message: lines.filter { !$0.isEmpty }.joined(separator: "\n"),
                                      preferredStyle: .actionSheet)
        for (title, action) in actions {
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak sheet] _ in
                sheet?.dismiss(animated: true, completion: action)
            })
        }
        if invitationURL != nil {
            sheet.addAction(UIAlertAction(title: L("Invite musicians"), style: .default) { [weak self, weak view, weak sheet] _ in
                // Present the system share sheet after the details sheet has finished closing.
                sheet?.dismiss(animated: true) { [weak self, weak view] in
                    if let view { self?.shareInvitation(from: view) }
                }
            })
            sheet.addAction(UIAlertAction(title: L("Copy link"), style: .default) { [weak self] _ in self?.copyInvitation() })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        let anchor = view.callActionPresentationAnchor
        sheet.popoverPresentationController?.sourceView = anchor
        sheet.popoverPresentationController?.sourceRect = anchor.bounds
        presenter.present(sheet, animated: true)
    }
}

private final class InvitationActivityItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let title: String?

    init(url: URL, title: String?) {
        self.url = url
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        if let title, !title.isEmpty {
            metadata.title = title
        }
        return metadata
    }
}

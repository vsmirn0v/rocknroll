import ConferenceCore
import SwiftUI
import UIKit

struct IOSMeetingSnapshotsSection: View {
    let snapshots: [MeetingSnapshotRecord]
    let onSelect: (MeetingSnapshotRecord) -> Void

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(snapshots) { snap in
                        Button {
                            onSelect(snap)
                        } label: {
                            IOSSnapshotThumbnailCard(record: snap)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(L("Visual Snapshots (%ld)", snapshots.count))
        }
    }
}

private struct IOSSnapshotThumbnailCard: View {
    let record: MeetingSnapshotRecord
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.88))
                    .frame(width: 156, height: 92)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 156, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: record.scope.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 156, height: 92)
                }
                Label(record.scope.title, systemImage: record.scope.symbol)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.72), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(5)
            }
            HStack {
                Text(record.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(record.capturedAt, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !record.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(record.caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 156, alignment: .leading)
        .padding(7)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .task(id: record.relativeFileName) {
            let url = await MeetingSnapshotStore.shared.imageURL(for: record)
            thumbnail = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)
            }.value
        }
    }
}

struct IOSMeetingSnapshotLightboxView: View {
    let record: MeetingSnapshotRecord
    let onSaveCaption: (String) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var imageURL: URL?
    @State private var caption: String
    @State private var copiedOCR = false

    init(record: MeetingSnapshotRecord, onSaveCaption: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.record = record
        self.onSaveCaption = onSaveCaption
        self.onDelete = onDelete
        _caption = State(initialValue: record.caption)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    HStack {
                        Label(record.displayTitle, systemImage: record.scope.symbol)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(record.pixelWidth)×\(record.pixelHeight) · \(record.fileExtension.uppercased())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(L("Caption")) {
                    TextField(L("Add a note for this snapshot…"), text: $caption, axis: .vertical)
                        .lineLimit(2...4)
                    if caption != record.caption {
                        Button(L("Save caption")) {
                            onSaveCaption(caption)
                        }
                    }
                }

                if !record.transcriptExcerpt.isEmpty {
                    Section(L("Transcript moment")) {
                        Text(record.transcriptExcerpt)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    if record.ocrText.isEmpty {
                        Text(L("No text detected in this frame."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(record.ocrText)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = record.ocrText
                            copiedOCR = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copiedOCR = false
                            }
                        } label: {
                            Label(copiedOCR ? L("Copied") : L("Copy recognized text"), systemImage: copiedOCR ? "checkmark" : "doc.on.doc")
                        }
                    }
                } header: {
                    Text(L("Recognized text (OCR)"))
                }

                Section {
                    if let imageURL {
                        ShareLink(item: imageURL) {
                            Label(L("Share snapshot"), systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label(L("Delete snapshot"), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(record.capturedAt.formatted(date: .omitted, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) {
                        if caption != record.caption { onSaveCaption(caption) }
                        dismiss()
                    }
                }
            }
        }
        .task(id: record.id) {
            let url = await MeetingSnapshotStore.shared.imageURL(for: record)
            imageURL = url
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)
            }.value
        }
    }
}

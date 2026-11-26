import AppKit
import ConferenceCore
import ImageIO
import SwiftUI

struct MacMeetingSnapshotsStripView: View {
    let snapshots: [MeetingSnapshotRecord]
    let onSaveCaption: (MeetingSnapshotRecord, String) -> Void
    let onDelete: (MeetingSnapshotRecord) -> Void

    @State private var selectedSnapshotID: UUID?

    private var selectedBinding: Binding<MeetingSnapshotRecord?> {
        Binding(
            get: {
                guard let id = selectedSnapshotID else { return nil }
                return snapshots.first(where: { $0.id == id })
            },
            set: { selectedSnapshotID = $0?.id }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("Visual snapshots (%ld)", snapshots.count), systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                Spacer()
                Text(L("Click any frame for Live Text & details"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(snapshots) { snap in
                        Button {
                            selectedSnapshotID = snap.id
                        } label: {
                            MacSnapshotCard(record: snap)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .sheet(item: selectedBinding) { snap in
            MacMeetingSnapshotLightbox(
                record: snap,
                onSaveCaption: { caption in
                    onSaveCaption(snap, caption)
                },
                onDelete: {
                    selectedSnapshotID = nil
                    onDelete(snap)
                }
            )
        }
    }
}

private struct MacSnapshotCard: View {
    let record: MeetingSnapshotRecord
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.85))
                    .frame(width: 196, height: 112)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 196, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: record.scope.symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 196, height: 112)
                }
                Label(record.scope.title, systemImage: record.scope.symbol)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.72), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
            HStack {
                Text(record.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(record.capturedAt, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !record.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(record.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 196, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .task(id: record.relativeFileName) {
            let url = await MeetingSnapshotStore.shared.imageURL(for: record)
            let cgImage: CGImage? = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }.value
            if let cgImage {
                thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
    }
}

struct MacMeetingSnapshotLightbox: View {
    let record: MeetingSnapshotRecord
    let onSaveCaption: (String) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var imageURL: URL?
    @State private var caption: String
    @State private var copiedOCR = false
    @State private var copiedImage = false

    init(record: MeetingSnapshotRecord, onSaveCaption: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.record = record
        self.onSaveCaption = onSaveCaption
        self.onDelete = onDelete
        _caption = State(initialValue: record.caption)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayTitle).font(.headline)
                    Text("\(record.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.pixelWidth)×\(record.pixelHeight) · \(record.fileExtension.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let image {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                        copiedImage = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedImage = false
                        }
                    }
                } label: {
                    Label(copiedImage ? L("Copied") : L("Copy image"), systemImage: copiedImage ? "checkmark" : "doc.on.doc")
                }
                .disabled(image == nil)

                if let imageURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([imageURL])
                    } label: {
                        Label(L("Reveal in Finder"), systemImage: "folder")
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Label(L("Delete"), systemImage: "trash")
                }
                Button(L("Done")) {
                    if caption != record.caption { onSaveCaption(caption) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(12)
                    } else {
                        ProgressView()
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("Caption")).font(.headline)
                            TextField(L("Add a note for this snapshot…"), text: $caption, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...4)
                            Button(L("Save caption")) {
                                onSaveCaption(caption)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(caption == record.caption)
                        }

                        if !record.transcriptExcerpt.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("Transcript moment")).font(.headline)
                                Text(record.transcriptExcerpt)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }

                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(L("Recognized text (OCR)")).font(.headline)
                                Spacer()
                                if !record.ocrText.isEmpty {
                                    Button(copiedOCR ? L("Copied") : L("Copy text")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(record.ocrText, forType: .string)
                                        copiedOCR = true
                                        Task {
                                            try? await Task.sleep(for: .seconds(1.5))
                                            copiedOCR = false
                                        }
                                    }
                                    .controlSize(.small)
                                }
                            }
                            if record.ocrText.isEmpty {
                                Text(L("No text detected in this frame."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(record.ocrText)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(14)
                }
                .frame(width: 280)
            }
        }
        .frame(width: 860, height: 560)
        .task(id: record.id) {
            let url = await MeetingSnapshotStore.shared.imageURL(for: record)
            imageURL = url
            let cgImage: CGImage? = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }.value
            if let cgImage {
                image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
    }
}

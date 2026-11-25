@testable import ConferenceCore
import CoreGraphics
import Foundation
import XCTest

final class MeetingSnapshotsTests: XCTestCase {
    private func makeTestImage(width: Int = 64, height: Int = 48, red: UInt8 = 40, green: UInt8 = 120, blue: UInt8 = 220) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = red
            pixels[index + 1] = green
            pixels[index + 2] = blue
            pixels[index + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    func testPreferencesDefaultsAndOverrides() {
        let suiteName = "MeetingSnapshotsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MeetingSnapshotPreferences.imageFormat(defaults: defaults), .jpeg)
        XCTAssertTrue(MeetingSnapshotPreferences.isIOSHardwareScreenshotBridgeEnabled(defaults: defaults))

        MeetingSnapshotPreferences.setImageFormat(.mixedPNGAndHEIC, defaults: defaults)
        MeetingSnapshotPreferences.setIOSHardwareScreenshotBridgeEnabled(false, defaults: defaults)

        XCTAssertEqual(MeetingSnapshotPreferences.imageFormat(defaults: defaults), .mixedPNGAndHEIC)
        XCTAssertFalse(MeetingSnapshotPreferences.isIOSHardwareScreenshotBridgeEnabled(defaults: defaults))
    }

    func testFormatExtensionsAndEncoding() {
        XCTAssertEqual(MeetingSnapshotImageFormat.jpeg.fileExtension(for: .screenShare), "jpg")
        XCTAssertEqual(MeetingSnapshotImageFormat.png.fileExtension(for: .participantCamera), "png")
        XCTAssertEqual(MeetingSnapshotImageFormat.mixedPNGAndHEIC.fileExtension(for: .screenShare), "png")
        XCTAssertEqual(MeetingSnapshotImageFormat.mixedPNGAndHEIC.fileExtension(for: .participantCamera), "heic")
        XCTAssertEqual(MeetingSnapshotImageFormat.mixedPNGAndHEIC.fileExtension(for: .fullStage), "heic")

        let image = makeTestImage(width: 120, height: 80)
        let jpeg = MeetingSnapshotEncoder.encode(image, scope: .screenShare, format: .jpeg)
        XCTAssertNotNil(jpeg)
        XCTAssertEqual(jpeg?.fileExtension, "jpg")
        XCTAssertGreaterThan(jpeg?.data.count ?? 0, 100)

        let png = MeetingSnapshotEncoder.encode(image, scope: .screenShare, format: .png)
        XCTAssertNotNil(png)
        XCTAssertEqual(png?.fileExtension, "png")

        let mixedCam = MeetingSnapshotEncoder.encode(image, scope: .participantCamera, format: .mixedPNGAndHEIC)
        XCTAssertNotNil(mixedCam)
        XCTAssertTrue(["heic", "jpg"].contains(mixedCam?.fileExtension ?? ""))
    }

    func testStageCompositorWithShareAndCameras() {
        let share = MeetingSnapshotCompositor.TileInput(
            image: makeTestImage(width: 320, height: 180, red: 20, green: 80, blue: 200),
            label: "Alex",
            isScreenShare: true
        )
        let cam = MeetingSnapshotCompositor.TileInput(
            image: makeTestImage(width: 160, height: 120, red: 200, green: 60, blue: 40),
            label: "Maya",
            isScreenShare: false
        )
        let stage = MeetingSnapshotCompositor.composeStage(tiles: [share, cam], canvasSize: CGSize(width: 640, height: 360))
        XCTAssertNotNil(stage)
        XCTAssertEqual(stage?.width, 640)
        XCTAssertEqual(stage?.height, 360)
    }

    func testDurableStoreCRUDAndRetroactiveFlipAndTTLPurge() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = MeetingSnapshotStore(root: tempRoot)
        let sessionID = UUID()
        let shareImg = makeTestImage(width: 100, height: 60, red: 10, green: 140, blue: 220)
        let camImg = makeTestImage(width: 80, height: 80, red: 220, green: 80, blue: 40)

        let encodedShare = try XCTUnwrap(MeetingSnapshotEncoder.encode(shareImg, scope: .screenShare, format: .jpeg))
        let saved = try await store.save(
            sessionID: sessionID,
            scope: .screenShare,
            sourceID: "share:alex",
            sourceName: "Alex",
            encoded: encodedShare,
            transcriptExcerpt: "Cap cache TTL at 30s"
        )

        var fetched = await store.snapshots(for: sessionID)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.sourceName, "Alex")

        let buffer = RetroactiveSnapshotBuffer(ttl: .milliseconds(250))
        await buffer.store(
            snapshotID: saved.id,
            sessionID: sessionID,
            candidates: [
                .init(id: "share", scope: .screenShare, sourceID: "share:alex", sourceName: "Alex", label: "Screen · Alex", image: shareImg),
                .init(id: "cam", scope: .participantCamera, sourceID: "cam:maya", sourceName: "Maya", label: "Camera · Maya", image: camImg),
                .init(id: "stage", scope: .fullStage, sourceID: "stage", sourceName: "Full stage", label: "Full stage", image: nil)
            ],
            activeCandidateID: "share"
        )

        let flippedToCam = try await buffer.flip(snapshotID: saved.id, toCandidateID: "cam", format: .png, store: store)
        XCTAssertEqual(flippedToCam?.scope, .participantCamera)
        XCTAssertEqual(flippedToCam?.sourceName, "Maya")
        XCTAssertEqual(flippedToCam?.fileExtension, "png")

        let flippedToStage = try await buffer.flip(snapshotID: saved.id, toCandidateID: "stage", format: .jpeg, store: store)
        XCTAssertEqual(flippedToStage?.scope, .fullStage)
        XCTAssertEqual(flippedToStage?.pixelWidth, 1920)
        XCTAssertEqual(flippedToStage?.pixelHeight, 1080)

        await buffer.store(
            snapshotID: saved.id,
            sessionID: sessionID,
            candidates: [.init(id: "share", scope: .screenShare, sourceID: "share:alex", sourceName: "Alex", label: "Screen · Alex", image: shareImg)],
            activeCandidateID: "share"
        )
        try await Task.sleep(for: .milliseconds(400))
        let hasActiveAfterTTL = await buffer.hasActiveSlot
        XCTAssertFalse(hasActiveAfterTTL)

        _ = try await store.updateCaption("Approved 30s TTL", snapshotID: saved.id, sessionID: sessionID)
        _ = try await store.updateOCRText("Edge Gateway TTL = 30s", snapshotID: saved.id, sessionID: sessionID)
        fetched = await store.snapshots(for: sessionID)
        XCTAssertEqual(fetched.first?.caption, "Approved 30s TTL")
        XCTAssertEqual(fetched.first?.ocrText, "Edge Gateway TTL = 30s")

        let md = MeetingSnapshotMarkdown.obsidianSection(snapshots: fetched)
        XCTAssertTrue(md.contains("## Visual Snapshots"))
        XCTAssertTrue(md.contains("Approved 30s TTL"))
        XCTAssertTrue(md.contains("Edge Gateway TTL = 30s"))

        let promptContext = try XCTUnwrap(MeetingSnapshotMarkdown.summaryPromptContext(snapshots: fetched))
        XCTAssertTrue(promptContext.contains("Approved 30s TTL"))
        XCTAssertTrue(promptContext.contains("Edge Gateway TTL = 30s"))

        try await store.delete(snapshotID: saved.id, sessionID: sessionID)
        let afterDelete = await store.snapshots(for: sessionID)
        XCTAssertTrue(afterDelete.isEmpty)
    }
}

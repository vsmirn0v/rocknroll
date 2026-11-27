#if NATIVE_DIRECT_UPDATES
import XCTest
@testable import RockNativeDesktop

final class UpdateChangelogTests: XCTestCase {
    private let sampleMarkdown = """
    ### 0.3.0 (167) — 2026-11-27
    - Show update changelog diff before restarting
    - Harden audio handoff across sleep

    ### 0.3.0 (166) — 2026-11-26
    - Guard SharedAudioEngine unmute

    ### 0.3.0 (165) — 2026-11-25
    - Improve ICE relay recovery
    """

    func testSingleBuildHopSlicesOnlyNewBuild() {
        let diff = UpdateChangelogParser.slice(
            markdown: sampleMarkdown,
            installedBuild: 166,
            targetBuild: 167,
            installedVersion: "0.3.0",
            targetVersion: "0.3.0"
        )
        XCTAssertEqual(diff.sections.map(\.build), [167])
        XCTAssertEqual(diff.sections.first?.items, [
            "Show update changelog diff before restarting",
            "Harden audio handoff across sleep",
        ])
        XCTAssertFalse(diff.hasOlderUnshownChanges)
        XCTAssertNil(diff.fallbackMarkdown)
    }

    func testMultiBuildHopIncludesIntermediateBuildsAndExcludesInstalledAndFuture() {
        let markdownWithFuture = sampleMarkdown + "\n\n### 0.3.0 (168) — 2026-11-28\n- Future item"
        let diff = UpdateChangelogParser.slice(
            markdown: markdownWithFuture,
            installedBuild: 165,
            targetBuild: 167,
            installedVersion: "0.3.0",
            targetVersion: "0.3.0"
        )
        XCTAssertEqual(diff.sections.map(\.build), [167, 166])
        XCTAssertEqual(diff.totalItemCount, 3)
        XCTAssertFalse(diff.hasOlderUnshownChanges)
    }

    func testOlderInstalledBuildFlagsOmittedHistory() {
        let diff = UpdateChangelogParser.slice(
            markdown: sampleMarkdown,
            installedBuild: 53,
            targetBuild: 167,
            installedVersion: "0.3.0",
            targetVersion: "0.3.0"
        )
        XCTAssertEqual(diff.sections.map(\.build), [167, 166, 165])
        XCTAssertTrue(diff.hasOlderUnshownChanges)
        let rendered = diff.attributedString().string
        XCTAssertTrue(rendered.contains("167"))
        XCTAssertTrue(rendered.contains("53"))
    }

    func testDeduplicatesRepeatedBuildHeadingsAndFallsBackOnUnstructuredNotes() {
        let duplicate = """
        ### 0.3.0 (167) — 2026-11-27
        - First copy

        ### 0.3.0 (167) — 2026-11-27
        - Duplicate copy
        """
        let diff = UpdateChangelogParser.slice(
            markdown: duplicate,
            installedBuild: 166,
            targetBuild: 167,
            installedVersion: "0.3.0",
            targetVersion: "0.3.0"
        )
        XCTAssertEqual(diff.sections.count, 1)
        XCTAssertEqual(diff.sections[0].items, ["First copy"])

        let plain = UpdateChangelogParser.slice(
            markdown: "Important security update.",
            installedBuild: 166,
            targetBuild: 167,
            installedVersion: "0.3.0",
            targetVersion: "0.3.0"
        )
        XCTAssertTrue(plain.sections.isEmpty)
        XCTAssertEqual(plain.fallbackMarkdown, "Important security update.")
        XCTAssertFalse(plain.isEmpty)
        XCTAssertTrue(plain.attributedString().string.contains("Important security update."))
    }

    func testCacheRoundTripsAndCapsSize() {
        let suite = "UpdateChangelogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        UpdateChangelogCache.save(markdown: sampleMarkdown, targetBuild: 167, targetVersion: "0.3.0", defaults: defaults)
        let loaded = UpdateChangelogCache.load(targetBuild: 167, defaults: defaults)
        XCTAssertEqual(loaded?.targetVersion, "0.3.0")
        XCTAssertTrue(loaded?.markdown.contains("167") == true)
        XCTAssertNil(UpdateChangelogCache.load(targetBuild: 166, defaults: defaults))

        var huge = ""
        for build in stride(from: 400, through: 100, by: -1) {
            huge += "### 0.3.0 (\(build)) — 2026-11-27\n- " + String(repeating: "x", count: 350) + "\n\n"
        }
        UpdateChangelogCache.save(markdown: huge, targetBuild: 400, targetVersion: "0.3.0", defaults: defaults)
        let stored = defaults.data(forKey: UpdateChangelogCache.storageKey)
        XCTAssertNotNil(stored)
        XCTAssertLessThanOrEqual(stored?.count ?? Int.max, UpdateChangelogCache.maxBytes)
        let loadedHuge = UpdateChangelogCache.load(targetBuild: 400, defaults: defaults)
        XCTAssertTrue(loadedHuge?.markdown.contains("0.3.0 (400)") == true)
    }
}
#endif

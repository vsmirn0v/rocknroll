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

    func testCacheLoadLatestReturnsMostRecentSavedPayload() {
        let suite = "UpdateChangelogLatestTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(UpdateChangelogCache.loadLatest(defaults: defaults))
        UpdateChangelogCache.save(markdown: sampleMarkdown, targetBuild: 167, targetVersion: "0.3.0", channel: "beta", defaults: defaults)
        let loaded = UpdateChangelogCache.loadLatest(defaults: defaults)
        XCTAssertEqual(loaded?.targetBuild, 167)
        XCTAssertEqual(loaded?.targetVersion, "0.3.0")
        XCTAssertEqual(loaded?.channel, "beta")
        XCTAssertTrue(loaded?.markdown.contains("167") == true)
    }

    func testLedgerParsesDeduplicatesAndSortsBundledJSON() throws {
        let json = """
        {
          "schemaVersion": 1,
          "mac": [
            {
              "build": 53,
              "version": "0.3.0",
              "channel": "stable",
              "date": "2026-11-01",
              "commit": "aaaa1111",
              "items": ["  Initial stable release  "]
            },
            {
              "build": 168,
              "version": "0.3.0",
              "channel": "beta",
              "date": "2026-11-27",
              "commit": "bbbb2222",
              "items": ["Reduce CPU in large rooms", ""]
            },
            {
              "build": 168,
              "version": "0.3.0",
              "channel": "beta",
              "date": "2026-11-27",
              "commit": "cccc3333",
              "items": ["Duplicate entry should be ignored"]
            }
          ],
          "ios": []
        }
        """
        let sections = UpdateChangelogLedger.parseJSON(Data(json.utf8))
        XCTAssertEqual(sections.map(\.build), [168, 53])
        XCTAssertEqual(sections[0].channel, "beta")
        XCTAssertEqual(sections[0].items, ["Reduce CPU in large rooms"])
        XCTAssertEqual(sections[1].channel, "stable")
        XCTAssertEqual(sections[1].items, ["Initial stable release"])

        let invalid = Data(#"{"schemaVersion": 2, "mac": []}"#.utf8)
        XCTAssertTrue(UpdateChangelogLedger.parseJSON(invalid).isEmpty)
    }

    func testLedgerLoadsRealBundledChangelogResource() {
        let sections = UpdateChangelogLedger.loadBundled(from: .main)
        XCTAssertFalse(sections.isEmpty, "changelog.json must be bundled in direct builds")
        XCTAssertEqual(sections, sections.sorted { $0.build > $1.build })
        XCTAssertGreaterThanOrEqual(sections.first?.build ?? 0, 168)
    }

    func testLedgerMergesBundledAndSupplementalAndFiltersByChannelAndQuery() {
        let bundled = [
            UpdateChangelogSection(version: "0.3.0", build: 168, date: "2026-11-27", items: ["Silence-gate transcription"], channel: "beta"),
            UpdateChangelogSection(version: "0.3.0", build: 53, date: "2026-11-01", items: ["Initial macOS release"], channel: "stable"),
        ]
        let supplemental = [
            UpdateChangelogSection(version: "0.3.0", build: 169, date: "2026-11-28", items: ["Browse changelog in Updates tab"]),
            UpdateChangelogSection(version: "0.3.0", build: 168, date: "2026-11-27", items: ["Server markdown bullet"]),
        ]
        let merged = UpdateChangelogLedger.merge(bundled: bundled, supplemental: supplemental)
        XCTAssertEqual(merged.map(\.build), [169, 168, 53])
        XCTAssertNil(merged[0].channel)
        XCTAssertEqual(merged[1].channel, "beta", "Existing bundled channel metadata must be preserved")
        XCTAssertEqual(merged[1].items, ["Silence-gate transcription"])

        XCTAssertEqual(UpdateChangelogLedger.filter(merged, channel: .all, query: "").map(\.build), [169, 168, 53])
        XCTAssertEqual(UpdateChangelogLedger.filter(merged, channel: .stable, query: "").map(\.build), [53])
        XCTAssertEqual(UpdateChangelogLedger.filter(merged, channel: .beta, query: "").map(\.build), [168])
        XCTAssertEqual(UpdateChangelogLedger.filter(merged, channel: .all, query: "SILENCE transcription").map(\.build), [168])
        XCTAssertEqual(UpdateChangelogLedger.filter(merged, channel: .all, query: "(169) updates").map(\.build), [169])

        let stamped = UpdateChangelogParser.parseSections(sampleMarkdown, targetBuild: 167, targetChannel: "beta")
        XCTAssertEqual(stamped.first { $0.build == 167 }?.channel, "beta")
        XCTAssertNil(stamped.first { $0.build == 166 }?.channel)
    }
}
#endif

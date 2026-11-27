#if NATIVE_DIRECT_UPDATES
import AppKit
import ConferenceCore
import Foundation

struct UpdateChangelogSection: Equatable, Identifiable, Sendable {
    let version: String
    let build: Int
    let date: String?
    let items: [String]
    var id: Int { build }
}

struct UpdateChangelogDiff: Equatable, Sendable {
    let installedVersion: String?
    let installedBuild: Int
    let targetVersion: String
    let targetBuild: Int
    let sections: [UpdateChangelogSection]
    let fallbackMarkdown: String?
    let hasOlderUnshownChanges: Bool

    var isEmpty: Bool {
        sections.isEmpty && (fallbackMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var totalItemCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }

    func bannerSummary() -> String? {
        if sections.count == 1, let first = sections[0].items.first {
            let extra = sections[0].items.count - 1
            return extra > 0 ? L("%@ (+%ld more)", first, extra) : first
        }
        if sections.count > 1 {
            if installedBuild > 0 {
                return L("%ld updates (%ld changes) since build %ld", sections.count, totalItemCount, installedBuild)
            }
            return L("%ld updates (%ld changes)", sections.count, totalItemCount)
        }
        if let fallback = fallbackMarkdown?.split(whereSeparator: \.isNewline).first {
            return String(fallback)
        }
        return nil
    }

    func attributedString() -> NSAttributedString {
        if sections.isEmpty {
            guard let fallback = fallbackMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty else {
                return NSAttributedString(string: "")
            }
            if let md = try? NSMutableAttributedString(
                markdown: fallback,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                let fullRange = NSRange(location: 0, length: md.length)
                md.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
                return md
            }
            return NSAttributedString(string: fallback, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
            ])
        }

        let result = NSMutableAttributedString()
        let titleText = installedBuild > 0
            ? L("Changes since %@ (%ld)", installedVersion ?? "?", installedBuild)
            : L("What's new in %@ (%ld)", targetVersion, targetBuild)
        let titlePara = NSMutableParagraphStyle()
        titlePara.paragraphSpacing = 8
        result.append(NSAttributedString(string: titleText + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: titlePara,
        ]))

        let headerPara = NSMutableParagraphStyle()
        headerPara.paragraphSpacingBefore = 6
        headerPara.paragraphSpacing = 3
        let bulletPara = NSMutableParagraphStyle()
        bulletPara.firstLineHeadIndent = 4
        bulletPara.headIndent = 15
        bulletPara.paragraphSpacing = 3

        for (index, section) in sections.enumerated() {
            let heading = section.date.map { "\(section.version) (\(section.build)) — \($0)" }
                ?? "\(section.version) (\(section.build))"
            result.append(NSAttributedString(string: heading + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: headerPara,
            ]))
            for (itemIndex, item) in section.items.enumerated() {
                let isVeryLast = index == sections.count - 1 && itemIndex == section.items.count - 1 && !hasOlderUnshownChanges
                let suffix = isVeryLast ? "" : "\n"
                result.append(NSAttributedString(string: "• \(item)\(suffix)", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: bulletPara,
                ]))
            }
        }

        if hasOlderUnshownChanges, let oldestBuild = sections.last?.build {
            let footerPara = NSMutableParagraphStyle()
            footerPara.paragraphSpacingBefore = 8
            result.append(NSAttributedString(
                string: L("Older release notes before build %ld are omitted.", oldestBuild),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: footerPara,
                ]
            ))
        }
        return result
    }
}

enum UpdateChangelogParser {
    private static let headingRegex = try! NSRegularExpression(
        pattern: #"^#{1,4}\s+([A-Za-z0-9][A-Za-z0-9._-]*)\s*\((\d+)\)(?:\s*[—–-]\s*(.+?))?\s*$"#
    )
    private static let bulletRegex = try! NSRegularExpression(
        pattern: #"^[-*•]\s+(.+?)\s*$"#
    )

    static func parseSections(_ markdown: String) -> [UpdateChangelogSection] {
        var sections: [UpdateChangelogSection] = []
        var currentVersion: String?
        var currentBuild: Int?
        var currentDate: String?
        var currentItems: [String] = []

        func flush() {
            if let version = currentVersion, let build = currentBuild, !currentItems.isEmpty {
                sections.append(UpdateChangelogSection(version: version, build: build, date: currentDate, items: currentItems))
            }
            currentVersion = nil
            currentBuild = nil
            currentDate = nil
            currentItems = []
        }

        for rawLine in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = headingRegex.firstMatch(in: line, range: range),
               let verRange = Range(match.range(at: 1), in: line),
               let buildRange = Range(match.range(at: 2), in: line),
               let build = Int(line[buildRange]), build > 0 {
                flush()
                currentVersion = String(line[verRange])
                currentBuild = build
                if let dateRange = Range(match.range(at: 3), in: line) {
                    let trimmedDate = line[dateRange].trimmingCharacters(in: .whitespaces)
                    currentDate = trimmedDate.isEmpty ? nil : trimmedDate
                }
            } else if currentBuild != nil,
                      let match = bulletRegex.firstMatch(in: line, range: range),
                      let itemRange = Range(match.range(at: 1), in: line) {
                let item = line[itemRange].trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { currentItems.append(item) }
            }
        }
        flush()
        return sections
    }

    static func slice(
        markdown: String?,
        installedBuild: Int,
        targetBuild: Int,
        installedVersion: String?,
        targetVersion: String
    ) -> UpdateChangelogDiff {
        guard let trimmed = markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return UpdateChangelogDiff(
                installedVersion: installedVersion,
                installedBuild: installedBuild,
                targetVersion: targetVersion,
                targetBuild: targetBuild,
                sections: [],
                fallbackMarkdown: nil,
                hasOlderUnshownChanges: false
            )
        }
        let parsed = parseSections(trimmed)
        if parsed.isEmpty {
            return UpdateChangelogDiff(
                installedVersion: installedVersion,
                installedBuild: installedBuild,
                targetVersion: targetVersion,
                targetBuild: targetBuild,
                sections: [],
                fallbackMarkdown: trimmed,
                hasOlderUnshownChanges: false
            )
        }
        var seenBuilds = Set<Int>()
        let deduplicated = parsed.filter { seenBuilds.insert($0.build).inserted }
        let minAvailable = deduplicated.map(\.build).min()
        let sliced = deduplicated
            .filter { $0.build > installedBuild && $0.build <= targetBuild }
            .sorted { $0.build > $1.build }
        let hasOlder = installedBuild > 0 && (minAvailable.map { installedBuild < $0 - 1 } ?? false)
        return UpdateChangelogDiff(
            installedVersion: installedVersion,
            installedBuild: installedBuild,
            targetVersion: targetVersion,
            targetBuild: targetBuild,
            sections: sliced,
            fallbackMarkdown: nil,
            hasOlderUnshownChanges: hasOlder
        )
    }
}

enum UpdateChangelogCache {
    static let storageKey = "native.updates.cachedChangelog"
    static let maxBytes = 65_536

    private struct Payload: Codable {
        let targetBuild: Int
        let targetVersion: String
        let markdown: String
    }

    static func save(markdown: String, targetBuild: Int, targetVersion: String, defaults: UserDefaults = .standard) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, targetBuild > 0 else { return }
        var candidate = trimmed
        while let data = try? JSONEncoder().encode(Payload(targetBuild: targetBuild, targetVersion: targetVersion, markdown: candidate)),
              data.count > maxBytes {
            guard let lastSection = candidate.range(of: "\n\n### ", options: .backwards) else {
                candidate = String(candidate.prefix(maxBytes / 2))
                break
            }
            candidate = String(candidate[..<lastSection.lowerBound])
        }
        if let data = try? JSONEncoder().encode(Payload(targetBuild: targetBuild, targetVersion: targetVersion, markdown: candidate)),
           data.count <= maxBytes {
            defaults.set(data, forKey: storageKey)
        }
    }

    static func load(targetBuild: Int, defaults: UserDefaults = .standard) -> (targetVersion: String, markdown: String)? {
        guard let data = defaults.data(forKey: storageKey),
              data.count <= maxBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.targetBuild == targetBuild else {
            return nil
        }
        return (payload.targetVersion, payload.markdown)
    }
}
#endif

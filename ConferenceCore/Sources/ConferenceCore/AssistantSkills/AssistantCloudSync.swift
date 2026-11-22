import CryptoKit
import Foundation

/// Portable Assistant settings that can sync safely through the private encrypted
/// CloudKit `MeetingLibrary` zone (`global:assistantPreferences`). API keys stay
/// strictly in Keychain on each device.
public struct LocalAssistantPortablePreferences: Codable, Equatable, Sendable {
    public var selectedSkillIDs: [String]
    public var autonomousMeetingVoiceEnabled: Bool
    public var realtimeProvider: String
    public var realtimeModel: String
    public var realtimeVoice: String
    public var realtimeEndpoint: String
    public var realtimeFolderID: String
    public var realtimeVoiceRole: String
    public var lastBoardURL: String

    public init(
        selectedSkillIDs: [String] = [],
        autonomousMeetingVoiceEnabled: Bool = false,
        realtimeProvider: String = RealtimeProviderKind.disabled.rawValue,
        realtimeModel: String = "",
        realtimeVoice: String = "",
        realtimeEndpoint: String = "",
        realtimeFolderID: String = "",
        realtimeVoiceRole: String = "",
        lastBoardURL: String = ""
    ) {
        self.selectedSkillIDs = selectedSkillIDs
        self.autonomousMeetingVoiceEnabled = autonomousMeetingVoiceEnabled
        self.realtimeProvider = realtimeProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        self.realtimeModel = realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.realtimeVoice = realtimeVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        self.realtimeEndpoint = realtimeEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.realtimeFolderID = realtimeFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.realtimeVoiceRole = realtimeVoiceRole.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastBoardURL = lastBoardURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SyncedAssistantPersonRecord: Codable, Equatable, Sendable {
    public var entry: SyncValue<AssistantPersonEntry>
    public var deleted: SyncValue<Bool>

    public init(entry: SyncValue<AssistantPersonEntry>, deleted: SyncValue<Bool>) {
        self.entry = entry
        self.deleted = deleted
    }

    public func merging(_ other: Self) -> Self {
        let mergedDeleted = deleted.merging(other.deleted)
        var winning = entry.merging(other.entry).value
        let losing = (entry.version < other.entry.version) ? entry.value : other.entry.value
        winning.aliases = AssistantPersonEntry.deduped(winning.aliases + losing.aliases)
        if winning.jiraUsername == nil { winning.jiraUsername = losing.jiraUsername }
        if winning.jiraAccountID == nil { winning.jiraAccountID = losing.jiraAccountID }
        if winning.email == nil { winning.email = losing.email }
        if winning.role == nil { winning.role = losing.role }
        if winning.notes == nil { winning.notes = losing.notes }
        winning.approvedVoiceCommander = entry.value.approvedVoiceCommander || other.entry.value.approvedVoiceCommander
            ? (entry.version >= other.entry.version ? entry.value.approvedVoiceCommander : other.entry.value.approvedVoiceCommander)
            : false
        let maxVersion = max(entry.version, other.entry.version)
        return Self(entry: SyncValue(winning, version: maxVersion), deleted: mergedDeleted)
    }
}

public struct SyncedAssistantPeoplePayload: Codable, Equatable, Sendable {
    public var entries: [String: SyncedAssistantPersonRecord] = [:]
    public var freeformNotes: SyncValue<String>?

    public init(
        entries: [String: SyncedAssistantPersonRecord] = [:],
        freeformNotes: SyncValue<String>? = nil
    ) {
        self.entries = entries
        self.freeformNotes = freeformNotes
    }

    public func merging(_ other: Self) -> Self {
        var merged = entries
        for (key, value) in other.entries {
            merged[key] = merged[key]?.merging(value) ?? value
        }
        let mergedNotes: SyncValue<String>? = switch (freeformNotes, other.freeformNotes) {
        case (.some(let a), .some(let b)): a.merging(b)
        case (.some(let a), .none): a
        case (.none, .some(let b)): b
        case (.none, .none): nil
        }
        return Self(entries: merged, freeformNotes: mergedNotes)
    }

    public func materializedDirectory(existingNotes: String = "") -> AssistantPeopleDirectory {
        let activeEntries = entries.values
            .filter { !$0.deleted.value }
            .map(\.entry.value)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let notes = freeformNotes?.value ?? existingNotes
        return AssistantPeopleDirectory(entries: activeEntries, freeformNotes: notes)
    }
}

public struct SyncedAssistantTeamContextPayload: Codable, Equatable, Sendable {
    public var defaultJiraBoardURL: SyncValue<String>?
    public var defaultJiraProjectKey: SyncValue<String>?
    public var defaultCalendarIdentifier: SyncValue<String>?
    public var notes: SyncValue<String>?

    public init(
        defaultJiraBoardURL: SyncValue<String>? = nil,
        defaultJiraProjectKey: SyncValue<String>? = nil,
        defaultCalendarIdentifier: SyncValue<String>? = nil,
        notes: SyncValue<String>? = nil
    ) {
        self.defaultJiraBoardURL = defaultJiraBoardURL
        self.defaultJiraProjectKey = defaultJiraProjectKey
        self.defaultCalendarIdentifier = defaultCalendarIdentifier
        self.notes = notes
    }

    public func merging(_ other: Self) -> Self {
        Self(
            defaultJiraBoardURL: mergeOptional(defaultJiraBoardURL, other.defaultJiraBoardURL),
            defaultJiraProjectKey: mergeOptional(defaultJiraProjectKey, other.defaultJiraProjectKey),
            defaultCalendarIdentifier: mergeOptional(defaultCalendarIdentifier, other.defaultCalendarIdentifier),
            notes: mergeOptional(notes, other.notes)
        )
    }

    public func materializedDocument(fallback: AssistantTeamContextDocument = .starter()) -> AssistantTeamContextDocument {
        AssistantTeamContextDocument(
            defaultJiraBoardURL: defaultJiraBoardURL?.value ?? fallback.defaultJiraBoardURL,
            defaultJiraProjectKey: defaultJiraProjectKey?.value ?? fallback.defaultJiraProjectKey,
            defaultCalendarIdentifier: defaultCalendarIdentifier?.value ?? fallback.defaultCalendarIdentifier,
            notes: notes?.value ?? fallback.notes
        )
    }

    private func mergeOptional(_ lhs: SyncValue<String>?, _ rhs: SyncValue<String>?) -> SyncValue<String>? {
        switch (lhs, rhs) {
        case (.some(let a), .some(let b)): return a.merging(b)
        case (.some(let a), .none): return a
        case (.none, .some(let b)): return b
        case (.none, .none): return nil
        }
    }
}

public struct SyncedAssistantSkillRecord: Codable, Equatable, Sendable {
    public var skill: SyncValue<AssistantSkill>
    public var deleted: SyncValue<Bool>

    public init(skill: SyncValue<AssistantSkill>, deleted: SyncValue<Bool>) {
        self.skill = skill
        self.deleted = deleted
    }

    public func merging(_ other: Self) -> Self {
        Self(skill: skill.merging(other.skill), deleted: deleted.merging(other.deleted))
    }
}

public struct SyncedAssistantSkillsPayload: Codable, Equatable, Sendable {
    public var skills: [String: SyncedAssistantSkillRecord] = [:]

    public init(skills: [String: SyncedAssistantSkillRecord] = [:]) {
        self.skills = skills
    }

    public func merging(_ other: Self) -> Self {
        var merged = skills
        for (id, record) in other.skills {
            merged[id] = merged[id]?.merging(record) ?? record
        }
        return Self(skills: merged)
    }
}

public struct SyncedAssistantPromptsPayload: Codable, Equatable, Sendable {
    public var prompts: [String: SyncValue<String?>] = [:]

    public init(prompts: [String: SyncValue<String?>] = [:]) {
        self.prompts = prompts
    }

    public func merging(_ other: Self) -> Self {
        var merged = prompts
        for (key, value) in other.prompts {
            merged[key] = merged[key]?.merging(value) ?? value
        }
        return Self(prompts: merged)
    }
}

public struct SyncedAssistantPreferencesPayload: Codable, Equatable, Sendable {
    public var selectedSkillIDs: SyncValue<[String]>?
    public var autonomousMeetingVoiceEnabled: SyncValue<Bool>?
    public var realtimeProvider: SyncValue<String>?
    public var realtimeModel: SyncValue<String>?
    public var realtimeVoice: SyncValue<String>?
    public var realtimeEndpoint: SyncValue<String>?
    public var realtimeFolderID: SyncValue<String>?
    public var realtimeVoiceRole: SyncValue<String>?
    public var lastBoardURL: SyncValue<String>?

    public init(
        selectedSkillIDs: SyncValue<[String]>? = nil,
        autonomousMeetingVoiceEnabled: SyncValue<Bool>? = nil,
        realtimeProvider: SyncValue<String>? = nil,
        realtimeModel: SyncValue<String>? = nil,
        realtimeVoice: SyncValue<String>? = nil,
        realtimeEndpoint: SyncValue<String>? = nil,
        realtimeFolderID: SyncValue<String>? = nil,
        realtimeVoiceRole: SyncValue<String>? = nil,
        lastBoardURL: SyncValue<String>? = nil
    ) {
        self.selectedSkillIDs = selectedSkillIDs
        self.autonomousMeetingVoiceEnabled = autonomousMeetingVoiceEnabled
        self.realtimeProvider = realtimeProvider
        self.realtimeModel = realtimeModel
        self.realtimeVoice = realtimeVoice
        self.realtimeEndpoint = realtimeEndpoint
        self.realtimeFolderID = realtimeFolderID
        self.realtimeVoiceRole = realtimeVoiceRole
        self.lastBoardURL = lastBoardURL
    }

    public func merging(_ other: Self) -> Self {
        Self(
            selectedSkillIDs: mergeOptional(selectedSkillIDs, other.selectedSkillIDs),
            autonomousMeetingVoiceEnabled: mergeOptional(autonomousMeetingVoiceEnabled, other.autonomousMeetingVoiceEnabled),
            realtimeProvider: mergeOptional(realtimeProvider, other.realtimeProvider),
            realtimeModel: mergeOptional(realtimeModel, other.realtimeModel),
            realtimeVoice: mergeOptional(realtimeVoice, other.realtimeVoice),
            realtimeEndpoint: mergeOptional(realtimeEndpoint, other.realtimeEndpoint),
            realtimeFolderID: mergeOptional(realtimeFolderID, other.realtimeFolderID),
            realtimeVoiceRole: mergeOptional(realtimeVoiceRole, other.realtimeVoiceRole),
            lastBoardURL: mergeOptional(lastBoardURL, other.lastBoardURL)
        )
    }

    public func materializedPreferences(onto current: LocalAssistantPortablePreferences) -> LocalAssistantPortablePreferences {
        var copy = current
        if let v = selectedSkillIDs?.value { copy.selectedSkillIDs = v }
        if let v = autonomousMeetingVoiceEnabled?.value { copy.autonomousMeetingVoiceEnabled = v }
        if let v = realtimeProvider?.value { copy.realtimeProvider = v }
        if let v = realtimeModel?.value { copy.realtimeModel = v }
        if let v = realtimeVoice?.value { copy.realtimeVoice = v }
        if let v = realtimeEndpoint?.value { copy.realtimeEndpoint = v }
        if let v = realtimeFolderID?.value { copy.realtimeFolderID = v }
        if let v = realtimeVoiceRole?.value { copy.realtimeVoiceRole = v }
        if let v = lastBoardURL?.value { copy.lastBoardURL = v }
        return copy
    }

    private func mergeOptional<T>(_ lhs: SyncValue<T>?, _ rhs: SyncValue<T>?) -> SyncValue<T>? {
        switch (lhs, rhs) {
        case (.some(let a), .some(let b)): return a.merging(b)
        case (.some(let a), .none): return a
        case (.none, .some(let b)): return b
        case (.none, .none): return nil
        }
    }
}

public struct AssistantLocalSyncBaseline: Codable, Equatable, Sendable {
    public var people: [String: AssistantPersonEntry] = [:]
    public var freeformNotes: String = ""
    public var teamContext: TeamContextBaseline?
    public var skillHashes: [String: String] = [:]
    public var promptHashes: [String: String] = [:]
    public var preferences: LocalAssistantPortablePreferences?

    public struct TeamContextBaseline: Codable, Equatable, Sendable {
        public var defaultJiraBoardURL: String
        public var defaultJiraProjectKey: String
        public var defaultCalendarIdentifier: String
        public var notes: String

        public init(doc: AssistantTeamContextDocument) {
            self.defaultJiraBoardURL = doc.defaultJiraBoardURL
            self.defaultJiraProjectKey = doc.defaultJiraProjectKey
            self.defaultCalendarIdentifier = doc.defaultCalendarIdentifier
            self.notes = doc.notes
        }
    }

    public init(
        people: [String: AssistantPersonEntry] = [:],
        freeformNotes: String = "",
        teamContext: TeamContextBaseline? = nil,
        skillHashes: [String: String] = [:],
        promptHashes: [String: String] = [:],
        preferences: LocalAssistantPortablePreferences? = nil
    ) {
        self.people = people
        self.freeformNotes = freeformNotes
        self.teamContext = teamContext
        self.skillHashes = skillHashes
        self.promptHashes = promptHashes
        self.preferences = preferences
    }
}

public enum AssistantCloudSync {
    public static let peopleScopeKey = "global:assistantPeople"
    public static let teamContextScopeKey = "global:assistantTeamContext"
    public static let skillsScopeKey = "global:assistantSkills"
    public static let promptsScopeKey = "global:assistantPrompts"
    public static let preferencesScopeKey = "global:assistantPreferences"

    public static let allScopeKeys: Set<String> = [
        peopleScopeKey,
        teamContextScopeKey,
        skillsScopeKey,
        promptsScopeKey,
        preferencesScopeKey,
    ]

    public static func isAssistantScopeKey(_ key: String) -> Bool {
        allScopeKeys.contains(key)
    }

    public static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeJSON<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = raw.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    public static func normalizedSkill(_ skill: AssistantSkill) -> AssistantSkill {
        var copy = skill
        copy.updatedAt = nil
        copy.sourceRelativePath = "Skills/\(copy.id).md"
        return copy
    }

    public static func skillDigest(_ skill: AssistantSkill) -> String {
        let text = encodeJSON(normalizedSkill(skill))
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func textDigest(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func mergeAboutValue(
        scopeKey: String,
        lhs: SyncValue<String>?,
        rhs: SyncValue<String>?
    ) -> SyncValue<String>? {
        switch (lhs, rhs) {
        case (.some(let a), .some(let b)):
            let maxVer = max(a.version, b.version)
            switch scopeKey {
            case peopleScopeKey:
                if let pA = decodeJSON(a.value, as: SyncedAssistantPeoplePayload.self),
                   let pB = decodeJSON(b.value, as: SyncedAssistantPeoplePayload.self) {
                    return SyncValue(encodeJSON(pA.merging(pB)), version: maxVer)
                }
            case teamContextScopeKey:
                if let tA = decodeJSON(a.value, as: SyncedAssistantTeamContextPayload.self),
                   let tB = decodeJSON(b.value, as: SyncedAssistantTeamContextPayload.self) {
                    return SyncValue(encodeJSON(tA.merging(tB)), version: maxVer)
                }
            case skillsScopeKey:
                if let sA = decodeJSON(a.value, as: SyncedAssistantSkillsPayload.self),
                   let sB = decodeJSON(b.value, as: SyncedAssistantSkillsPayload.self) {
                    return SyncValue(encodeJSON(sA.merging(sB)), version: maxVer)
                }
            case promptsScopeKey:
                if let rA = decodeJSON(a.value, as: SyncedAssistantPromptsPayload.self),
                   let rB = decodeJSON(b.value, as: SyncedAssistantPromptsPayload.self) {
                    return SyncValue(encodeJSON(rA.merging(rB)), version: maxVer)
                }
            case preferencesScopeKey:
                if let fA = decodeJSON(a.value, as: SyncedAssistantPreferencesPayload.self),
                   let fB = decodeJSON(b.value, as: SyncedAssistantPreferencesPayload.self) {
                    return SyncValue(encodeJSON(fA.merging(fB)), version: maxVer)
                }
            default:
                break
            }
            return a.merging(b)
        case (.some(let a), .none):
            return a
        case (.none, .some(let b)):
            return b
        case (.none, .none):
            return nil
        }
    }

    public struct LocalSnapshotInput: Sendable {
        public var people: AssistantPeopleDirectory
        public var teamContext: AssistantTeamContextDocument
        public var skills: [AssistantSkill]
        public var prompts: [AssistantPromptDocument]
        public var preferences: LocalAssistantPortablePreferences

        public init(
            people: AssistantPeopleDirectory,
            teamContext: AssistantTeamContextDocument,
            skills: [AssistantSkill],
            prompts: [AssistantPromptDocument],
            preferences: LocalAssistantPortablePreferences
        ) {
            self.people = people
            self.teamContext = teamContext
            self.skills = skills
            self.prompts = prompts
            self.preferences = preferences
        }
    }

    /// Exports local changes (relative to `baseline`) into `doc.contextSettings`
    /// without overwriting remote CloudKit values with fresh/unconfigured defaults.
    @discardableResult
    public static func exportLocalState(
        _ input: LocalSnapshotInput,
        into doc: inout MeetingWorkspaceSyncDocument,
        baseline: inout AssistantLocalSyncBaseline?
    ) -> Set<String> {
        let currentPeopleMap = Dictionary(
            input.people.entries.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentSkillMap = Dictionary(
            input.skills.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentSkillHashes: [String: String] = currentSkillMap.reduce(into: [:]) { acc, pair in
            if let def = DefaultAssistantSkills.skill(id: pair.key), skillDigest(def) == skillDigest(pair.value) {
                return
            }
            acc[pair.key] = skillDigest(pair.value)
        }
        let currentPromptHashes: [String: String] = input.prompts.reduce(into: [:]) { acc, docItem in
            let defText = DefaultAssistantPrompts.content(for: docItem.kind)
            if textDigest(docItem.content) == textDigest(defText) { return }
            acc[docItem.kind.rawValue] = textDigest(docItem.content)
        }

        let prevBaseline = baseline
        var changedScopeKeys: Set<String> = []

        // 1. People.md
        var peoplePayload = doc.contextSettings[peopleScopeKey]?.about.flatMap {
            decodeJSON($0.value, as: SyncedAssistantPeoplePayload.self)
        } ?? SyncedAssistantPeoplePayload()
        var peopleDirty = false

        for (id, entry) in currentPeopleMap {
            let prev = prevBaseline?.people[id]
            let shouldWrite = prev != entry
            if shouldWrite && peoplePayload.entries[id]?.entry.value != entry {
                let v = doc.nextVersion()
                peoplePayload.entries[id] = SyncedAssistantPersonRecord(
                    entry: SyncValue(entry, version: v),
                    deleted: SyncValue(false, version: v)
                )
                peopleDirty = true
            }
        }
        if let prevPeople = prevBaseline?.people {
            for id in prevPeople.keys where currentPeopleMap[id] == nil {
                if let existing = peoplePayload.entries[id], !existing.deleted.value {
                    let v = doc.nextVersion()
                    peoplePayload.entries[id] = SyncedAssistantPersonRecord(
                        entry: existing.entry,
                        deleted: SyncValue(true, version: v)
                    )
                    peopleDirty = true
                }
            }
        }
        let cleanNotes = input.people.freeformNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let prevNotes = prevBaseline?.freeformNotes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if (prevBaseline == nil && !cleanNotes.isEmpty) || (prevBaseline != nil && cleanNotes != prevNotes) {
            if peoplePayload.freeformNotes?.value != input.people.freeformNotes {
                peoplePayload.freeformNotes = SyncValue(input.people.freeformNotes, version: doc.nextVersion())
                peopleDirty = true
            }
        }
        if peopleDirty {
            upsertScope(peopleScopeKey, title: "Assistant People", json: encodeJSON(peoplePayload), into: &doc)
            changedScopeKeys.insert(peopleScopeKey)
        }

        // 2. TeamContext.md
        var teamPayload = doc.contextSettings[teamContextScopeKey]?.about.flatMap {
            decodeJSON($0.value, as: SyncedAssistantTeamContextPayload.self)
        } ?? SyncedAssistantTeamContextPayload()
        var teamDirty = false
        let starterTeam = AssistantTeamContextDocument.starter()
        let prevTeam = prevBaseline?.teamContext

        if (prevTeam == nil && !input.teamContext.defaultJiraBoardURL.isEmpty)
            || (prevTeam != nil && input.teamContext.defaultJiraBoardURL != prevTeam?.defaultJiraBoardURL) {
            if teamPayload.defaultJiraBoardURL?.value != input.teamContext.defaultJiraBoardURL {
                teamPayload.defaultJiraBoardURL = SyncValue(input.teamContext.defaultJiraBoardURL, version: doc.nextVersion())
                teamDirty = true
            }
        }
        if (prevTeam == nil && !input.teamContext.defaultJiraProjectKey.isEmpty)
            || (prevTeam != nil && input.teamContext.defaultJiraProjectKey != prevTeam?.defaultJiraProjectKey) {
            if teamPayload.defaultJiraProjectKey?.value != input.teamContext.defaultJiraProjectKey {
                teamPayload.defaultJiraProjectKey = SyncValue(input.teamContext.defaultJiraProjectKey, version: doc.nextVersion())
                teamDirty = true
            }
        }
        if (prevTeam == nil && !input.teamContext.defaultCalendarIdentifier.isEmpty)
            || (prevTeam != nil && input.teamContext.defaultCalendarIdentifier != prevTeam?.defaultCalendarIdentifier) {
            if teamPayload.defaultCalendarIdentifier?.value != input.teamContext.defaultCalendarIdentifier {
                teamPayload.defaultCalendarIdentifier = SyncValue(input.teamContext.defaultCalendarIdentifier, version: doc.nextVersion())
                teamDirty = true
            }
        }
        if (prevTeam == nil && textDigest(input.teamContext.notes) != textDigest(starterTeam.notes) && !input.teamContext.notes.isEmpty)
            || (prevTeam != nil && input.teamContext.notes != prevTeam?.notes) {
            if teamPayload.notes?.value != input.teamContext.notes {
                teamPayload.notes = SyncValue(input.teamContext.notes, version: doc.nextVersion())
                teamDirty = true
            }
        }
        if teamDirty {
            upsertScope(teamContextScopeKey, title: "Assistant Team Context", json: encodeJSON(teamPayload), into: &doc)
            changedScopeKeys.insert(teamContextScopeKey)
        }

        // 3. Skills (custom or customized built-ins)
        var skillsPayload = doc.contextSettings[skillsScopeKey]?.about.flatMap {
            decodeJSON($0.value, as: SyncedAssistantSkillsPayload.self)
        } ?? SyncedAssistantSkillsPayload()
        var skillsDirty = false
        for (id, hash) in currentSkillHashes {
            guard let rawSkill = currentSkillMap[id] else { continue }
            let skill = normalizedSkill(rawSkill)
            let existingDigest = skillsPayload.skills[id].map { skillDigest($0.skill.value) }
            let existingDeleted = skillsPayload.skills[id]?.deleted.value ?? false
            if prevBaseline?.skillHashes[id] != hash, (existingDigest != hash || existingDeleted) {
                let v = doc.nextVersion()
                skillsPayload.skills[id] = SyncedAssistantSkillRecord(
                    skill: SyncValue(skill, version: v),
                    deleted: SyncValue(false, version: v)
                )
                skillsDirty = true
            }
        }
        if let prevSkills = prevBaseline?.skillHashes {
            for id in prevSkills.keys where currentSkillHashes[id] == nil {
                if let existing = skillsPayload.skills[id], !existing.deleted.value {
                    let v = doc.nextVersion()
                    skillsPayload.skills[id] = SyncedAssistantSkillRecord(
                        skill: existing.skill,
                        deleted: SyncValue(true, version: v)
                    )
                    skillsDirty = true
                }
            }
        }
        if skillsDirty {
            upsertScope(skillsScopeKey, title: "Assistant Skills", json: encodeJSON(skillsPayload), into: &doc)
            changedScopeKeys.insert(skillsScopeKey)
        }

        // 4. Core Prompts (only customized non-default texts, or explicit reset after customization)
        var promptsPayload = doc.contextSettings[promptsScopeKey]?.about.flatMap {
            decodeJSON($0.value, as: SyncedAssistantPromptsPayload.self)
        } ?? SyncedAssistantPromptsPayload()
        var promptsDirty = false
        for (rawKind, hash) in currentPromptHashes {
            if prevBaseline?.promptHashes[rawKind] != hash,
               let content = input.prompts.first(where: { $0.kind.rawValue == rawKind })?.content,
               promptsPayload.prompts[rawKind]?.value != content {
                promptsPayload.prompts[rawKind] = SyncValue(content, version: doc.nextVersion())
                promptsDirty = true
            }
        }
        if let prevPrompts = prevBaseline?.promptHashes {
            for rawKind in prevPrompts.keys where currentPromptHashes[rawKind] == nil {
                if let existing = promptsPayload.prompts[rawKind], existing.value != nil {
                    promptsPayload.prompts[rawKind] = SyncValue(nil, version: doc.nextVersion())
                    promptsDirty = true
                }
            }
        }
        if promptsDirty {
            upsertScope(promptsScopeKey, title: "Assistant Prompts", json: encodeJSON(promptsPayload), into: &doc)
            changedScopeKeys.insert(promptsScopeKey)
        }

        // 5. Portable Preferences
        var prefsPayload = doc.contextSettings[preferencesScopeKey]?.about.flatMap {
            decodeJSON($0.value, as: SyncedAssistantPreferencesPayload.self)
        } ?? SyncedAssistantPreferencesPayload()
        var prefsDirty = false
        let prevPrefs = prevBaseline?.preferences
        let p = input.preferences

        func syncStringField(
            _ value: String,
            previous: String?,
            isDefault: Bool,
            slot: inout SyncValue<String>?
        ) {
            if (prevPrefs == nil && !isDefault) || (prevPrefs != nil && value != previous) {
                if slot?.value != value {
                    slot = SyncValue(value, version: doc.nextVersion())
                    prefsDirty = true
                }
            }
        }

        let isDefaultSkillSelection = p.selectedSkillIDs.isEmpty || p.selectedSkillIDs == ["scrum-master"]
        if (prevPrefs == nil && !isDefaultSkillSelection) || (prevPrefs != nil && p.selectedSkillIDs != prevPrefs?.selectedSkillIDs) {
            if prefsPayload.selectedSkillIDs?.value != p.selectedSkillIDs {
                prefsPayload.selectedSkillIDs = SyncValue(p.selectedSkillIDs, version: doc.nextVersion())
                prefsDirty = true
            }
        }
        if (prevPrefs == nil && p.autonomousMeetingVoiceEnabled)
            || (prevPrefs != nil && p.autonomousMeetingVoiceEnabled != prevPrefs?.autonomousMeetingVoiceEnabled) {
            if prefsPayload.autonomousMeetingVoiceEnabled?.value != p.autonomousMeetingVoiceEnabled {
                prefsPayload.autonomousMeetingVoiceEnabled = SyncValue(p.autonomousMeetingVoiceEnabled, version: doc.nextVersion())
                prefsDirty = true
            }
        }
        syncStringField(
            p.realtimeProvider,
            previous: prevPrefs?.realtimeProvider,
            isDefault: p.realtimeProvider.isEmpty || p.realtimeProvider == RealtimeProviderKind.disabled.rawValue,
            slot: &prefsPayload.realtimeProvider
        )
        syncStringField(p.realtimeModel, previous: prevPrefs?.realtimeModel, isDefault: p.realtimeModel.isEmpty, slot: &prefsPayload.realtimeModel)
        syncStringField(p.realtimeVoice, previous: prevPrefs?.realtimeVoice, isDefault: p.realtimeVoice.isEmpty, slot: &prefsPayload.realtimeVoice)
        syncStringField(p.realtimeEndpoint, previous: prevPrefs?.realtimeEndpoint, isDefault: p.realtimeEndpoint.isEmpty, slot: &prefsPayload.realtimeEndpoint)
        syncStringField(p.realtimeFolderID, previous: prevPrefs?.realtimeFolderID, isDefault: p.realtimeFolderID.isEmpty, slot: &prefsPayload.realtimeFolderID)
        syncStringField(p.realtimeVoiceRole, previous: prevPrefs?.realtimeVoiceRole, isDefault: p.realtimeVoiceRole.isEmpty, slot: &prefsPayload.realtimeVoiceRole)
        syncStringField(p.lastBoardURL, previous: prevPrefs?.lastBoardURL, isDefault: p.lastBoardURL.isEmpty, slot: &prefsPayload.lastBoardURL)

        if prefsDirty {
            upsertScope(preferencesScopeKey, title: "Assistant Preferences", json: encodeJSON(prefsPayload), into: &doc)
            changedScopeKeys.insert(preferencesScopeKey)
        }

        baseline = makeBaseline(from: input)

        return changedScopeKeys
    }

    public struct RemoteApplicationPlan: Sendable {
        public var updatedPeople: AssistantPeopleDirectory?
        public var updatedTeamContext: AssistantTeamContextDocument?
        public var skillsToSave: [AssistantSkill] = []
        public var skillIDsToRestoreDefault: [String] = []
        public var skillIDsToDelete: [String] = []
        public var promptsToSave: [(kind: AssistantPromptKind, content: String)] = []
        public var promptKindsToRestoreDefault: [AssistantPromptKind] = []
        public var updatedPreferences: LocalAssistantPortablePreferences?
        public var updatedBaseline: AssistantLocalSyncBaseline

        public var hasAnyChange: Bool {
            updatedPeople != nil
                || updatedTeamContext != nil
                || !skillsToSave.isEmpty
                || !skillIDsToRestoreDefault.isEmpty
                || !skillIDsToDelete.isEmpty
                || !promptsToSave.isEmpty
                || !promptKindsToRestoreDefault.isEmpty
                || updatedPreferences != nil
        }
    }

    public static func planRemoteApplication(
        from contextSettings: [String: SyncedMeetingContextSettings],
        currentInput: LocalSnapshotInput,
        previousBaseline: AssistantLocalSyncBaseline?
    ) -> RemoteApplicationPlan? {
        guard allScopeKeys.contains(where: { contextSettings[$0]?.about != nil }) else {
            return nil
        }

        var resultingPeople = currentInput.people
        var updatedPeople: AssistantPeopleDirectory?
        if let raw = contextSettings[peopleScopeKey]?.about?.value,
           let payload = decodeJSON(raw, as: SyncedAssistantPeoplePayload.self) {
            let localMap = Dictionary(
                currentInput.people.entries.map { ($0.id.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var mergedMap = localMap
            for (id, record) in payload.entries {
                if record.deleted.value {
                    mergedMap.removeValue(forKey: id)
                } else {
                    mergedMap[id] = record.entry.value
                }
            }
            let targetNotes = payload.freeformNotes?.value ?? currentInput.people.freeformNotes
            let sortedEntries = mergedMap.values.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            if mergedMap != localMap || targetNotes != currentInput.people.freeformNotes {
                let candidate = AssistantPeopleDirectory(entries: sortedEntries, freeformNotes: targetNotes)
                updatedPeople = candidate
                resultingPeople = candidate
            }
        }

        var resultingTeamContext = currentInput.teamContext
        var updatedTeamContext: AssistantTeamContextDocument?
        if let raw = contextSettings[teamContextScopeKey]?.about?.value,
           let payload = decodeJSON(raw, as: SyncedAssistantTeamContextPayload.self) {
            let starter = AssistantTeamContextDocument.starter()
            var candidate = currentInput.teamContext
            let hadTeamBaseline = previousBaseline?.teamContext != nil
            if let v = payload.defaultJiraBoardURL?.value, !v.isEmpty || hadTeamBaseline {
                candidate.defaultJiraBoardURL = v
            }
            if let v = payload.defaultJiraProjectKey?.value, !v.isEmpty || hadTeamBaseline {
                candidate.defaultJiraProjectKey = v
            }
            if let v = payload.defaultCalendarIdentifier?.value, !v.isEmpty || hadTeamBaseline {
                candidate.defaultCalendarIdentifier = v
            }
            if let v = payload.notes?.value,
               textDigest(v) != textDigest(starter.notes) || hadTeamBaseline {
                candidate.notes = v
            }
            if candidate != currentInput.teamContext {
                updatedTeamContext = candidate
                resultingTeamContext = candidate
            }
        }

        var resultingSkills = Dictionary(
            currentInput.skills.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var skillsToSave: [AssistantSkill] = []
        var skillIDsToRestoreDefault: [String] = []
        var skillIDsToDelete: [String] = []
        if let raw = contextSettings[skillsScopeKey]?.about?.value,
           let payload = decodeJSON(raw, as: SyncedAssistantSkillsPayload.self) {
            for (id, record) in payload.skills.sorted(by: { $0.key < $1.key }) {
                if record.deleted.value {
                    if let def = DefaultAssistantSkills.skill(id: id) {
                        if let local = resultingSkills[id], skillDigest(local) != skillDigest(def) {
                            skillIDsToRestoreDefault.append(id)
                            resultingSkills[id] = def
                        }
                    } else if resultingSkills[id] != nil {
                        skillIDsToDelete.append(id)
                        resultingSkills.removeValue(forKey: id)
                    }
                } else {
                    let remoteSkill = normalizedSkill(record.skill.value)
                    let remoteHash = skillDigest(remoteSkill)
                    let localHash = resultingSkills[id].map(skillDigest)
                    if localHash != remoteHash {
                        skillsToSave.append(remoteSkill)
                        resultingSkills[id] = remoteSkill
                    }
                }
            }
        }

        var resultingPrompts = Dictionary(
            currentInput.prompts.map { ($0.kind, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var promptsToSave: [(kind: AssistantPromptKind, content: String)] = []
        var promptKindsToRestoreDefault: [AssistantPromptKind] = []
        if let raw = contextSettings[promptsScopeKey]?.about?.value,
           let payload = decodeJSON(raw, as: SyncedAssistantPromptsPayload.self) {
            for kind in AssistantPromptKind.allCases {
                guard let syncVal = payload.prompts[kind.rawValue] else { continue }
                let localContent = resultingPrompts[kind]?.content ?? DefaultAssistantPrompts.content(for: kind)
                if let remoteContent = syncVal.value {
                    if textDigest(remoteContent) != textDigest(localContent) {
                        promptsToSave.append((kind: kind, content: remoteContent))
                        resultingPrompts[kind] = AssistantPromptDocument(kind: kind, content: remoteContent)
                    }
                } else {
                    let defaultText = DefaultAssistantPrompts.content(for: kind)
                    if textDigest(localContent) != textDigest(defaultText) {
                        promptKindsToRestoreDefault.append(kind)
                        resultingPrompts[kind] = AssistantPromptDocument(kind: kind, content: defaultText)
                    }
                }
            }
        }

        var resultingPreferences = currentInput.preferences
        var updatedPreferences: LocalAssistantPortablePreferences?
        if let raw = contextSettings[preferencesScopeKey]?.about?.value,
           let payload = decodeJSON(raw, as: SyncedAssistantPreferencesPayload.self) {
            let mergedPrefs = payload.materializedPreferences(onto: currentInput.preferences)
            if mergedPrefs != currentInput.preferences {
                updatedPreferences = mergedPrefs
                resultingPreferences = mergedPrefs
            }
        }

        let finalInput = LocalSnapshotInput(
            people: resultingPeople,
            teamContext: resultingTeamContext,
            skills: Array(resultingSkills.values),
            prompts: Array(resultingPrompts.values),
            preferences: resultingPreferences
        )

        return RemoteApplicationPlan(
            updatedPeople: updatedPeople,
            updatedTeamContext: updatedTeamContext,
            skillsToSave: skillsToSave,
            skillIDsToRestoreDefault: skillIDsToRestoreDefault,
            skillIDsToDelete: skillIDsToDelete,
            promptsToSave: promptsToSave,
            promptKindsToRestoreDefault: promptKindsToRestoreDefault,
            updatedPreferences: updatedPreferences,
            updatedBaseline: makeBaseline(from: finalInput)
        )
    }

    public static func applyRepositoryChanges(
        from plan: RemoteApplicationPlan,
        to repository: AssistantSkillRepository
    ) throws {
        if let updatedPeople = plan.updatedPeople {
            try repository.savePeople(updatedPeople)
        }
        if let updatedTeamContext = plan.updatedTeamContext {
            try repository.saveTeamContext(updatedTeamContext)
        }
        for skill in plan.skillsToSave {
            _ = try repository.saveSkill(skill)
        }
        for skillID in plan.skillIDsToRestoreDefault {
            _ = try repository.restoreDefaultSkill(id: skillID)
        }
        for skillID in plan.skillIDsToDelete {
            try repository.deleteSkill(id: skillID)
        }
        for (kind, content) in plan.promptsToSave {
            _ = try repository.savePrompt(kind, content: content)
        }
        for kind in plan.promptKindsToRestoreDefault {
            _ = try repository.restoreDefaultPrompt(kind)
        }
    }

    public static func makeBaseline(from input: LocalSnapshotInput) -> AssistantLocalSyncBaseline {
        let peopleMap = Dictionary(
            input.people.entries.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let skillHashes: [String: String] = input.skills.reduce(into: [:]) { acc, skill in
            let hash = skillDigest(skill)
            if let def = DefaultAssistantSkills.skill(id: skill.id), skillDigest(def) == hash {
                return
            }
            acc[skill.id] = hash
        }
        let promptHashes: [String: String] = input.prompts.reduce(into: [:]) { acc, docItem in
            let defText = DefaultAssistantPrompts.content(for: docItem.kind)
            let hash = textDigest(docItem.content)
            if hash == textDigest(defText) { return }
            acc[docItem.kind.rawValue] = hash
        }
        return AssistantLocalSyncBaseline(
            people: peopleMap,
            freeformNotes: input.people.freeformNotes,
            teamContext: AssistantLocalSyncBaseline.TeamContextBaseline(doc: input.teamContext),
            skillHashes: skillHashes,
            promptHashes: promptHashes,
            preferences: input.preferences
        )
    }

    private static func upsertScope(
        _ scopeKey: String,
        title: String,
        json: String,
        into doc: inout MeetingWorkspaceSyncDocument
    ) {
        let existing = doc.contextSettings[scopeKey]
        let v = doc.nextVersion()
        var entry = existing ?? SyncedMeetingContextSettings(
            scopeKey: scopeKey,
            scopeKind: .allMeetings,
            title: SyncValue(title, version: v)
        )
        entry.about = SyncValue(json, version: doc.nextVersion())
        doc.upsertContextSettings(entry)
    }
}

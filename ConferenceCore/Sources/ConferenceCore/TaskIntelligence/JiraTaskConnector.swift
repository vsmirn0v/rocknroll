import Foundation

public struct JiraProjectMetadata: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var issueTypes: [String]
}

public struct JiraRemoteIssue: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var key: String
    public var summary: String
    public var description: String
    public var statusName: String
    public var workflowStatus: TaskWorkflowStatus
    public var issueTypeName: String
    public var issueKind: TaskIssueKind
    public var parentEpicKey: String?
    public var priority: TaskPriorityLevel?
    public var dueDay: String?
    public var assigneeName: String?
    public var assigneeIdentifier: String?
    public var updatedAt: Date?
    public var browseURL: String?
    public var assigneeContact: JiraUserContact?
    public var reporterContact: JiraUserContact?

    public init(
        id: String,
        key: String,
        summary: String,
        description: String,
        statusName: String,
        workflowStatus: TaskWorkflowStatus,
        issueTypeName: String = "Task",
        issueKind: TaskIssueKind = .task,
        parentEpicKey: String? = nil,
        priority: TaskPriorityLevel? = nil,
        dueDay: String? = nil,
        assigneeName: String? = nil,
        assigneeIdentifier: String? = nil,
        updatedAt: Date? = nil,
        browseURL: String? = nil,
        assigneeContact: JiraUserContact? = nil,
        reporterContact: JiraUserContact? = nil
    ) {
        self.id = id
        self.key = key
        self.summary = summary
        self.description = description
        self.statusName = statusName
        self.workflowStatus = workflowStatus
        self.issueTypeName = issueTypeName
        self.issueKind = issueKind
        self.parentEpicKey = parentEpicKey
        self.priority = priority
        self.dueDay = dueDay
        self.assigneeName = assigneeName
        self.assigneeIdentifier = assigneeIdentifier
        self.updatedAt = updatedAt
        self.browseURL = browseURL
        self.assigneeContact = assigneeContact
        self.reporterContact = reporterContact
    }
}

public struct JiraIssueWritePayload: Sendable {
    public var projectKey: String
    public var issueType: String
    public var issueKind: TaskIssueKind
    public var parentEpicKey: String?
    public var summary: String
    public var description: String
    public var dueDay: String?
    public var priority: TaskPriorityLevel?
    public var assignee: JiraUserContact?

    public init(
        projectKey: String,
        issueType: String,
        issueKind: TaskIssueKind = .task,
        parentEpicKey: String? = nil,
        summary: String,
        description: String,
        dueDay: String? = nil,
        priority: TaskPriorityLevel? = nil,
        assignee: JiraUserContact? = nil
    ) {
        self.projectKey = projectKey
        self.issueType = issueType
        self.issueKind = issueKind
        self.parentEpicKey = parentEpicKey
        self.summary = summary
        self.description = description
        self.dueDay = dueDay
        self.priority = priority
        self.assignee = assignee
    }
}

public enum JiraConnectorError: LocalizedError, Equatable {
    case invalidBaseURL
    case missingCredentials
    case unauthorized
    case forbidden(String?)
    case notFound(String?)
    case badRequest(String)
    case invalidResponse
    case serverError(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return L("Enter a valid Jira server URL (for example https://jira.example.com).")
        case .missingCredentials:
            return L("Sign in to Jira or add a Personal Access Token in Task Sync settings.")
        case .unauthorized:
            return L("Jira rejected your credentials or session. Sign in again or update your Personal Access Token.")
        case .forbidden(let detail):
            return detail ?? L("Your Jira account does not have permission for this action.")
        case .notFound(let detail):
            return detail ?? L("The requested Jira project or issue was not found.")
        case .badRequest(let detail):
            return L("Jira rejected the request: %@", detail)
        case .invalidResponse:
            return L("Jira returned an unexpected response.")
        case .serverError(let code, let detail):
            if let detail, !detail.isEmpty {
                return L("Jira error %ld: %@", code, detail)
            }
            return L("Jira returned HTTP %ld.", code)
        }
    }
}

public protocol JiraTaskConnecting: Sendable {
    func verifyMyself() async throws -> JiraUserContact
    func fetchProjectMetadata(projectKey: String) async throws -> JiraProjectMetadata
    func fetchAssignableUsers(projectKey: String, query: String) async throws -> [JiraUserContact]
    func searchUsers(query: String, projectKey: String?, maxResults: Int) async throws -> [JiraUserContact]
    func searchIssues(jql: String, maxResults: Int) async throws -> [JiraRemoteIssue]
    func createIssue(_ payload: JiraIssueWritePayload) async throws -> JiraRemoteIssue
    func updateIssue(
        key: String,
        payload: JiraIssueWritePayload,
        targetStatus: TaskWorkflowStatus?,
        comment: String?
    ) async throws -> JiraRemoteIssue
    func addIssueComment(key: String, comment: String) async throws
    func transitionIssue(key: String, targetStatusText: String, comment: String?) async throws -> JiraRemoteIssue
    func assignIssue(key: String, assignee: JiraUserContact?) async throws -> JiraRemoteIssue
    func fetchIssueDetails(key: String) async throws -> JiraRemoteIssue
}

public extension JiraTaskConnecting {
    func addIssueComment(key: String, comment: String) async throws {}
    func searchUsers(query: String, projectKey: String?, maxResults: Int) async throws -> [JiraUserContact] { [] }
    func transitionIssue(key: String, targetStatusText: String, comment: String?) async throws -> JiraRemoteIssue {
        throw JiraConnectorError.badRequest(L("Jira transitions are not supported by this connector."))
    }
    func assignIssue(key: String, assignee: JiraUserContact?) async throws -> JiraRemoteIssue {
        throw JiraConnectorError.badRequest(L("Jira assignment is not supported by this connector."))
    }
    func fetchIssueDetails(key: String) async throws -> JiraRemoteIssue {
        let issues = try await searchIssues(jql: "key = \"\(key)\"", maxResults: 1)
        guard let issue = issues.first else {
            throw JiraConnectorError.notFound(nil)
        }
        return issue
    }
}

public final class JiraTaskConnector: JiraTaskConnecting, @unchecked Sendable {
    private let settings: JiraConnectionSettings
    private let secretProvider: @Sendable (String, TaskIntegrationSecretKind) -> String?
    private let session: URLSession

    public init(
        settings: JiraConnectionSettings,
        keychain: TaskIntegrationKeychain = .init(),
        session: URLSession? = nil
    ) {
        self.settings = settings
        self.secretProvider = { host, kind in keychain.read(hostKey: host, kind: kind) }
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieAcceptPolicy = .never
            config.httpShouldSetCookies = false
            config.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: config)
        }
    }

    public init(
        settings: JiraConnectionSettings,
        secretProvider: @escaping @Sendable (String, TaskIntegrationSecretKind) -> String?,
        session: URLSession
    ) {
        self.settings = settings
        self.secretProvider = secretProvider
        self.session = session
    }

    public func verifyMyself() async throws -> JiraUserContact {
        let data = try await send(path: "/rest/api/2/myself", method: "GET")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = Self.parseUserObject(object, isServerOrDC: !settings.isCloudHost) else {
            throw JiraConnectorError.invalidResponse
        }
        return user
    }

    public static func validatedJiraKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: #"^[A-Za-z][A-Za-z0-9_]+(?:-[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw JiraConnectorError.badRequest(L("Invalid Jira key."))
        }
        return key
    }

    public func fetchProjectMetadata(projectKey: String) async throws -> JiraProjectMetadata {
        let cleanKey = try Self.validatedJiraKey(projectKey).uppercased()
        let data = try await send(path: "/rest/api/2/project/\(cleanKey)", method: "GET")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraConnectorError.invalidResponse
        }
        let issueTypes = (object["issueTypes"] as? [[String: Any]] ?? [])
            .filter { ($0["subtask"] as? Bool) != true }
            .compactMap { $0["name"] as? String }
        return JiraProjectMetadata(
            key: object["key"] as? String ?? cleanKey,
            name: object["name"] as? String ?? cleanKey,
            issueTypes: issueTypes
        )
    }

    public func fetchAssignableUsers(projectKey: String, query: String = "") async throws -> [JiraUserContact] {
        let cleanKey = projectKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let paramName = settings.isCloudHost ? "query" : "username"
        do {
            return try await queryAssignable(projectKey: cleanKey, paramName: paramName, query: query)
        } catch JiraConnectorError.badRequest where paramName == "username" && query.isEmpty {
            // Some Jira DC versions require a non-empty username/query filter.
            if let fallback = try? await queryAssignable(projectKey: cleanKey, paramName: "query", query: "") {
                return fallback
            }
            return try await queryAssignable(projectKey: cleanKey, paramName: "username", query: ".")
        }
    }

    private func queryAssignable(projectKey: String, paramName: String, query: String) async throws -> [JiraUserContact] {
        var items = [
            URLQueryItem(name: "project", value: projectKey),
            URLQueryItem(name: "maxResults", value: "200")
        ]
        if !query.isEmpty || !settings.isCloudHost {
            items.append(URLQueryItem(name: paramName, value: query))
        }
        let data = try await send(path: "/rest/api/2/user/assignable/search", method: "GET", queryItems: items)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw JiraConnectorError.invalidResponse
        }
        return array.compactMap { Self.parseUserObject($0, isServerOrDC: !settings.isCloudHost) }
    }

    public func searchUsers(query: String, projectKey: String? = nil, maxResults: Int = 15) async throws -> [JiraUserContact] {
        let cap = max(1, min(maxResults, 50))
        let stripped = AssistantPeopleDirectory.strippedMeetingDisplayName(query)
        var rawQuery = (stripped.isEmpty ? query : stripped).trimmingCharacters(in: .whitespacesAndNewlines)
        if rawQuery.hasPrefix("@") {
            rawQuery.removeFirst()
            rawQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let terms = JiraContactMatcher.searchTerms(for: rawQuery)
        let cleanProject = (projectKey ?? settings.cleanProjectKey).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let isServerOrDC = !settings.isCloudHost
        let path = settings.isCloudHost ? "/rest/api/3/user/search" : "/rest/api/2/user/search"
        let pickerPath = settings.isCloudHost ? "/rest/api/3/user/picker" : "/rest/api/2/user/picker"
        let paramName = settings.isCloudHost ? "query" : "username"

        func runSearch(term: String) async throws -> [JiraUserContact] {
            var hits: [JiraUserContact] = []
            var searchItems = [
                URLQueryItem(name: paramName, value: term),
                URLQueryItem(name: "maxResults", value: String(cap)),
            ]
            do {
                let data = try await send(path: path, method: "GET", queryItems: searchItems)
                if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    hits.append(contentsOf: array.compactMap { Self.parseUserObject($0, isServerOrDC: isServerOrDC) })
                }
            } catch JiraConnectorError.badRequest(let detail) where isServerOrDC && term.isEmpty {
                searchItems[0] = URLQueryItem(name: "username", value: ".")
                if let data = try? await send(path: path, method: "GET", queryItems: searchItems),
                   let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    hits.append(contentsOf: array.compactMap { Self.parseUserObject($0, isServerOrDC: isServerOrDC) })
                } else if !cleanProject.isEmpty,
                          let assignable = try? await fetchAssignableUsers(projectKey: cleanProject, query: term) {
                    hits.append(contentsOf: assignable)
                } else {
                    throw JiraConnectorError.badRequest(detail)
                }
            } catch let error as JiraConnectorError where !cleanProject.isEmpty {
                switch error {
                case .badRequest, .forbidden, .notFound:
                    if let assignable = try? await fetchAssignableUsers(projectKey: cleanProject, query: term) {
                        hits.append(contentsOf: assignable)
                    }
                default:
                    throw error
                }
            }

            if !term.isEmpty && hits.count < cap {
                let pickerItems = [
                    URLQueryItem(name: "query", value: term),
                    URLQueryItem(name: "maxResults", value: String(cap)),
                ]
                if let pickerData = try? await send(path: pickerPath, method: "GET", queryItems: pickerItems),
                   let root = try? JSONSerialization.jsonObject(with: pickerData) as? [String: Any],
                   let users = root["users"] as? [[String: Any]] {
                    hits.append(contentsOf: users.compactMap { Self.parseUserObject($0, isServerOrDC: isServerOrDC) })
                }
            }

            if !cleanProject.isEmpty && hits.isEmpty {
                if let assignable = try? await fetchAssignableUsers(projectKey: cleanProject, query: term) {
                    hits.append(contentsOf: assignable)
                }
            }
            return hits
        }

        var collectedByID: [String: JiraUserContact] = [:]
        var orderedKeys: [String] = []
        var succeededAtLeastOnce = false
        var firstError: Error?

        for term in terms.prefix(6) {
            do {
                let hits = try await runSearch(term: term)
                succeededAtLeastOnce = true
                for user in hits {
                    let key = user.identifier.lowercased()
                    if collectedByID[key] == nil {
                        orderedKeys.append(key)
                    }
                    collectedByID[key] = user
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let me = try? await verifyMyself() {
            succeededAtLeastOnce = true
            let includeMe = rawQuery.isEmpty || JiraContactMatcher.matchScore(
                name: rawQuery,
                candidateNames: [me.displayName, me.username ?? "", me.identifier],
                candidateEmail: me.emailAddress,
                candidateUsername: me.username
            ) >= 0.55
            if includeMe {
                let key = me.identifier.lowercased()
                if collectedByID[key] == nil {
                    orderedKeys.append(key)
                    collectedByID[key] = me
                }
            }
        }

        if !succeededAtLeastOnce, let firstError {
            throw firstError
        }

        let unique = orderedKeys.compactMap { collectedByID[$0] }
        guard !rawQuery.isEmpty else {
            return Array(unique.prefix(cap))
        }
        let ranked = unique.enumerated().sorted { lhs, rhs in
            let lScore = JiraContactMatcher.matchScore(
                name: rawQuery,
                candidateNames: [lhs.element.displayName, lhs.element.username ?? "", lhs.element.identifier],
                candidateEmail: lhs.element.emailAddress,
                candidateUsername: lhs.element.username
            )
            let rScore = JiraContactMatcher.matchScore(
                name: rawQuery,
                candidateNames: [rhs.element.displayName, rhs.element.username ?? "", rhs.element.identifier],
                candidateEmail: rhs.element.emailAddress,
                candidateUsername: rhs.element.username
            )
            if abs(lScore - rScore) > 0.001 {
                return lScore > rScore
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return Array(ranked.prefix(cap))
    }

    public func searchIssues(jql: String, maxResults: Int = 100) async throws -> [JiraRemoteIssue] {
        let body: [String: Any] = [
            "jql": jql,
            "startAt": 0,
            "maxResults": max(1, min(maxResults, 200)),
            "fields": [
                "summary", "description", "status", "priority", "duedate",
                "assignee", "reporter", "updated", "created", "resolutiondate", "issuetype", "project",
                "parent", "customfield_10014", "customfield_10008", "customfield_10100"
            ]
        ]
        let data = try await send(path: "/rest/api/2/search", method: "POST", jsonBody: body)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issues = root["issues"] as? [[String: Any]] else {
            throw JiraConnectorError.invalidResponse
        }
        return issues.compactMap {
            Self.parseIssueObject($0, baseURL: settings.normalizedBaseURL, isServerOrDC: !settings.isCloudHost)
        }
    }

    public func createIssue(_ payload: JiraIssueWritePayload) async throws -> JiraRemoteIssue {
        let resolvedIssueType = payload.issueKind == .epic ? "Epic" : payload.issueType
        var fields: [String: Any] = [
            "project": ["key": payload.projectKey],
            "summary": String(payload.summary.prefix(255)),
            "issuetype": ["name": resolvedIssueType]
        ]
        let desc = payload.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { fields["description"] = desc }
        if let dueDay = payload.dueDay, !dueDay.isEmpty { fields["duedate"] = dueDay }
        if let assignee = payload.assignee { fields["assignee"] = assignee.assigneePayload() }
        if let priority = payload.priority { fields["priority"] = ["name": Self.jiraPriorityName(priority)] }
        if payload.issueKind == .epic {
            fields["customfield_10011"] = String(payload.summary.prefix(120))
        } else if let epicKey = payload.parentEpicKey?.trimmingCharacters(in: .whitespacesAndNewlines), !epicKey.isEmpty {
            if settings.isCloudHost {
                fields["parent"] = ["key": epicKey]
            } else {
                fields["customfield_10014"] = epicKey
            }
        }

        let data: Data
        do {
            data = try await send(path: "/rest/api/2/issue", method: "POST", jsonBody: ["fields": fields])
        } catch JiraConnectorError.badRequest(let detail) {
            var trimmedFields = fields
            var retried = false
            for optionalKey in ["customfield_10011", "customfield_10014", "parent", "priority", "assignee", "duedate"] {
                if trimmedFields[optionalKey] != nil && detail.localizedCaseInsensitiveContains(optionalKey) {
                    trimmedFields.removeValue(forKey: optionalKey)
                    retried = true
                }
            }
            if !retried {
                for optionalKey in ["customfield_10011", "customfield_10014", "parent", "priority"] where trimmedFields[optionalKey] != nil {
                    trimmedFields.removeValue(forKey: optionalKey)
                    retried = true
                }
            }
            guard retried else { throw JiraConnectorError.badRequest(detail) }
            do {
                data = try await send(path: "/rest/api/2/issue", method: "POST", jsonBody: ["fields": trimmedFields])
            } catch JiraConnectorError.badRequest(let retryDetail) {
                for optionalKey in ["priority", "assignee", "duedate"] {
                    trimmedFields.removeValue(forKey: optionalKey)
                }
                guard trimmedFields.count >= 3 else { throw JiraConnectorError.badRequest(retryDetail) }
                data = try await send(path: "/rest/api/2/issue", method: "POST", jsonBody: ["fields": trimmedFields])
            }
        }

        guard let created = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = created["key"] as? String else {
            throw JiraConnectorError.invalidResponse
        }
        return try await fetchIssue(key: key)
    }

    public func updateIssue(
        key: String,
        payload: JiraIssueWritePayload,
        targetStatus: TaskWorkflowStatus?,
        comment: String?
    ) async throws -> JiraRemoteIssue {
        let encodedKey = try Self.validatedJiraKey(key)
        var fields: [String: Any] = [
            "summary": String(payload.summary.prefix(255))
        ]
        let desc = payload.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { fields["description"] = desc }
        if let dueDay = payload.dueDay, !dueDay.isEmpty { fields["duedate"] = dueDay }
        if let assignee = payload.assignee { fields["assignee"] = assignee.assigneePayload() }
        if payload.issueKind != .epic,
           let epicKey = payload.parentEpicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !epicKey.isEmpty {
            if settings.isCloudHost {
                fields["parent"] = ["key": epicKey]
            } else {
                fields["customfield_10014"] = epicKey
            }
        }

        do {
            _ = try await send(path: "/rest/api/2/issue/\(encodedKey)", method: "PUT", jsonBody: ["fields": fields])
        } catch JiraConnectorError.badRequest(let detail) {
            var trimmed = fields
            var changed = false
            for optionalKey in ["customfield_10014", "parent", "assignee", "duedate", "description"] where trimmed[optionalKey] != nil {
                if detail.localizedCaseInsensitiveContains(optionalKey) || optionalKey == "customfield_10014" || optionalKey == "parent" {
                    trimmed.removeValue(forKey: optionalKey)
                    changed = true
                }
            }
            guard changed, !trimmed.isEmpty else {
                throw JiraConnectorError.badRequest(detail)
            }
            _ = try await send(path: "/rest/api/2/issue/\(encodedKey)", method: "PUT", jsonBody: ["fields": trimmed])
        }

        if let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            _ = try await send(
                path: "/rest/api/2/issue/\(encodedKey)/comment",
                method: "POST",
                jsonBody: ["body": String(comment.prefix(8_000))]
            )
        }

        if let targetStatus {
            try await transitionIssueIfNeeded(encodedKey: encodedKey, targetStatus: targetStatus)
        }

        return try await fetchIssue(key: encodedKey)
    }

    public func addIssueComment(key: String, comment: String) async throws {
        let encodedKey = try Self.validatedJiraKey(key)
        let clean = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw JiraConnectorError.badRequest(L("Comment text cannot be empty."))
        }
        _ = try await send(
            path: "/rest/api/2/issue/\(encodedKey)/comment",
            method: "POST",
            jsonBody: ["body": String(clean.prefix(8_000))]
        )
    }

    public func fetchIssue(key: String) async throws -> JiraRemoteIssue {
        let encodedKey = try Self.validatedJiraKey(key)
        let data = try await send(path: "/rest/api/2/issue/\(encodedKey)", method: "GET")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issue = Self.parseIssueObject(object, baseURL: settings.normalizedBaseURL, isServerOrDC: !settings.isCloudHost) else {
            throw JiraConnectorError.invalidResponse
        }
        return issue
    }

    public func fetchIssueDetails(key: String) async throws -> JiraRemoteIssue {
        try await fetchIssue(key: key)
    }

    public func transitionIssue(key: String, targetStatusText: String, comment: String? = nil) async throws -> JiraRemoteIssue {
        let encodedKey = try Self.validatedJiraKey(key)
        let cleanTarget = targetStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTarget.isEmpty else {
            throw JiraConnectorError.badRequest(L("Target status is required."))
        }
        let data = try await send(path: "/rest/api/2/issue/\(encodedKey)/transitions", method: "GET")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transitions = root["transitions"] as? [[String: Any]] else {
            throw JiraConnectorError.invalidResponse
        }
        guard let match = Self.selectTransition(from: transitions, matchingText: cleanTarget),
              let transitionID = match["id"] as? String else {
            let available = transitions.compactMap {
                ($0["to"] as? [String: Any])?["name"] as? String ?? ($0["name"] as? String)
            }.joined(separator: ", ")
            throw JiraConnectorError.badRequest(
                available.isEmpty
                    ? L("No matching Jira status transition found for %@.", cleanTarget)
                    : L("No Jira transition matches %@. Available: %@", cleanTarget, available)
            )
        }
        _ = try await send(
            path: "/rest/api/2/issue/\(encodedKey)/transitions",
            method: "POST",
            jsonBody: ["transition": ["id": transitionID]]
        )
        if let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            try await addIssueComment(key: encodedKey, comment: comment)
        }
        return try await fetchIssue(key: encodedKey)
    }

    public func assignIssue(key: String, assignee: JiraUserContact?) async throws -> JiraRemoteIssue {
        let encodedKey = try Self.validatedJiraKey(key)
        let body: [String: Any]
        if let assignee {
            body = assignee.assigneePayload()
        } else {
            body = settings.isCloudHost ? ["accountId": NSNull()] : ["name": NSNull()]
        }
        _ = try await send(
            path: "/rest/api/2/issue/\(encodedKey)/assignee",
            method: "PUT",
            jsonBody: body
        )
        return try await fetchIssue(key: encodedKey)
    }

    private func transitionIssueIfNeeded(encodedKey: String, targetStatus: TaskWorkflowStatus) async throws {
        let data = try await send(path: "/rest/api/2/issue/\(encodedKey)/transitions", method: "GET")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transitions = root["transitions"] as? [[String: Any]] else { return }

        guard let match = Self.selectTransition(from: transitions, for: targetStatus),
              let transitionID = match["id"] as? String else { return }
        _ = try await send(
            path: "/rest/api/2/issue/\(encodedKey)/transitions",
            method: "POST",
            jsonBody: ["transition": ["id": transitionID]]
        )
    }

    public static func selectTransition(from transitions: [[String: Any]], matchingText targetText: String) -> [String: Any]? {
        let needle = targetText.workspaceFolded
        if !needle.isEmpty {
            if let exact = transitions.first(where: { candidate in
                let name = ((candidate["name"] as? String) ?? "").workspaceFolded
                let toName = (((candidate["to"] as? [String: Any])?["name"] as? String) ?? "").workspaceFolded
                return name == needle || toName == needle
            }) {
                return exact
            }
            if let contains = transitions.first(where: { candidate in
                let name = ((candidate["name"] as? String) ?? "").workspaceFolded
                let toName = (((candidate["to"] as? [String: Any])?["name"] as? String) ?? "").workspaceFolded
                return (!name.isEmpty && (name.contains(needle) || needle.contains(name))) ||
                    (!toName.isEmpty && (toName.contains(needle) || needle.contains(toName)))
            }) {
                return contains
            }
        }
        let mapped = mapWorkflowStatus(statusName: targetText, categoryKey: nil)
        return selectTransition(from: transitions, for: mapped)
    }

    public static func selectTransition(from transitions: [[String: Any]], for target: TaskWorkflowStatus) -> [String: Any]? {
        let preferredNames: [String]
        let desiredCategory: String
        switch target {
        case .todo:
            preferredNames = ["to do", "open", "backlog", "к выполнению", "открыто", "новая"]
            desiredCategory = "new"
        case .inProgress:
            preferredNames = ["in progress", "progress", "start", "в работе", "начать"]
            desiredCategory = "indeterminate"
        case .blocked:
            preferredNames = ["blocked", "on hold", "wait", "заблокировано", "блокировка", "ожидание"]
            desiredCategory = "indeterminate"
        case .inReview:
            preferredNames = ["in review", "review", "code review", "на ревью", "ревью", "на проверке"]
            desiredCategory = "indeterminate"
        case .done:
            preferredNames = ["done", "closed", "resolved", "complete", "готово", "выполнено", "закрыто"]
            desiredCategory = "done"
        case .cancelled:
            preferredNames = ["cancelled", "canceled", "rejected", "won't do", "отменено", "отклонено", "отмена"]
            desiredCategory = "done"
        }

        for candidate in transitions {
            let name = ((candidate["name"] as? String) ?? "").workspaceFolded
            let toName = (((candidate["to"] as? [String: Any])?["name"] as? String) ?? "").workspaceFolded
            if preferredNames.contains(where: { name.contains($0) || toName.contains($0) }) {
                return candidate
            }
        }
        return transitions.first { candidate in
            let category = (((candidate["to"] as? [String: Any])?["statusCategory"] as? [String: Any])?["key"] as? String ?? "").lowercased()
            return category == desiredCategory
        }
    }

    private func authorizationHeaders(hostKey: String) throws -> [String: String] {
        switch settings.authMode {
        case .personalAccessToken:
            guard let pat = secretProvider(hostKey, .jiraPersonalAccessToken)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !pat.isEmpty else {
                throw JiraConnectorError.missingCredentials
            }
            return ["Authorization": "Bearer \(pat)"]
        case .basicAuth:
            let username = settings.usernameOrEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty,
                  let secret = secretProvider(hostKey, .jiraBasicSecret)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !secret.isEmpty else {
                throw JiraConnectorError.missingCredentials
            }
            let encoded = Data("\(username):\(secret)".utf8).base64EncodedString()
            return ["Authorization": "Basic \(encoded)"]
        case .webSession:
            guard let cookieHeader = secretProvider(hostKey, .jiraSessionCookies)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cookieHeader.isEmpty else {
                throw JiraConnectorError.missingCredentials
            }
            return ["Cookie": cookieHeader, "X-Atlassian-Token": "no-check"]
        }
    }

    private func send(
        path: String,
        method: String,
        queryItems: [URLQueryItem]? = nil,
        jsonBody: [String: Any]? = nil
    ) async throws -> Data {
        guard let baseURL = settings.normalizedBaseURL,
              let hostKey = baseURL.host else {
            throw JiraConnectorError.invalidBaseURL
        }
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false) else {
            throw JiraConnectorError.invalidBaseURL
        }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw JiraConnectorError.invalidBaseURL }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")

        for (header, value) in try authorizationHeaders(hostKey: hostKey) {
            request.setValue(value, forHTTPHeaderField: header)
        }
        if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let (data, response) = try await MeetingAITransfer.send(request, using: session)
        guard let http = response as? HTTPURLResponse else {
            throw JiraConnectorError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw JiraConnectorError.unauthorized
        case 403:
            throw JiraConnectorError.forbidden(Self.extractErrorMessage(from: data))
        case 404:
            throw JiraConnectorError.notFound(Self.extractErrorMessage(from: data))
        case 400, 422:
            throw JiraConnectorError.badRequest(Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)")
        default:
            throw JiraConnectorError.serverError(http.statusCode, Self.extractErrorMessage(from: data))
        }
    }

    public static func stripHTMLTags(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parseUserObject(_ object: [String: Any], isServerOrDC: Bool) -> JiraUserContact? {
        if let active = object["active"] as? Bool, !active { return nil }
        let accountId = (object["accountId"] as? String)?.cleanedNilIfEmpty
        let name = (object["name"] as? String)?.cleanedNilIfEmpty
        let key = (object["key"] as? String)?.cleanedNilIfEmpty
        let identifier = isServerOrDC ? (name ?? key ?? accountId) : (accountId ?? name ?? key)
        guard let identifier, !identifier.isEmpty else { return nil }
        let rawDisplay = (object["displayName"] as? String)
            ?? (object["html"] as? String).map(stripHTMLTags)
            ?? identifier
        let cleanedDisplay = stripHTMLTags(rawDisplay)
        let displayName = cleanedDisplay.isEmpty ? identifier : cleanedDisplay
        return JiraUserContact(
            identifier: identifier,
            username: name ?? key,
            accountId: accountId,
            displayName: displayName,
            emailAddress: (object["emailAddress"] as? String)?.cleanedNilIfEmpty,
            isServerOrDC: isServerOrDC
        )
    }

    public static func parseIssueObject(
        _ object: [String: Any],
        baseURL: URL?,
        isServerOrDC: Bool
    ) -> JiraRemoteIssue? {
        guard let key = object["key"] as? String, !key.isEmpty else { return nil }
        let id = (object["id"] as? String) ?? key
        let fields = object["fields"] as? [String: Any] ?? [:]
        let summary = (fields["summary"] as? String) ?? key
        let description = extractDescriptionText(fields["description"])
        let statusObj = fields["status"] as? [String: Any] ?? [:]
        let statusName = (statusObj["name"] as? String) ?? "To Do"
        let categoryKey = (statusObj["statusCategory"] as? [String: Any])?["key"] as? String
        let workflowStatus = mapWorkflowStatus(statusName: statusName, categoryKey: categoryKey)
        let issueTypeName = ((fields["issuetype"] as? [String: Any])?["name"] as? String) ?? "Task"
        let issueKind = mapIssueKind(issueTypeName)
        let parentKey = extractParentEpicKey(from: fields)
        let priorityName = (fields["priority"] as? [String: Any])?["name"] as? String
        let dueDay = (fields["duedate"] as? String).flatMap { $0.count >= 10 ? String($0.prefix(10)) : nil }
        let assigneeObj = fields["assignee"] as? [String: Any]
        let assigneeContact = assigneeObj.flatMap { parseUserObject($0, isServerOrDC: isServerOrDC) }
        let reporterObj = fields["reporter"] as? [String: Any]
        let reporterContact = reporterObj.flatMap { parseUserObject($0, isServerOrDC: isServerOrDC) }
        let assigneeName = assigneeContact?.displayName ?? (assigneeObj?["displayName"] as? String)
        let assigneeIdentifier = assigneeContact?.identifier
            ?? (assigneeObj?["accountId"] as? String)
            ?? (assigneeObj?["name"] as? String)
        let updatedAt = (fields["updated"] as? String).flatMap(parseJiraDate)
        let browseURL = baseURL?.appendingPathComponent("browse/\(key)").absoluteString

        return JiraRemoteIssue(
            id: id,
            key: key,
            summary: summary,
            description: description,
            statusName: statusName,
            workflowStatus: workflowStatus,
            issueTypeName: issueTypeName,
            issueKind: issueKind,
            parentEpicKey: issueKind == .epic ? nil : parentKey,
            priority: mapPriority(priorityName),
            dueDay: dueDay,
            assigneeName: assigneeName,
            assigneeIdentifier: assigneeIdentifier,
            updatedAt: updatedAt,
            browseURL: browseURL,
            assigneeContact: assigneeContact,
            reporterContact: reporterContact
        )
    }

    static func mapIssueKind(_ name: String?) -> TaskIssueKind {
        guard let folded = name?.workspaceFolded, !folded.isEmpty else { return .task }
        if folded.contains("epic") || folded.contains("эпик") { return .epic }
        if folded.contains("bug") || folded.contains("defect") || folded.contains("ошиб") || folded.contains("баг") || folded.contains("дефект") {
            return .bug
        }
        if folded.contains("story") || folded.contains("истор") { return .story }
        return .task
    }

    static func extractParentEpicKey(from fields: [String: Any]) -> String? {
        if let parentObj = fields["parent"] as? [String: Any],
           let parentKey = parentObj["key"] as? String,
           !parentKey.isEmpty {
            return parentKey
        }
        for key in ["customfield_10014", "customfield_10008", "customfield_10100"] {
            if let str = fields[key] as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let obj = fields[key] as? [String: Any],
               let nestedKey = obj["key"] as? String,
               !nestedKey.isEmpty {
                return nestedKey
            }
        }
        return nil
    }

    static func mapWorkflowStatus(statusName: String, categoryKey: String?) -> TaskWorkflowStatus {
        let lower = statusName.workspaceFolded
        if lower.contains("block") || lower.contains("блок") || lower.contains("hold") || lower.contains("ожид") {
            return .blocked
        }
        if lower.contains("review") || lower.contains("ревью") || lower.contains("проверк") || lower.contains("qa") {
            return .inReview
        }
        if lower.contains("cancel") || lower.contains("отмен") || lower.contains("won't") || lower.contains("reject") {
            return .cancelled
        }
        if let categoryKey = categoryKey?.lowercased() {
            switch categoryKey {
            case "done": return .done
            case "indeterminate": return .inProgress
            case "new": return .todo
            default: break
            }
        }
        if lower.contains("done") || lower.contains("closed") || lower.contains("resolved") || lower.contains("готов") || lower.contains("закрыт") {
            return .done
        }
        if lower.contains("progress") || lower.contains("работ") {
            return .inProgress
        }
        return .todo
    }

    static func mapPriority(_ name: String?) -> TaskPriorityLevel? {
        guard let lower = name?.workspaceFolded, !lower.isEmpty else { return nil }
        if lower.contains("blocker") || lower.contains("critical") || lower.contains("highest") || lower.contains("крит") {
            return .critical
        }
        if lower.contains("high") || lower.contains("высок") || lower.contains("major") {
            return .high
        }
        if lower.contains("low") || lower.contains("низк") || lower.contains("minor") || lower.contains("trivial") {
            return .low
        }
        if lower.contains("medium") || lower.contains("сред") || lower.contains("normal") {
            return .medium
        }
        return nil
    }

    public static func jiraPriorityName(_ priority: TaskPriorityLevel) -> String {
        switch priority {
        case .critical: return "Critical"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    private static func extractDescriptionText(_ raw: Any?) -> String {
        if let str = raw as? String { return str }
        // Support Atlassian Document Format (ADF) returned by newer Jira versions if encountered.
        if let dict = raw as? [String: Any] {
            var fragments: [String] = []
            func walk(_ node: Any) {
                if let obj = node as? [String: Any] {
                    if let text = obj["text"] as? String { fragments.append(text) }
                    if let content = obj["content"] as? [Any] { content.forEach(walk) }
                } else if let array = node as? [Any] {
                    array.forEach(walk)
                }
            }
            walk(dict)
            return fragments.joined(separator: " ")
        }
        return ""
    }

    static func parseJiraDate(_ raw: String) -> Date? {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        ]
        for format in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = format
            if let date = df.date(from: raw) { return date }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var messages: [String] = []
        if let errorMessages = root["errorMessages"] as? [String] {
            messages.append(contentsOf: errorMessages)
        }
        if let errors = root["errors"] as? [String: Any] {
            for (field, value) in errors.sorted(by: { $0.key < $1.key }) {
                messages.append("\(field): \(value)")
            }
        }
        let combined = messages.filter { !$0.isEmpty }.joined(separator: "; ")
        return combined.isEmpty ? nil : String(combined.prefix(300))
    }
}

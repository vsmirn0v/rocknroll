import Foundation

@MainActor
public protocol JiraBoardWebEvaluating: AnyObject {
    var currentBoardURL: URL? { get }
    var isBoardLoading: Bool { get }
    func callBoardAsyncJS(_ functionBody: String, arguments: [String: Any]) async throws -> String
    func cookiesForBoard(matching origin: URL) async -> [HTTPCookie]
    func refreshBoardAfterJiraMutation(highlightIssueKey: String?) async
}

public extension JiraBoardWebEvaluating {
    var isBoardLoading: Bool { false }
}

public struct JiraBoardContextInfo: Equatable, Sendable {
    public var pageURL: URL
    public var baseURL: URL
    public var contextPath: String
    public var isCloud: Bool
    public var projectKey: String?
    public var rapidViewID: String?
    public var selectedIssueKey: String?
    public var looksLikeJiraURL: Bool

    public init(
        pageURL: URL,
        baseURL: URL,
        contextPath: String,
        isCloud: Bool,
        projectKey: String? = nil,
        rapidViewID: String? = nil,
        selectedIssueKey: String? = nil,
        looksLikeJiraURL: Bool = true
    ) {
        self.pageURL = pageURL
        self.baseURL = baseURL
        self.contextPath = contextPath
        self.isCloud = isCloud
        self.projectKey = projectKey
        self.rapidViewID = rapidViewID
        self.selectedIssueKey = selectedIssueKey
        self.looksLikeJiraURL = looksLikeJiraURL
    }

    public static func parse(from url: URL) -> JiraBoardContextInfo? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let isCloud = host.hasSuffix(".atlassian.net")
        let rawPath = url.path
        let lowerPath = rawPath.lowercased()

        var contextPath = ""
        if !isCloud {
            let markers = [
                "/secure/",
                "/browse/",
                "/projects/",
                "/jira/software/",
                "/jira/core/",
                "/jira/servicedesk/",
                "/issues/",
                "/plugins/",
                "/servicedesk/",
                "/login.jsp",
                "/rest/"
            ]
            var earliestIndex: String.Index?
            for marker in markers {
                if let range = lowerPath.range(of: marker) {
                    if earliestIndex == nil || range.lowerBound < earliestIndex! {
                        earliestIndex = range.lowerBound
                    }
                }
            }
            if let cut = earliestIndex {
                contextPath = String(rawPath[..<cut])
            }
            while contextPath.hasSuffix("/") {
                contextPath.removeLast()
            }
        }

        components.path = contextPath
        components.query = nil
        components.fragment = nil
        let baseURL = components.url ?? url

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func queryValue(_ names: [String]) -> String? {
            for name in names {
                if let val = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !val.isEmpty {
                    return val
                }
            }
            return nil
        }

        var rapidViewID = queryValue(["rapidView", "board", "boardId"])
        if rapidViewID == nil,
           let match = firstCapture(in: rawPath, pattern: #"/boards/([0-9]+)"#) {
            rapidViewID = match
        }

        var selectedIssueKey = queryValue(["selectedIssue", "focusedIssueKey"])
        if selectedIssueKey == nil,
           let browseIssue = firstCapture(in: rawPath, pattern: #"/browse/([A-Za-z][A-Za-z0-9_]+-[0-9]+)"#) {
            selectedIssueKey = browseIssue.uppercased()
        } else if let s = selectedIssueKey {
            selectedIssueKey = s.uppercased()
        }

        var projectKey = queryValue(["projectKey", "project"])?.uppercased()
        if projectKey == nil,
           let pathProj = firstCapture(in: rawPath, pattern: #"/projects/([A-Za-z][A-Za-z0-9_]+)"#) {
            projectKey = pathProj.uppercased()
        }
        if projectKey == nil,
           let issueKey = selectedIssueKey,
           let dash = issueKey.firstIndex(of: "-") {
            projectKey = String(issueKey[..<dash]).uppercased()
        }

        let looksLikeJira = isCloud
            || host.contains("jira")
            || lowerPath.contains("/secure/rapidboard")
            || lowerPath.contains("/jira/software")
            || lowerPath.contains("/browse/")
            || (lowerPath.contains("/projects/") && (lowerPath.contains("/boards/") || rapidViewID != nil))
            || rapidViewID != nil
            || selectedIssueKey != nil

        return JiraBoardContextInfo(
            pageURL: url,
            baseURL: baseURL,
            contextPath: contextPath,
            isCloud: isCloud,
            projectKey: projectKey,
            rapidViewID: rapidViewID,
            selectedIssueKey: selectedIssueKey,
            looksLikeJiraURL: looksLikeJira
        )
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    public static func matchingCookies(_ cookies: [HTTPCookie], for origin: URL) -> [HTTPCookie] {
        guard let host = origin.host?.lowercased(), !host.isEmpty else { return [] }
        let isHTTPS = origin.scheme?.lowercased() == "https"
        let reqPath = origin.path.isEmpty ? "/" : origin.path
        let now = Date()
        return cookies.filter { cookie in
            if let exp = cookie.expiresDate, exp < now { return false }
            if cookie.isSecure && !isHTTPS { return false }
            let domain = cookie.domain.lowercased()
            let domainMatch = domain.hasPrefix(".")
                ? (host == String(domain.dropFirst()) || host.hasSuffix(domain))
                : (host == domain || host.hasSuffix("." + domain))
            guard domainMatch else { return false }
            return cookie.path == "/" || reqPath.hasPrefix(cookie.path) || cookie.path.hasPrefix(reqPath)
        }
    }
}

public final class JiraBoardWebSessionConnector: JiraTaskConnecting, @unchecked Sendable {
    private weak var evaluator: (any JiraBoardWebEvaluating)?
    private let fallbackSettings: JiraConnectionSettings?

    public init(
        evaluator: any JiraBoardWebEvaluating,
        fallbackSettings: JiraConnectionSettings? = nil
    ) {
        self.evaluator = evaluator
        self.fallbackSettings = fallbackSettings
    }

    @MainActor
    private func resolvedContext() throws -> JiraBoardContextInfo {
        guard let evaluator else {
            throw JiraConnectorError.badRequest(L("Assistant Board is unavailable."))
        }
        if let url = evaluator.currentBoardURL,
           let parsed = JiraBoardContextInfo.parse(from: url) {
            return parsed
        }
        if let base = fallbackSettings?.normalizedBaseURL,
           let parsed = JiraBoardContextInfo.parse(from: base) {
            return parsed
        }
        throw JiraConnectorError.invalidBaseURL
    }

    // MARK: - JiraTaskConnecting

    public func verifyMyself() async throws -> JiraUserContact {
        let context = try await MainActor.run { try resolvedContext() }
        let object = try await fetchJSONObject(
            paths: context.isCloud
                ? ["/rest/api/3/myself", "/rest/api/2/myself"]
                : ["/rest/api/2/myself", "/rest/api/3/myself"],
            method: "GET"
        )
        guard let user = JiraTaskConnector.parseUserObject(object, isServerOrDC: !context.isCloud) else {
            throw JiraConnectorError.invalidResponse
        }
        return user
    }

    public func fetchProjectMetadata(projectKey: String) async throws -> JiraProjectMetadata {
        let context = try await MainActor.run { try resolvedContext() }
        let cleanKey = try JiraTaskConnector.validatedJiraKey(projectKey).uppercased()
        let object = try await fetchJSONObject(
            paths: context.isCloud
                ? ["/rest/api/3/project/\(cleanKey)", "/rest/api/2/project/\(cleanKey)"]
                : ["/rest/api/2/project/\(cleanKey)", "/rest/api/3/project/\(cleanKey)"],
            method: "GET"
        )
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
        let context = try await MainActor.run { try resolvedContext() }
        let cleanKey = projectKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let paramName = context.isCloud ? "query" : "username"
        var items = [
            URLQueryItem(name: "project", value: cleanKey),
            URLQueryItem(name: "maxResults", value: "200")
        ]
        if !query.isEmpty || !context.isCloud {
            items.append(URLQueryItem(name: paramName, value: query))
        }
        let array = try await fetchJSONArray(
            paths: context.isCloud
                ? ["/rest/api/3/user/assignable/search", "/rest/api/2/user/assignable/search"]
                : ["/rest/api/2/user/assignable/search", "/rest/api/3/user/assignable/search"],
            queryItems: items
        )
        return array.compactMap { JiraTaskConnector.parseUserObject($0, isServerOrDC: !context.isCloud) }
    }

    public func searchUsers(query: String, projectKey: String? = nil, maxResults: Int = 15) async throws -> [JiraUserContact] {
        let context = try await MainActor.run { try resolvedContext() }
        let cap = max(1, min(maxResults, 50))
        let terms = JiraContactMatcher.searchTerms(for: query)
        let cleanProject = (projectKey ?? context.projectKey ?? fallbackSettings?.cleanProjectKey ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let isServerOrDC = !context.isCloud
        let searchPaths = context.isCloud
            ? ["/rest/api/3/user/search", "/rest/api/2/user/search"]
            : ["/rest/api/2/user/search", "/rest/api/3/user/search"]
        let pickerPaths = context.isCloud
            ? ["/rest/api/3/user/picker", "/rest/api/2/user/picker"]
            : ["/rest/api/2/user/picker", "/rest/api/3/user/picker"]
        let paramName = context.isCloud ? "query" : "username"

        var collectedByID: [String: JiraUserContact] = [:]
        var orderedKeys: [String] = []
        var succeeded = false
        var firstError: Error?

        func addUsers(_ users: [JiraUserContact]) {
            for user in users {
                let key = user.identifier.lowercased()
                if collectedByID[key] == nil {
                    orderedKeys.append(key)
                }
                collectedByID[key] = user
            }
        }

        for term in terms.prefix(6) {
            let searchQuery = [
                URLQueryItem(name: paramName, value: term.isEmpty && isServerOrDC ? "." : term),
                URLQueryItem(name: "maxResults", value: String(cap))
            ]
            do {
                let array = try await fetchJSONArray(paths: searchPaths, queryItems: searchQuery)
                succeeded = true
                addUsers(array.compactMap { JiraTaskConnector.parseUserObject($0, isServerOrDC: isServerOrDC) })
            } catch {
                if firstError == nil { firstError = error }
            }
            if !term.isEmpty && orderedKeys.count < cap {
                let pickerQuery = [
                    URLQueryItem(name: "query", value: term),
                    URLQueryItem(name: "maxResults", value: String(cap))
                ]
                if let root = try? await fetchJSONObject(paths: pickerPaths, method: "GET", queryItems: pickerQuery),
                   let users = root["users"] as? [[String: Any]] {
                    succeeded = true
                    addUsers(users.compactMap { JiraTaskConnector.parseUserObject($0, isServerOrDC: isServerOrDC) })
                }
            }
            if !cleanProject.isEmpty && orderedKeys.isEmpty {
                do {
                    let assignable = try await fetchAssignableUsers(projectKey: cleanProject, query: term)
                    succeeded = true
                    addUsers(assignable)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
        }

        if let me = try? await verifyMyself() {
            succeeded = true
            let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || JiraContactMatcher.matchScore(
                name: raw,
                candidateNames: [me.displayName, me.username ?? "", me.identifier],
                candidateEmail: me.emailAddress,
                candidateUsername: me.username
            ) >= 0.55 {
                addUsers([me])
            }
        }

        if !succeeded, let firstError {
            throw firstError
        }

        let unique = orderedKeys.compactMap { collectedByID[$0] }
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return Array(unique.prefix(cap))
        }
        let ranked = unique.enumerated().sorted { lhs, rhs in
            let lScore = JiraContactMatcher.matchScore(
                name: raw,
                candidateNames: [lhs.element.displayName, lhs.element.username ?? "", lhs.element.identifier],
                candidateEmail: lhs.element.emailAddress,
                candidateUsername: lhs.element.username
            )
            let rScore = JiraContactMatcher.matchScore(
                name: raw,
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
        let context = try await MainActor.run { try resolvedContext() }
        let cap = max(1, min(maxResults, 200))
        let fields = [
            "summary", "description", "status", "priority", "duedate",
            "assignee", "reporter", "updated", "created", "resolutiondate", "issuetype", "project",
            "parent", "customfield_10014", "customfield_10008", "customfield_10100"
        ]
        let root: [String: Any]
        if context.isCloud {
            // Try newer Jira Cloud /rest/api/3/search/jql first, falling back to classic POST search.
            let body: [String: Any] = ["jql": jql, "maxResults": cap, "fields": fields]
            if let modern = try? await fetchJSONObject(
                paths: ["/rest/api/3/search/jql", "/rest/api/3/search", "/rest/api/2/search"],
                method: "POST",
                jsonBody: body
            ) {
                root = modern
            } else {
                root = try await fetchJSONObject(
                    paths: ["/rest/api/2/search", "/rest/api/3/search"],
                    method: "POST",
                    jsonBody: ["jql": jql, "startAt": 0, "maxResults": cap, "fields": fields]
                )
            }
        } else {
            root = try await fetchJSONObject(
                paths: ["/rest/api/2/search", "/rest/api/3/search"],
                method: "POST",
                jsonBody: ["jql": jql, "startAt": 0, "maxResults": cap, "fields": fields]
            )
        }
        guard let issues = root["issues"] as? [[String: Any]] else {
            throw JiraConnectorError.invalidResponse
        }
        return issues.compactMap {
            JiraTaskConnector.parseIssueObject($0, baseURL: context.baseURL, isServerOrDC: !context.isCloud)
        }
    }

    public func fetchActiveBoardIssues(maxResults: Int = 60) async throws -> [JiraRemoteIssue] {
        let context = try await MainActor.run { try resolvedContext() }
        let cap = max(1, min(maxResults, 100))
        if let rapidViewID = context.rapidViewID {
            let fieldsParam = "summary,description,status,priority,duedate,assignee,reporter,updated,issuetype,project,parent"
            if let root = try? await fetchJSONObject(
                paths: ["/rest/agile/1.0/board/\(rapidViewID)/issue"],
                method: "GET",
                queryItems: [
                    URLQueryItem(name: "maxResults", value: String(cap)),
                    URLQueryItem(name: "fields", value: fieldsParam)
                ]
            ),
               let issues = root["issues"] as? [[String: Any]] {
                let parsed = issues.compactMap {
                    JiraTaskConnector.parseIssueObject($0, baseURL: context.baseURL, isServerOrDC: !context.isCloud)
                }
                if !parsed.isEmpty {
                    return parsed
                }
            }
        }

        if let selectedKey = context.selectedIssueKey,
           let selected = try? await fetchIssueDetails(key: selectedKey) {
            let proj = context.projectKey ?? String(selected.key.split(separator: "-").first ?? "")
            if !proj.isEmpty,
               let projectIssues = try? await searchIssues(jql: "project = \"\(proj)\" ORDER BY updated DESC", maxResults: cap) {
                var combined = projectIssues
                if !combined.contains(where: { $0.key.caseInsensitiveCompare(selected.key) == .orderedSame }) {
                    combined.insert(selected, at: 0)
                }
                return combined
            }
            return [selected]
        }

        if let proj = context.projectKey, !proj.isEmpty {
            return try await searchIssues(jql: "project = \"\(proj)\" ORDER BY updated DESC", maxResults: cap)
        }
        return try await searchIssues(jql: "updated >= -30d ORDER BY updated DESC", maxResults: cap)
    }

    /// Derives candidate Jira project keys from the active board URL, visible DOM cards,
    /// Jira Agile REST board endpoints (`/project`, `/configuration`), or active board issues.
    public func deriveBoardProjectKeys() async -> [String] {
        guard let context = try? await MainActor.run(body: { try resolvedContext() }) else {
            return []
        }
        var ordered: [String] = []
        var seen: Set<String> = []
        func addKey(_ raw: String?) {
            guard let raw else { return }
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !clean.isEmpty,
                  clean.range(of: #"^[A-Z][A-Z0-9_]+$"#, options: .regularExpression) != nil,
                  seen.insert(clean).inserted else {
                return
            }
            ordered.append(clean)
        }

        addKey(context.projectKey)

        if let evaluator {
            let rawDOM: String? = try? await evaluator.callBoardAsyncJS(
                JiraBoardDOMScripts.extractBoardContextScript(),
                arguments: [:]
            )
            if let data = rawDOM?.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let domProjects = obj["projectKeys"] as? [String] {
                    for key in domProjects { addKey(key) }
                }
                if let domIssues = obj["issueKeys"] as? [String] {
                    for issueKey in domIssues {
                        if let dash = issueKey.firstIndex(of: "-") {
                            addKey(String(issueKey[..<dash]))
                        }
                    }
                }
            }
        }

        if ordered.isEmpty, let rapidViewID = context.rapidViewID {
            if let root = try? await fetchJSONObject(
                paths: ["/rest/agile/1.0/board/\(rapidViewID)/project"],
                method: "GET"
            ),
               let values = root["values"] as? [[String: Any]] {
                for item in values {
                    addKey(item["key"] as? String)
                }
            }
        }

        if ordered.isEmpty, let rapidViewID = context.rapidViewID {
            if let config = try? await fetchJSONObject(
                paths: ["/rest/agile/1.0/board/\(rapidViewID)/configuration"],
                method: "GET"
            ) {
                if let location = config["location"] as? [String: Any] {
                    addKey(location["projectKey"] as? String ?? location["key"] as? String)
                }
                if let filter = config["filter"] as? [String: Any] {
                    let filterID = (filter["id"] as? String)
                        ?? (filter["id"] as? Int).map(String.init)
                    if let query = filter["query"] as? String {
                        for key in Self.extractProjectKeys(fromJQL: query) { addKey(key) }
                    } else if ordered.isEmpty, let filterID,
                              let filterObj = try? await fetchJSONObject(
                                paths: ["/rest/api/2/filter/\(filterID)", "/rest/api/3/filter/\(filterID)"],
                                method: "GET"
                              ),
                              let jql = filterObj["jql"] as? String {
                        for key in Self.extractProjectKeys(fromJQL: jql) { addKey(key) }
                    }
                }
            }
        }

        if ordered.isEmpty,
           let boardIssues = try? await fetchActiveBoardIssues(maxResults: 25) {
            var counts: [String: Int] = [:]
            var firstOrder: [String] = []
            for issue in boardIssues {
                if let dash = issue.key.firstIndex(of: "-") {
                    let prefix = String(issue.key[..<dash]).uppercased()
                    if counts[prefix] == nil {
                        firstOrder.append(prefix)
                    }
                    counts[prefix, default: 0] += 1
                }
            }
            let ranked = firstOrder.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
            for key in ranked { addKey(key) }
        }

        return ordered
    }

    public static func extractProjectKeys(fromJQL jql: String) -> [String] {
        var keys: [String] = []
        var seen: Set<String> = []
        func add(_ raw: String) {
            let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))).uppercased()
            guard !upper.isEmpty,
                  upper.range(of: #"^[A-Z][A-Z0-9_]+$"#, options: .regularExpression) != nil,
                  seen.insert(upper).inserted else { return }
            keys.append(upper)
        }
        let nsRange = NSRange(jql.startIndex..<jql.endIndex, in: jql)
        if let eqRegex = try? NSRegularExpression(
            pattern: #"\bproject\s*=\s*["']?([A-Za-z][A-Za-z0-9_]+)["']?"#,
            options: [.caseInsensitive]
        ) {
            for match in eqRegex.matches(in: jql, range: nsRange) {
                if match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: jql) {
                    add(String(jql[r]))
                }
            }
        }
        if let inRegex = try? NSRegularExpression(
            pattern: #"\bproject\s+in\s*\(([^)]+)\)"#,
            options: [.caseInsensitive]
        ) {
            for match in inRegex.matches(in: jql, range: nsRange) {
                if match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: jql) {
                    for part in jql[r].split(separator: ",") {
                        add(String(part))
                    }
                }
            }
        }
        return keys
    }

    public func fetchIssueDetails(key: String) async throws -> JiraRemoteIssue {
        let context = try await MainActor.run { try resolvedContext() }
        let encodedKey = try JiraTaskConnector.validatedJiraKey(key)
        let object = try await fetchJSONObject(
            paths: context.isCloud
                ? ["/rest/api/3/issue/\(encodedKey)", "/rest/api/2/issue/\(encodedKey)"]
                : ["/rest/api/2/issue/\(encodedKey)", "/rest/api/3/issue/\(encodedKey)"],
            method: "GET"
        )
        guard let issue = JiraTaskConnector.parseIssueObject(object, baseURL: context.baseURL, isServerOrDC: !context.isCloud) else {
            throw JiraConnectorError.invalidResponse
        }
        return issue
    }

    public func createIssue(_ payload: JiraIssueWritePayload) async throws -> JiraRemoteIssue {
        let context = try await MainActor.run { try resolvedContext() }
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
        if let priority = payload.priority { fields["priority"] = ["name": JiraTaskConnector.jiraPriorityName(priority)] }
        if payload.issueKind == .epic {
            fields["customfield_10011"] = String(payload.summary.prefix(120))
        } else if let epicKey = payload.parentEpicKey?.trimmingCharacters(in: .whitespacesAndNewlines), !epicKey.isEmpty {
            if context.isCloud {
                fields["parent"] = ["key": epicKey]
            } else {
                fields["customfield_10014"] = epicKey
            }
        }

        let created = try await fetchJSONObject(
            paths: ["/rest/api/2/issue", "/rest/api/3/issue"],
            method: "POST",
            jsonBody: ["fields": fields]
        )
        guard let key = created["key"] as? String, !key.isEmpty else {
            throw JiraConnectorError.invalidResponse
        }
        return try await fetchIssueDetails(key: key)
    }

    public func updateIssue(
        key: String,
        payload: JiraIssueWritePayload,
        targetStatus: TaskWorkflowStatus?,
        comment: String?
    ) async throws -> JiraRemoteIssue {
        let encodedKey = try JiraTaskConnector.validatedJiraKey(key)
        var fields: [String: Any] = [
            "summary": String(payload.summary.prefix(255))
        ]
        let desc = payload.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { fields["description"] = desc }
        if let dueDay = payload.dueDay, !dueDay.isEmpty { fields["duedate"] = dueDay }
        if let assignee = payload.assignee { fields["assignee"] = assignee.assigneePayload() }

        _ = try await sendWebRequest(
            paths: ["/rest/api/2/issue/\(encodedKey)", "/rest/api/3/issue/\(encodedKey)"],
            method: "PUT",
            jsonBody: ["fields": fields]
        )
        if let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            try await addIssueComment(key: encodedKey, comment: comment)
        }
        if let targetStatus {
            return try await transitionIssue(key: encodedKey, targetStatusText: targetStatus.localizedTitle, comment: nil)
        }
        return try await fetchIssueDetails(key: encodedKey)
    }

    public func addIssueComment(key: String, comment: String) async throws {
        let encodedKey = try JiraTaskConnector.validatedJiraKey(key)
        let clean = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw JiraConnectorError.badRequest(L("Comment text cannot be empty."))
        }
        _ = try await sendWebRequest(
            paths: ["/rest/api/2/issue/\(encodedKey)/comment"],
            method: "POST",
            jsonBody: ["body": String(clean.prefix(8_000))]
        )
    }

    public func transitionIssue(key: String, targetStatusText: String, comment: String? = nil) async throws -> JiraRemoteIssue {
        let context = try await MainActor.run { try resolvedContext() }
        let encodedKey = try JiraTaskConnector.validatedJiraKey(key)
        let cleanTarget = targetStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTarget.isEmpty else {
            throw JiraConnectorError.badRequest(L("Target status is required."))
        }
        let paths = context.isCloud
            ? ["/rest/api/3/issue/\(encodedKey)/transitions", "/rest/api/2/issue/\(encodedKey)/transitions"]
            : ["/rest/api/2/issue/\(encodedKey)/transitions", "/rest/api/3/issue/\(encodedKey)/transitions"]
        let root = try await fetchJSONObject(paths: paths, method: "GET")
        guard let transitions = root["transitions"] as? [[String: Any]] else {
            throw JiraConnectorError.invalidResponse
        }
        guard let match = JiraTaskConnector.selectTransition(from: transitions, matchingText: cleanTarget),
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
        _ = try await sendWebRequest(
            paths: paths,
            method: "POST",
            jsonBody: ["transition": ["id": transitionID]]
        )
        if let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            try await addIssueComment(key: encodedKey, comment: comment)
        }
        return try await fetchIssueDetails(key: encodedKey)
    }

    public func assignIssue(key: String, assignee: JiraUserContact?) async throws -> JiraRemoteIssue {
        let context = try await MainActor.run { try resolvedContext() }
        let encodedKey = try JiraTaskConnector.validatedJiraKey(key)
        let body: [String: Any]
        if let assignee {
            body = assignee.assigneePayload()
        } else {
            body = context.isCloud ? ["accountId": NSNull()] : ["name": NSNull()]
        }
        let paths = context.isCloud
            ? ["/rest/api/3/issue/\(encodedKey)/assignee", "/rest/api/2/issue/\(encodedKey)/assignee"]
            : ["/rest/api/2/issue/\(encodedKey)/assignee", "/rest/api/3/issue/\(encodedKey)/assignee"]
        _ = try await sendWebRequest(paths: paths, method: "PUT", jsonBody: body)
        return try await fetchIssueDetails(key: encodedKey)
    }

    // MARK: - Same-Origin WebView Fetch

    private func fetchJSONObject(
        paths: [String],
        method: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let data = try await sendWebRequest(paths: paths, method: method, queryItems: queryItems, jsonBody: jsonBody)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraConnectorError.invalidResponse
        }
        return object
    }

    private func fetchJSONArray(
        paths: [String],
        queryItems: [URLQueryItem] = []
    ) async throws -> [[String: Any]] {
        let data = try await sendWebRequest(paths: paths, method: "GET", queryItems: queryItems)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw JiraConnectorError.invalidResponse
        }
        return array
    }

    private func sendWebRequest(
        paths: [String],
        method: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: [String: Any]? = nil
    ) async throws -> Data {
        let bodyString: String?
        if let jsonBody {
            let encoded = try JSONSerialization.data(withJSONObject: jsonBody)
            bodyString = String(decoding: encoded, as: UTF8.self)
        } else {
            bodyString = nil
        }

        let context = try await MainActor.run { try resolvedContext() }
        var lastError: Error = JiraConnectorError.invalidResponse

        for rawPath in paths {
            var components = URLComponents()
            components.path = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }
            let relativeEndpoint = components.string ?? rawPath

            do {
                return try await executeWebFetch(
                    endpoint: relativeEndpoint,
                    fallbackContextPath: context.contextPath,
                    method: method,
                    bodyJSONString: bodyString
                )
            } catch JiraConnectorError.notFound {
                lastError = JiraConnectorError.notFound(nil)
                continue
            } catch {
                throw error
            }
        }
        throw lastError
    }

    private func executeWebFetch(
        endpoint: String,
        fallbackContextPath: String,
        method: String,
        bodyJSONString: String?
    ) async throws -> Data {
        let responseText = try await performAsyncJS(
            endpoint: endpoint,
            fallbackContextPath: fallbackContextPath,
            method: method,
            bodyJSONString: bodyJSONString
        )
        guard let envelopeData = responseText.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
              let status = envelope["status"] as? Int else {
            throw JiraConnectorError.invalidResponse
        }
        let bodyText = (envelope["body"] as? String) ?? ""
        let payloadData = Data(bodyText.utf8)

        switch status {
        case 200...299:
            return payloadData
        case 401:
            throw JiraConnectorError.unauthorized
        case 403:
            throw JiraConnectorError.forbidden(extractErrorMessage(from: payloadData))
        case 404:
            throw JiraConnectorError.notFound(extractErrorMessage(from: payloadData))
        case 400, 422:
            throw JiraConnectorError.badRequest(extractErrorMessage(from: payloadData) ?? "HTTP \(status)")
        default:
            throw JiraConnectorError.serverError(status, extractErrorMessage(from: payloadData))
        }
    }

    public static let defaultFetchTimeoutMilliseconds = 6_000

    public static func webFetchScript() -> String {
        """
        const metaCtx = document.querySelector('meta[name="ajs-context-path"]')?.getAttribute('content') || '';
        const ctx = (metaCtx || fallbackContextPath || '').replace(/\\/+$/, '');
        const cleanEndpoint = endpoint.startsWith('/') ? endpoint : ('/' + endpoint);
        const url = (ctx && !cleanEndpoint.startsWith(ctx + '/')) ? (ctx + cleanEndpoint) : cleanEndpoint;
        const effectiveTimeout = (typeof fetchTimeoutMs === 'number' && fetchTimeoutMs > 0) ? fetchTimeoutMs : 6000;
        const headers = {
            'Accept': 'application/json',
            'X-Atlassian-Token': 'no-check'
        };
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), effectiveTimeout);
        const init = {
            method: method,
            credentials: 'include',
            headers: headers,
            signal: controller.signal
        };
        if (typeof bodyJSON !== 'undefined' && bodyJSON !== null && method !== 'GET') {
            headers['Content-Type'] = 'application/json';
            init.body = bodyJSON;
        }
        try {
            const resp = await fetch(url, init);
            const text = await resp.text();
            return JSON.stringify({ ok: resp.ok, status: resp.status, body: text });
        } catch (err) {
            if (err && err.name === 'AbortError') {
                return JSON.stringify({ ok: false, status: 408, body: 'Request timed out' });
            }
            throw err;
        } finally {
            clearTimeout(timer);
        }
        """
    }

    @MainActor
    private func performAsyncJS(
        endpoint: String,
        fallbackContextPath: String,
        method: String,
        bodyJSONString: String?
    ) async throws -> String {
        guard let evaluator else {
            throw JiraConnectorError.badRequest(L("Assistant Board is unavailable."))
        }
        let js = Self.webFetchScript()
        var args: [String: Any] = [
            "endpoint": endpoint,
            "fallbackContextPath": fallbackContextPath,
            "method": method,
            "fetchTimeoutMs": Self.defaultFetchTimeoutMilliseconds
        ]
        args["bodyJSON"] = bodyJSONString ?? NSNull()
        return try await evaluator.callBoardAsyncJS(js, arguments: args)
    }

    private func extractErrorMessage(from data: Data) -> String? {
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
        if let msg = root["message"] as? String, !msg.isEmpty {
            messages.append(msg)
        }
        let combined = messages.filter { !$0.isEmpty }.joined(separator: "; ")
        return combined.isEmpty ? nil : String(combined.prefix(300))
    }
}

// MARK: - Shared Board DOM Automation Scripts

public enum JiraBoardDOMScripts {
    private static let bannerHelperJS = """
    function showBanner(text, accent) {
        const id = '__rnr-board-action-banner';
        let el = document.getElementById(id);
        if (!el) {
            el = document.createElement('div');
            el.id = id;
            el.style.cssText = 'position:fixed;top:12px;right:12px;z-index:2147483647;padding:8px 14px;border-radius:10px;background:rgba(24,24,28,0.92);color:#fff;font:600 13px -apple-system,BlinkMacSystemFont,sans-serif;box-shadow:0 6px 20px rgba(0,0,0,0.35);pointer-events:none;transition:opacity 0.25s ease;backdrop-filter:blur(8px);max-width:340px;';
            document.body.appendChild(el);
        }
        el.style.borderLeft = '4px solid ' + (accent || '#f59e0b');
        el.textContent = text;
        el.style.opacity = '1';
        clearTimeout(el.__rnrTimer);
        el.__rnrTimer = setTimeout(() => { el.style.opacity = '0'; }, 3500);
    }
    """

    public static func personFilterCandidateTerms(
        query: String,
        directory: AssistantPeopleDirectory
    ) -> (terms: [String], label: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = AssistantPeopleDirectory.strippedMeetingDisplayName(clean)
        let label = stripped.isEmpty ? clean : stripped

        var candidates: [String] = []
        var seen: Set<String> = []
        func add(_ raw: String?) {
            guard let raw else { return }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2 else { return }
            let key = t.lowercased()
            if seen.insert(key).inserted {
                candidates.append(t)
            }
        }

        if let person = directory.resolvePerson(matching: clean) ?? directory.resolvePerson(matching: label) {
            add(person.displayName)
            for alias in person.aliases {
                let s = AssistantPeopleDirectory.strippedMeetingDisplayName(alias)
                add(s.isEmpty ? alias : s)
            }
            add(person.jiraUsername)
            add(person.email)
            if let emailLocal = person.email?.split(separator: "@").first.map(String.init) {
                add(emailLocal)
            }
            for term in JiraContactMatcher.searchTerms(for: person.displayName) {
                add(term)
            }
        }

        add(label)
        add(clean)
        for term in JiraContactMatcher.searchTerms(for: label) {
            add(term)
        }
        return (candidates, label)
    }

    public static func selectPersonFilterScript(candidateTerms: [String], displayLabel: String) -> String {
        let encodedTerms = encodeJSONLiteral(candidateTerms)
        let encodedLabel = encodeJSONLiteral(displayLabel)
        return """
        const terms = \(encodedTerms).map(t => String(t || '').trim().toLowerCase()).filter(Boolean);
        const displayLabel = \(encodedLabel);
        \(bannerHelperJS)
        const normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
        const isVisible = (el) => {
            if (!el) return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && getComputedStyle(el).visibility !== 'hidden';
        };
        const tokensFrom = (s) => normalize(s).split(/[^\\p{L}\\p{N}]+/u).filter(t => t.length >= 2);
        const matchesTerm = (candidateText) => {
            const hay = normalize(candidateText);
            if (!hay) return false;
            const hayTokens = tokensFrom(hay);
            for (const term of terms) {
                if (hay.includes(term)) return true;
                const tTokens = tokensFrom(term);
                if (tTokens.length >= 2 && tTokens.every(tt => hayTokens.some(ht => ht.includes(tt) || tt.includes(ht)))) {
                    return true;
                }
            }
            return false;
        };
        const metaText = (el) => {
            const parts = [
                el.getAttribute('aria-label'),
                el.getAttribute('title'),
                el.getAttribute('data-tooltip'),
                el.getAttribute('alt'),
                el.textContent
            ];
            for (const img of el.querySelectorAll('img')) {
                parts.push(img.getAttribute('alt'), img.getAttribute('aria-label'), img.getAttribute('title'));
            }
            return parts.filter(Boolean).join(' ').trim();
        };
        const isAvatarFilterEl = (el) => {
            const tid = (el.getAttribute('data-testid') || '') + ' ' + (el.getAttribute('class') || '');
            return tid.includes('avatar') || tid.includes('quick-filter') || tid.includes('ghx-avatar') || !!el.closest('[data-testid*="filters"], #ghx-quick-filters');
        };
        const isSelectedFilter = (el) => {
            const pressed = el.getAttribute('aria-pressed') === 'true' || el.getAttribute('aria-checked') === 'true' || el.getAttribute('data-selected') === 'true';
            const cls = String(el.getAttribute('class') || '').toLowerCase();
            return pressed || cls.includes('active') || cls.includes('selected') || cls.includes('ghx-active');
        };
        const clickEl = (el) => {
            el.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
            el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
            el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
            el.click();
        };

        const candidateSelector = '[data-testid*="filters.ui.stateless.avatar"] button, [data-testid*="avatar-filter"], [data-testid*="quick-filter"], .ghx-quick-filter a, .ghx-quick-filter button, .ghx-avatar-filter, #ghx-quick-filters button, #ghx-quick-filters a, [role="checkbox"][aria-label], [role="button"][aria-pressed]';
        let controls = Array.from(document.querySelectorAll(candidateSelector)).filter(isVisible);

        const findBestMatch = (list) => {
            for (const el of list) {
                const label = metaText(el);
                if (matchesTerm(label)) return { el, label };
            }
            return null;
        };

        let found = findBestMatch(controls);
        if (!found) {
            const expanders = Array.from(document.querySelectorAll('[data-testid*="avatar"] button, [data-testid*="filters"] button, #ghx-quick-filters button')).filter(el => {
                if (!isVisible(el)) return false;
                const txt = normalize(metaText(el));
                return /^\\+\\d+$/.test(txt) || txt.includes('more') || txt.includes('ещё') || txt.includes('еще') || txt.includes('assignee') || txt.includes('исполнител');
            });
            if (expanders.length > 0) {
                clickEl(expanders[0]);
                await new Promise(r => setTimeout(r, 250));
                controls = Array.from(document.querySelectorAll(candidateSelector + ', [role="menuitem"], [role="option"]')).filter(isVisible);
                found = findBestMatch(controls);
            }
        }

        if (found) {
            // Deselect other active person filters when selecting a new speaker cleanly.
            for (const el of controls) {
                if (el !== found.el && isAvatarFilterEl(el) && isSelectedFilter(el)) {
                    clickEl(el);
                }
            }
            if (!isSelectedFilter(found.el)) {
                clickEl(found.el);
            }
            showBanner('Filtering: ' + (found.label || displayLabel), '#22c55e');
            return JSON.stringify({ matched: true, method: 'avatar_filter', label: found.label || displayLabel });
        }

        const searchSelectors = [
            'input[data-testid*="search"]',
            'input[placeholder*="Search" i]',
            'input[placeholder*="Filter" i]',
            'input[placeholder*="Поиск" i]',
            'input[placeholder*="Фильтр" i]',
            'input[aria-label*="Search" i]',
            'input[aria-label*="Поиск" i]',
            '#ghx-board-search input',
            'input[type="search"]'
        ];
        for (const sel of searchSelectors) {
            const input = Array.from(document.querySelectorAll(sel)).find(isVisible);
            if (input) {
                const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
                const filterWord = (displayLabel.split(/\\s+/)[0] || terms[0] || '');
                if (setter) setter.call(input, filterWord);
                else input.value = filterWord;
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
                showBanner('Filtered board: ' + filterWord, '#f59e0b');
                return JSON.stringify({ matched: true, method: 'search_input', label: filterWord });
            }
        }
        return JSON.stringify({ matched: false, method: 'none', label: displayLabel });
        """
    }

    public static func filterBoardScript(query: String) -> String {
        let encodedQuery = encodeJSONLiteral(query)
        return """
        const q = \(encodedQuery);
        \(bannerHelperJS)
        const selectors = [
            'input[data-testid*="search"]',
            'input[placeholder*="Search" i]',
            'input[placeholder*="Filter" i]',
            'input[placeholder*="Поиск" i]',
            'input[placeholder*="Фильтр" i]',
            'input[aria-label*="Search" i]',
            'input[aria-label*="Поиск" i]',
            '#ghx-board-search input',
            'input[type="search"]'
        ];
        for (const sel of selectors) {
            const input = Array.from(document.querySelectorAll(sel)).find(el => {
                const r = el.getBoundingClientRect();
                return r.width > 0 && r.height > 0;
            });
            if (input) {
                const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
                if (setter) setter.call(input, q);
                else input.value = q;
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
                showBanner(q ? ('Filtered board: ' + q) : 'Cleared board search', '#f59e0b');
                return 'Filtered board using ' + sel + ': ' + q;
            }
        }
        return 'No board search input matched selector.';
        """
    }

    public static func clearFiltersScript() -> String {
        """
        \(bannerHelperJS)
        let cleared = 0;
        const buttons = Array.from(document.querySelectorAll('button, a'));
        for (const el of buttons) {
            const label = ((el.textContent || '') + ' ' + (el.getAttribute('aria-label') || '')).trim().toLowerCase();
            if (label.includes('clear filters') || label.includes('clear all') || label.includes('сбросить фильтр') || label.includes('очистить фильтр')) {
                el.click();
                cleared += 1;
            } else if (el.getAttribute('aria-pressed') === 'true' && !!el.closest('[data-testid*="filters"], #ghx-quick-filters')) {
                el.click();
                cleared += 1;
            }
        }
        const searchInputs = document.querySelectorAll('input[data-testid*="search"], #ghx-board-search input, input[type="search"], input[placeholder*="Filter" i], input[placeholder*="Поиск" i]');
        for (const input of searchInputs) {
            if (input.value) {
                const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
                if (setter) setter.call(input, '');
                else input.value = '';
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                cleared += 1;
            }
        }
        showBanner('Cleared board filters', '#60a5fa');
        return 'Cleared filters (' + cleared + ' controls updated).';
        """
    }

    private static let highlightCardHelperJS = """
        const highlightIssueCard = (rawKey) => {
            const safeKey = String(rawKey || '').trim();
            if (!safeKey) return false;
            const escaped = (typeof CSS !== 'undefined' && CSS.escape)
                ? CSS.escape(safeKey)
                : safeKey.replace(/[^A-Za-z0-9_-]/g, '');
            const card = document.querySelector('[data-issue-key="' + escaped + '"]') ||
                         Array.from(document.querySelectorAll('[data-testid*="card"], .ghx-issue, tr, a[href*="/browse/"]'))
                            .find(e => (e.textContent || '').includes(safeKey) || (e.getAttribute('href') || '').includes('/browse/' + safeKey));
            if (card) {
                card.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
                const prev = card.style.outline;
                const prevShadow = card.style.boxShadow;
                card.style.outline = '3px solid #22c55e';
                card.style.boxShadow = '0 0 18px rgba(34, 197, 94, 0.55)';
                setTimeout(() => { card.style.outline = prev; card.style.boxShadow = prevShadow; }, 4500);
                return true;
            }
            return false;
        };
    """

    public static func refreshBoardAfterMutationScript(highlightIssueKey: String?) -> String {
        let encodedKey = encodeJSONLiteral(highlightIssueKey ?? "")
        return """
        const issueKey = \(encodedKey);
        \(bannerHelperJS)
        \(highlightCardHelperJS)
        let refreshedInPlace = false;
        try {
            if (window.GH && GH.WorkController && typeof GH.WorkController.reload === 'function') {
                GH.WorkController.reload();
                refreshedInPlace = true;
            } else if (window.GH && GH.RapidBoard && GH.RapidBoard.State && typeof GH.RapidBoard.State.update === 'function') {
                GH.RapidBoard.State.update();
                refreshedInPlace = true;
            }
        } catch (_) {}
        if (!refreshedInPlace) {
            const refreshButtons = Array.from(document.querySelectorAll('button[aria-label*="Refresh" i], button[aria-label*="Обновить" i], [data-testid*="refresh"] button, .ghx-refresh-link'));
            if (refreshButtons.length > 0) {
                refreshButtons[0].click();
                refreshedInPlace = true;
            }
        }
        if (issueKey) {
            highlightIssueCard(issueKey);
            showBanner('Updated ' + issueKey, '#22c55e');
        }
        return JSON.stringify({ refreshedInPlace, issueKey });
        """
    }

    public static func highlightIssueScript(issueKey: String) -> String {
        let encodedKey = encodeJSONLiteral(issueKey)
        return """
        const issueKey = \(encodedKey);
        \(bannerHelperJS)
        \(highlightCardHelperJS)
        const found = highlightIssueCard(issueKey);
        if (issueKey) {
            showBanner('Updated ' + issueKey, '#22c55e');
        }
        return JSON.stringify({ found, issueKey });
        """
    }

    public static func parseRefreshedInPlace(_ rawJSON: String) -> Bool {
        guard let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (obj["refreshedInPlace"] as? Bool) == true
    }

    public static func enhancedInspectScript() -> String {
        """
        const activeFilters = Array.from(document.querySelectorAll('[aria-pressed="true"], .ghx-active'))
            .map(el => (el.getAttribute('aria-label') || el.getAttribute('title') || el.textContent || '').trim())
            .filter(Boolean)
            .slice(0, 12);
        const filterAssignees = Array.from(document.querySelectorAll('[data-testid*="filters.ui.stateless.avatar"] button, .ghx-avatar-filter, [data-testid*="avatar-filter"]'))
            .map(el => {
                const img = el.querySelector('img');
                return (el.getAttribute('aria-label') || el.getAttribute('title') || img?.getAttribute('alt') || el.textContent || '').trim();
            })
            .filter(Boolean)
            .slice(0, 30);
        const cards = Array.from(document.querySelectorAll('[data-testid*="card"], .ghx-issue, [data-issue-key]')).slice(0, 40).map(card => {
            const key = card.getAttribute('data-issue-key') ||
                        (card.textContent.match(/[A-Z][A-Z0-9_]+-\\d+/) || [null])[0];
            const assigneeImg = card.querySelector('img[alt], [data-testid*="assignee"], .ghx-avatar-img');
            const assignee = assigneeImg?.getAttribute('alt') || assigneeImg?.getAttribute('aria-label') || assigneeImg?.getAttribute('data-tooltip') || null;
            const summaryEl = card.querySelector('[data-testid*="summary"], .ghx-summary');
            const text = (summaryEl?.innerText || card.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 160);
            return { key, assignee, text };
        }).filter(c => c.key || c.text);
        return JSON.stringify({
            title: document.title,
            url: location.href,
            activeFilters,
            filterAssignees,
            cards,
            bodyTextSample: (document.body?.innerText || '').slice(0, 2000)
        });
        """
    }

    public static func extractBoardContextScript() -> String {
        """
        const counts = new Map();
        const addProject = (raw, weight) => {
            const clean = String(raw || '').trim().toUpperCase();
            if (!/^[A-Z][A-Z0-9_]{1,}$/.test(clean)) return;
            counts.set(clean, (counts.get(clean) || 0) + (weight || 1));
        };
        const metaProj = document.querySelector('meta[name="ajs-project-key"]')?.getAttribute('content');
        if (metaProj) addProject(metaProj, 10);
        try {
            const url = new URL(location.href);
            addProject(url.searchParams.get('projectKey') || url.searchParams.get('project'), 10);
            const pathMatch = url.pathname.match(/\\/projects\\/([A-Za-z][A-Za-z0-9_]+)/i);
            if (pathMatch) addProject(pathMatch[1], 10);
            const browseMatch = url.pathname.match(/\\/browse\\/([A-Za-z][A-Za-z0-9_]+)-\\d+/i);
            if (browseMatch) addProject(browseMatch[1], 8);
        } catch (_) {}
        try {
            if (window.GH && GH.RapidBoard && GH.RapidBoard.State && GH.RapidBoard.State.data) {
                addProject(GH.RapidBoard.State.data.projectKey, 10);
            }
            if (window.AJS && AJS.Meta && typeof AJS.Meta.get === 'function') {
                addProject(AJS.Meta.get('project-key'), 10);
            }
        } catch (_) {}
        document.querySelectorAll('[data-project-key]').forEach(el => addProject(el.getAttribute('data-project-key'), 5));
        const issueKeys = [];
        const seenIssues = new Set();
        const pushIssue = (raw) => {
            const m = String(raw || '').toUpperCase().match(/[A-Z][A-Z0-9_]+-\\d+/);
            if (!m) return;
            const key = m[0];
            if (!seenIssues.has(key)) {
                seenIssues.add(key);
                issueKeys.push(key);
                addProject(key.split('-')[0], 2);
            }
        };
        document.querySelectorAll('[data-issue-key], .ghx-issue, [data-testid*="card"], a[href*="/browse/"]').forEach(el => {
            pushIssue(el.getAttribute('data-issue-key'));
            pushIssue(el.getAttribute('href'));
            pushIssue((el.textContent || '').slice(0, 120));
        });
        const projectKeys = Array.from(counts.entries())
            .sort((a, b) => b[1] - a[1])
            .map(e => e[0]);
        const activeFilters = Array.from(document.querySelectorAll('[aria-pressed="true"], .ghx-active'))
            .map(el => (el.getAttribute('aria-label') || el.getAttribute('title') || el.textContent || '').trim())
            .filter(Boolean)
            .slice(0, 12);
        const columns = Array.from(document.querySelectorAll('#ghx-column-headers .ghx-column h2, [data-testid*="column-header"]'))
            .map(el => (el.innerText || el.textContent || '').trim())
            .filter(Boolean)
            .slice(0, 16);
        return JSON.stringify({
            url: location.href,
            title: document.title,
            projectKeys,
            issueKeys: issueKeys.slice(0, 40),
            activeFilters,
            columns
        });
        """
    }

    public static func scrollBoardScript(deltaY: Int, deltaX: Int = 0) -> String {
        """
        const dy = \(deltaY);
        const dx = \(deltaX);
        const prioritySelectors = [
            '#ghx-pool',
            '#ghx-work',
            '[data-testid*="software-board.board-container"]',
            '[data-testid*="board-container"]',
            '[data-testid*="software-board"]',
            'main [role="main"]',
            'main'
        ];
        const canScrollY = (el) => {
            if (!el) return false;
            const oy = getComputedStyle(el).overflowY;
            return (oy === 'auto' || oy === 'scroll' || oy === 'overlay') && el.scrollHeight > el.clientHeight + 20;
        };
        const canScrollX = (el) => {
            if (!el) return false;
            const ox = getComputedStyle(el).overflowX;
            return (ox === 'auto' || ox === 'scroll' || ox === 'overlay') && el.scrollWidth > el.clientWidth + 20;
        };
        let target = null;
        for (const sel of prioritySelectors) {
            for (const el of document.querySelectorAll(sel)) {
                if ((dy !== 0 && canScrollY(el)) || (dx !== 0 && canScrollX(el))) {
                    target = el;
                    break;
                }
            }
            if (target) break;
        }
        if (!target) {
            let bestArea = 0;
            for (const el of document.querySelectorAll('div, section, main')) {
                if ((dy !== 0 && canScrollY(el)) || (dx !== 0 && canScrollX(el))) {
                    const rect = el.getBoundingClientRect();
                    const area = rect.width * rect.height;
                    if (area > bestArea) {
                        bestArea = area;
                        target = el;
                    }
                }
            }
        }
        if (target) {
            const beforeY = target.scrollTop;
            const beforeX = target.scrollLeft;
            if (typeof target.scrollBy === 'function') {
                target.scrollBy({ top: dy, left: dx, behavior: 'auto' });
            } else {
                target.scrollTop += dy;
                target.scrollLeft += dx;
            }
            return JSON.stringify({
                scrolled: target.scrollTop !== beforeY || target.scrollLeft !== beforeX,
                container: target.id || target.getAttribute('data-testid') || target.tagName.toLowerCase(),
                scrollTop: Math.round(target.scrollTop),
                maxScrollTop: Math.max(0, Math.round(target.scrollHeight - target.clientHeight)),
                scrollLeft: Math.round(target.scrollLeft),
                maxScrollLeft: Math.max(0, Math.round(target.scrollWidth - target.clientWidth))
            });
        }
        const root = document.scrollingElement || document.documentElement;
        const beforeY = window.scrollY || (root ? root.scrollTop : 0);
        const beforeX = window.scrollX || (root ? root.scrollLeft : 0);
        window.scrollBy({ top: dy, left: dx, behavior: 'auto' });
        const afterY = window.scrollY || (root ? root.scrollTop : 0);
        const afterX = window.scrollX || (root ? root.scrollLeft : 0);
        return JSON.stringify({
            scrolled: afterY !== beforeY || afterX !== beforeX,
            container: 'window',
            scrollTop: Math.round(afterY),
            maxScrollTop: root ? Math.max(0, Math.round(root.scrollHeight - window.innerHeight)) : 0,
            scrollLeft: Math.round(afterX),
            maxScrollLeft: root ? Math.max(0, Math.round(root.scrollWidth - window.innerWidth)) : 0
        });
        """
    }

    public static func applyPresentationModeScript(enabled: Bool) -> String {
        if !enabled {
            return """
            const existing = document.getElementById('__rnr-board-presentation-style');
            if (existing) existing.remove();
            window.dispatchEvent(new Event('resize'));
            return JSON.stringify({ enabled: false });
            """
        }
        return """
        const styleId = '__rnr-board-presentation-style';
        let styleEl = document.getElementById(styleId);
        const css = `
            #header, #aui-header, .aui-header, [data-testid="atlassian-navigation"],
            [data-testid*="global-nav"], #ghx-navigation, .aui-sidebar,
            [data-testid*="navigation-appshell"] nav, [data-testid="contextual-navigation"],
            [data-testid*="project-sidebar"], #ghx-header .aui-nav,
            .ghx-feedback-banner, #announcement-banner {
                display: none !important;
                height: 0 !important;
                min-height: 0 !important;
            }
            #page, #content, .aui-page-panel, .aui-page-panel-inner,
            #ghx-content-main, #ghx-work, #ghx-pool-column {
                margin-left: 0 !important;
                padding-left: 0 !important;
                padding-top: 0 !important;
                top: 0 !important;
            }
            #ghx-header {
                padding: 4px 8px !important;
                margin-bottom: 4px !important;
            }
            #ghx-quick-filters, [data-testid*="filters"] {
                margin: 2px 0 !important;
                padding-top: 2px !important;
                padding-bottom: 2px !important;
            }
            #ghx-pool {
                height: auto !important;
                min-height: calc(100vh - 96px) !important;
                max-height: calc(100vh - 96px) !important;
                overflow-y: auto !important;
            }
        `;
        if (!styleEl) {
            styleEl = document.createElement('style');
            styleEl.id = styleId;
            (document.head || document.documentElement).appendChild(styleEl);
        }
        styleEl.textContent = css;
        window.dispatchEvent(new Event('resize'));
        return JSON.stringify({ enabled: true });
        """
    }

    public static func focusActiveCardsScript() -> String {
        """
        const cards = Array.from(document.querySelectorAll('[data-issue-key], .ghx-issue, [data-testid*="card"]'))
            .filter(el => {
                const r = el.getBoundingClientRect();
                return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
            });
        if (cards.length === 0) {
            return JSON.stringify({ focused: false });
        }
        const firstCard = cards[0];
        const pool = document.querySelector('#ghx-pool, #ghx-work, [data-testid*="software-board.board-container"], [data-testid*="board-container"]');
        if (pool && pool.scrollHeight > pool.clientHeight + 20) {
            const cardRect = firstCard.getBoundingClientRect();
            const poolRect = pool.getBoundingClientRect();
            if (cardRect.top > poolRect.bottom - 40 || cardRect.top < poolRect.top) {
                firstCard.scrollIntoView({ behavior: 'auto', block: 'start', inline: 'nearest' });
            }
        }
        return JSON.stringify({
            focused: true,
            visibleCards: cards.length,
            firstKey: firstCard.getAttribute('data-issue-key') || null
        });
        """
    }

    private static func encodeJSONLiteral<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }
}

/// Bounds asynchronous `@MainActor` WebView JavaScript calls with a single-resume timeout race
/// so stuck pages cannot freeze the facilitator or board sharing pipeline indefinitely.
@MainActor
public enum JiraBoardAsyncTimeout {
    @MainActor
    private final class TimeoutOnceState {
        var continuation: CheckedContinuation<String, Error>?
        var timeoutTask: Task<Void, Never>?
        var workTask: Task<Void, Never>?
        var isCancelled = false

        func install(_ cont: CheckedContinuation<String, Error>) {
            if isCancelled {
                cont.resume(throwing: CancellationError())
                return
            }
            continuation = cont
        }

        func finish(with result: Result<String, Error>) {
            timeoutTask?.cancel()
            timeoutTask = nil
            workTask?.cancel()
            workTask = nil
            guard let cont = continuation else { return }
            continuation = nil
            cont.resume(with: result)
        }

        func cancelExternally() {
            isCancelled = true
            workTask?.cancel()
            finish(with: .failure(CancellationError()))
        }
    }

    public static func run(
        seconds: TimeInterval = 6,
        timeoutError: (@Sendable () -> Error)? = nil,
        operation: @escaping @MainActor () async throws -> String
    ) async throws -> String {
        try Task.checkCancellation()
        let state = TimeoutOnceState()
        let nanoseconds = UInt64(max(0.05, seconds) * 1_000_000_000)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                guard state.continuation != nil else { return }
                state.timeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    let err = timeoutError?() ?? JiraConnectorError.serverError(408, "Assistant Board JavaScript evaluation timed out.")
                    state.finish(with: .failure(err))
                }
                state.workTask = Task { @MainActor in
                    do {
                        let value = try await operation()
                        state.finish(with: .success(value))
                    } catch {
                        state.finish(with: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                state.cancelExternally()
            }
        }
    }
}

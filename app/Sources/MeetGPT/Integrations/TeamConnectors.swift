import Foundation

/// Token/API-key connectors — the decentralized fallback for team tools that
/// host NO MCP server (Slack bot APIs) or where MCP is impractical. Confluence is normally reached through the Atlassian MCP
/// entry in Connected apps; the token client here exists for MCP-less setups.
/// Together with MCP research these simulate central aggregation: every
/// configured connector can search/fetch for grounding, and the TeamWatcher
/// scans designated channels for keyword rules.
enum TeamService: String, CaseIterable, Identifiable {
    case slack, confluence

    var id: String { rawValue }
    var label: String {
        switch self {
        case .slack:      return "Slack"
        case .confluence: return "Confluence"
        }
    }
    var symbol: String {
        switch self {
        case .slack:      return "number.square"
        case .confluence: return "book.closed"
        }
    }

    /// Configured = its tokens are present in mac/.env.
    var isConfigured: Bool {
        switch self {
        case .slack:      return !Config.slackBotToken.isEmpty
        case .confluence: return !Config.confluenceToken.isEmpty && !Config.confluenceSite.isEmpty
        }
    }

    var configHint: String {
        switch self {
        case .slack:      return "SLACK_BOT_TOKEN (+ SLACK_CHANNEL_IDS)"
        case .confluence: return "CONFLUENCE_SITE + CONFLUENCE_EMAIL + CONFLUENCE_TOKEN — or use Atlassian in Connected apps"
        }
    }
}

/// One message/item pulled from a team tool.
struct TeamItem {
    let service: TeamService
    let channel: String     // channel id / space / project context
    let author: String
    let text: String
    let timestamp: Date
}

enum TeamConnectors {
    static var configured: [TeamService] { TeamService.allCases.filter(\.isConfigured) }

    // MARK: - Reading (watcher + grounding)

    /// Recent messages of every DESIGNATED channel for the service.
    static func recentMessages(_ service: TeamService, limit: Int = 20) async -> [TeamItem] {
        switch service {
        case .slack:
            var items: [TeamItem] = []
            for channel in Config.slackChannelIDs {
                items += await slackHistory(channel: channel, limit: limit)
            }
            return items
        case .confluence:
            return []   // not channel-based; used via search()
        }
    }

    /// Goal/keyword search — feeds the co-pilot research fan-out.
    static func search(_ service: TeamService, query: String, cap: Int = 3000) async -> String? {
        switch service {
        case .slack:
            let words = query.lowercased().split(separator: " ").map(String.init)
            let hits = await recentMessages(service, limit: 50).filter { item in
                let text = item.text.lowercased()
                return words.contains { text.contains($0) }
            }
            guard !hits.isEmpty else { return nil }
            return hits.prefix(12).map { "[\($0.channel)] \($0.author): \($0.text)" }
                .joined(separator: "\n").prefix(cap).description
        case .confluence:
            return await confluenceSearch(query: query, cap: cap)
        }
    }

    // MARK: - Writing (alerts / automated responses)

    /// Post into a channel (Slack bot).
    static func post(_ service: TeamService, channel: String, text: String) async {
        switch service {
        case .slack:
            _ = try? await request(
                url: "https://slack.com/api/chat.postMessage",
                bearer: Config.slackBotToken,
                json: ["channel": channel, "text": text])
        case .confluence:
            break
        }
    }

    // MARK: - Slack (bot token)

    private static func slackHistory(channel: String, limit: Int) async -> [TeamItem] {
        guard let data = try? await request(
            url: "https://slack.com/api/conversations.history?channel=\(channel)&limit=\(limit)",
            bearer: Config.slackBotToken, json: nil),
              let root = json(data), root["ok"] as? Bool == true,
              let messages = root["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { message in
            guard let text = message["text"] as? String, !text.isEmpty else { return nil }
            let ts = Double(message["ts"] as? String ?? "") ?? 0
            return TeamItem(service: .slack, channel: channel,
                            author: (message["user"] as? String) ?? "bot",
                            text: text, timestamp: Date(timeIntervalSince1970: ts))
        }
    }

    // MARK: - Confluence (site + email + API token; MCP-less fallback)

    private static func confluenceSearch(query: String, cap: Int) async -> String? {
        let site = Config.confluenceSite.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let cql = "text ~ \"\(query.replacingOccurrences(of: "\"", with: ""))\""
        guard let encoded = cql.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let data = try? await request(
                url: "\(site)/wiki/rest/api/content/search?cql=\(encoded)&limit=5&expand=body.storage",
                basicUser: Config.confluenceEmail, basicPass: Config.confluenceToken),
              let root = json(data),
              let results = root["results"] as? [[String: Any]], !results.isEmpty else { return nil }
        let pages = results.compactMap { page -> String? in
            guard let title = page["title"] as? String else { return nil }
            let body = (((page["body"] as? [String: Any])?["storage"] as? [String: Any])?["value"] as? String) ?? ""
            let text = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            return "## \(title)\n\(text.prefix(800))"
        }
        return pages.joined(separator: "\n\n").prefix(cap).description
    }

    // MARK: - Transport

    private static func request(url: String, bearer: String? = nil,
                                basicUser: String? = nil, basicPass: String? = nil,
                                json body: [String: Any]? = nil) async throws -> Data {
        guard let requestURL = URL(string: url), requestURL.scheme == "https" else {
            throw LLMError.badResponse("Team connector")
        }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 20
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let basicUser, let basicPass {
            let basic = Data("\(basicUser):\(basicPass)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.badResponse("Team connector")
        }
        return data
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

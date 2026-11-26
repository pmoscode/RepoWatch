import Foundation
import GitHubAPI

/// Ereignis aus `GET /repos/{owner}/{repo}/events` (Konzept 7, Detailansicht).
/// Achtung: Die Events-API hinkt 30 s bis einige Stunden hinterher; nur Ergänzung.
public struct ActivityEvent: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case push
        case pullRequestOpened, pullRequestMerged, pullRequestClosed
        case issueOpened, issueClosed, issueReopened
        case comment, review
        case release
        case branchOrTagCreated, branchOrTagDeleted
        case star, fork
        case other
    }

    public let id: String
    public let kind: Kind
    public let actor: String
    public let createdAt: Date
    /// Kurzbeschreibung, z. B. „#42 Fix login“ oder „main“.
    public let detail: String?
    public let url: URL?
}

extension ActivityModule {
    /// Commits pro Woche der letzten 52 Wochen (Sparkline, Konzept 7).
    /// Kann `GitHubAPIError.pending` werfen, solange GitHub die Statistik noch berechnet (HTTP 202).
    public static func fetchWeeklyCommits(rest: RESTClient, nameWithOwner: String) async throws -> [Int] {
        struct Participation: Decodable, Sendable { let all: [Int] }
        return try await rest.get("/repos/\(nameWithOwner)/stats/participation", as: Participation.self).value.all
    }

    /// Letzte Ereignisse eines Repos. Mit ETag: unveränderte Abfragen sind kostenlos.
    public static func fetchEvents(rest: RESTClient, nameWithOwner: String, limit: Int = 30) async throws -> [ActivityEvent] {
        let raw = try await rest.get(
            "/repos/\(nameWithOwner)/events",
            query: [URLQueryItem(name: "per_page", value: String(limit))],
            as: [RawEvent].self
        )
        return raw.value.map(\.event)
    }

    /// Rohform der Events-API; alle Inhalte optional, weil GitHub die Payloads gekürzt hat.
    struct RawEvent: Decodable, Sendable {
        struct Actor: Decodable, Sendable { let login: String }
        struct Payload: Decodable, Sendable {
            struct Item: Decodable, Sendable {
                let number: Int?
                let title: String?
                let htmlUrl: URL?
                let merged: Bool?
            }
            struct Release: Decodable, Sendable {
                let name: String?
                let tagName: String?
                let htmlUrl: URL?
            }
            let action: String?
            let ref: String?
            let refType: String?
            let pullRequest: Item?
            let issue: Item?
            let release: Release?
        }
        let id: String
        let type: String
        let actor: Actor
        let createdAt: Date
        let payload: Payload?

        var event: ActivityEvent {
            let payload = payload
            let action = payload?.action
            let kind: ActivityEvent.Kind
            var detail: String?
            var url: URL?

            func describe(_ item: Payload.Item?) {
                if let item {
                    detail = [item.number.map { "#\($0)" }, item.title].compactMap { $0 }.joined(separator: " ")
                    url = item.htmlUrl
                }
            }

            switch type {
            case "PushEvent":
                kind = .push
                detail = payload?.ref?.replacingOccurrences(of: "refs/heads/", with: "")
            case "PullRequestEvent":
                switch action {
                case "opened", "reopened": kind = .pullRequestOpened
                case "closed": kind = payload?.pullRequest?.merged == true ? .pullRequestMerged : .pullRequestClosed
                default: kind = .other
                }
                describe(payload?.pullRequest)
            case "IssuesEvent":
                switch action {
                case "opened": kind = .issueOpened
                case "closed": kind = .issueClosed
                case "reopened": kind = .issueReopened
                default: kind = .other
                }
                describe(payload?.issue)
            case "IssueCommentEvent", "PullRequestReviewCommentEvent", "CommitCommentEvent":
                kind = .comment
                describe(payload?.issue ?? payload?.pullRequest)
            case "PullRequestReviewEvent":
                kind = .review
                describe(payload?.pullRequest)
            case "ReleaseEvent":
                kind = .release
                detail = payload?.release?.name ?? payload?.release?.tagName
                url = payload?.release?.htmlUrl
            case "CreateEvent":
                kind = .branchOrTagCreated
                detail = payload?.ref
            case "DeleteEvent":
                kind = .branchOrTagDeleted
                detail = payload?.ref
            case "WatchEvent":
                kind = .star
            case "ForkEvent":
                kind = .fork
            default:
                kind = .other
                detail = type
            }
            return ActivityEvent(id: id, kind: kind, actor: actor.login, createdAt: createdAt, detail: detail, url: url)
        }
    }
}

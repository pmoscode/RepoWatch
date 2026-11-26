import Domain
import Foundation

/// Ergebnis eines Workflow-Runs (Konzept 8.2).
public enum RunOutcome: String, Codable, Sendable, Hashable {
    case success
    /// failure, timed_out, startup_failure
    case failure
    case cancelled
    /// queued, in_progress, waiting, pending, requested
    case running
    /// skipped, neutral, stale
    case skipped
    /// action_required (z. B. Freigabe für Runs aus Fork-PRs)
    case actionRequired

    /// Aus `status` und `conclusion`, egal ob REST (klein) oder GraphQL (groß).
    public init(status: String?, conclusion: String?) {
        let status = status?.lowercased()
        guard status == nil || status == "completed" else {
            self = .running
            return
        }
        switch conclusion?.lowercased() {
        case "success": self = .success
        case "failure", "timed_out", "startup_failure": self = .failure
        case "cancelled": self = .cancelled
        case "action_required": self = .actionRequired
        case "skipped", "neutral", "stale": self = .skipped
        case nil: self = .running
        default: self = .skipped
        }
    }

    /// Zählt für Serien und Erfolgsquote (abgebrochene/übersprungene Runs zählen nicht).
    var isDecisive: Bool { self == .success || self == .failure }
}

public struct WorkflowRunSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let workflowName: String
    public let runNumber: Int
    /// Versuch; GitHub liefert pro Run den neuesten Versuch.
    public let attempt: Int
    public let outcome: RunOutcome
    public let branch: String?
    public let event: String
    public let actor: String?
    public let startedAt: Date
    public let updatedAt: Date
    public let url: URL
    public let pullRequestNumbers: [Int]

    public var duration: TimeInterval { max(0, updatedAt.timeIntervalSince(startedAt)) }

    public init(id: Int64, workflowName: String, runNumber: Int, attempt: Int, outcome: RunOutcome, branch: String?,
                event: String, actor: String?, startedAt: Date, updatedAt: Date, url: URL, pullRequestNumbers: [Int]) {
        self.id = id
        self.workflowName = workflowName
        self.runNumber = runNumber
        self.attempt = attempt
        self.outcome = outcome
        self.branch = branch
        self.event = event
        self.actor = actor
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.url = url
        self.pullRequestNumbers = pullRequestNumbers
    }
}

/// Zustand eines Workflows auf einem Branch (Konzept 8.2, „Abgeleitete Werte“).
public struct WorkflowState: Sendable, Hashable, Identifiable {
    public var id: String { "\(workflowName)@\(branch ?? "")" }
    public let workflowName: String
    public let branch: String?
    /// Neuester Run (auch laufend).
    public let latest: WorkflowRunSummary
    /// Ergebnis des neuesten abgeschlossenen, entscheidenden Runs (Erfolg oder Fehlschlag).
    public let current: RunOutcome?
    /// Seit wann rot: Start des ersten Fehlschlags nach dem letzten Erfolg.
    public let failingSince: Date?
    public let consecutiveFailures: Int
    /// Anteil erfolgreicher unter den entscheidenden Runs; `nil` ohne solche.
    public let successRate: Double?
    public let isRunning: Bool

    public var isFailing: Bool { current == .failure }
}

public enum WorkflowAnalysis {
    /// Gruppiert Runs nach Workflow und Branch und leitet den Zustand ab.
    public static func states(of runs: [WorkflowRunSummary]) -> [WorkflowState] {
        let groups = Dictionary(grouping: runs) { "\($0.workflowName)\u{0}\($0.branch ?? "")" }
        return groups.values.compactMap { group -> WorkflowState? in
            let sorted = group.sorted { ($0.startedAt, $0.runNumber) > ($1.startedAt, $1.runNumber) }
            guard let latest = sorted.first else { return nil }
            let decisive = sorted.filter { $0.outcome.isDecisive }
            let streak = decisive.prefix { $0.outcome == .failure }
            let successes = decisive.filter { $0.outcome == .success }.count
            return WorkflowState(
                workflowName: latest.workflowName,
                branch: latest.branch,
                latest: latest,
                current: decisive.first?.outcome,
                failingSince: streak.last?.startedAt,
                consecutiveFailures: streak.count,
                successRate: decisive.isEmpty ? nil : Double(successes) / Double(decisive.count),
                isRunning: sorted.contains { $0.outcome == .running }
            )
        }
        .sorted { ($0.isFailing ? 0 : 1, $0.workflowName, $0.branch ?? "") < ($1.isFailing ? 0 : 1, $1.workflowName, $1.branch ?? "") }
    }
}

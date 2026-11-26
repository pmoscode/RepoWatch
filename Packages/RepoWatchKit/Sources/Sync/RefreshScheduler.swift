import Domain
import Foundation
import GitHubAPI
import os

/// Meldungen des Schedulers an die Oberfläche.
public enum SyncEvent: Sendable {
    case started(SyncPlan)
    case finished(SyncOutcome)
    case failed(GitHubAPIError, retryAt: Date)
}

/// Führt Sync-Durchläufe im Takt aus (Konzept 4.2).
///
/// Die Entscheidung „was ist fällig“ trifft der `RefreshPlanner`; hier geht es nur um das Wann:
/// schlafen bis zur nächsten Fälligkeit, bei Auslösern sofort aufwachen, nach Fehlern länger warten.
public actor RefreshScheduler {
    private let engine: SyncEngine
    private var planner: RefreshPlanner
    private let now: @Sendable () -> Date
    private let sleep: Sleeper
    private let continuation: AsyncStream<SyncEvent>.Continuation
    public nonisolated let events: AsyncStream<SyncEvent>

    private var loopTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Error>?
    private var pendingTriggers: [RefreshTrigger] = []
    /// Auslöser, der während eines Backoffs/Rate-Limits kam; wird danach ausgeführt statt verworfen.
    private var deferredTrigger: RefreshTrigger?
    private var consecutiveFailures = 0
    private var notBefore: Date?
    private var rateLimitedUntil: Date?
    private let logger = Logger(subsystem: "de.pmoscode.repowatch", category: "RefreshScheduler")

    /// Längste Pause zwischen zwei Prüfungen; fängt auch Uhrsprünge (Ruhezustand) ab.
    static let maximumIdle: TimeInterval = 60
    static let maximumBackoff: TimeInterval = 15 * 60

    public init(
        engine: SyncEngine,
        planner: RefreshPlanner = RefreshPlanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.engine = engine
        self.planner = planner
        self.now = now
        self.sleep = sleep
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    deinit {
        continuation.finish()
    }

    // MARK: Steuerung

    public func start(with trigger: RefreshTrigger = .launch) {
        pendingTriggers.append(trigger)
        guard loopTask == nil else {
            sleepTask?.cancel()
            return
        }
        loopTask = Task { await self.run() }
    }

    public func stop() {
        loopTask?.cancel()
        sleepTask?.cancel()
        loopTask = nil
        pendingTriggers.removeAll()
        deferredTrigger = nil
    }

    /// Weckt den Scheduler auf, z. B. beim Öffnen des Panels oder nach dem Ruhezustand.
    public func trigger(_ trigger: RefreshTrigger) {
        logger.info("Auslöser: \(String(describing: trigger), privacy: .public)")
        pendingTriggers.append(trigger)
        if trigger == .manual {
            // Manuell heißt: jetzt. Backoff nach Fehlern zählt nicht, ein Rate-Limit schon.
            notBefore = nil
        }
        sleepTask?.cancel()
    }

    public func setFavorites(_ favorites: Set<String>) {
        planner.favorites = favorites
    }

    // MARK: Schleife

    private func run() async {
        while !Task.isCancelled {
            // Auslöser übernehmen, BEVOR irgendwo gewartet wird: Was während eines `await` eintrifft,
            // bleibt in `pendingTriggers` und weckt die nächste Runde (Actor-Reentrancy).
            let consumed = pendingTriggers + (deferredTrigger.map { [$0] } ?? [])
            pendingTriggers.removeAll()
            deferredTrigger = nil
            let trigger = Self.strongest(of: consumed) ?? .timer

            let current = now()
            if let blockedUntil = [notBefore, rateLimitedUntil].compactMap({ $0 }).filter({ $0 > current }).max() {
                if trigger != .timer {
                    deferredTrigger = trigger
                    logger.info("Auslöser \(String(describing: trigger), privacy: .public) wartet bis \(blockedUntil.formatted(date: .omitted, time: .standard), privacy: .public) (Backoff/Rate-Limit)")
                }
                await idle(for: .seconds(min(max(blockedUntil.timeIntervalSince(current), 1), Self.maximumIdle)))
                continue
            }

            let state = await engine.currentState
            let plan = planner.plan(for: state, trigger: trigger, now: current)
            if !plan.isEmpty {
                if trigger != .timer {
                    logger.info("Plan für \(String(describing: trigger), privacy: .public): Bestand=\(plan.inventory), \(plan.allRepositories ? "alle" : String(plan.repositoryIDs.count), privacy: .public) Repos")
                }
                await execute(plan)
                continue
            }
            if trigger != .timer {
                logger.info("Auslöser \(String(describing: trigger), privacy: .public): nichts fällig")
            }
            let wakeAt = planner.nextDueDate(for: state, now: current)
            await idle(for: .seconds(min(max(wakeAt.timeIntervalSince(current), 1), Self.maximumIdle)))
        }
    }

    private func execute(_ plan: SyncPlan) async {
        continuation.yield(.started(plan))
        do {
            let outcome = try await engine.sync(plan)
            consecutiveFailures = 0
            notBefore = nil
            rateLimitedUntil = nil
            continuation.yield(.finished(outcome))
        } catch is CancellationError {
            return
        } catch {
            let apiError = (error as? GitHubAPIError) ?? .transport(error.localizedDescription)
            consecutiveFailures += 1
            let retryAt: Date
            if case .rateLimited(let resetAt) = apiError {
                retryAt = resetAt ?? now().addingTimeInterval(Self.maximumBackoff)
                rateLimitedUntil = retryAt
            } else {
                // 30 s, 1 min, 2 min … höchstens 15 min.
                let delay = min(30 * pow(2, Double(consecutiveFailures - 1)), Self.maximumBackoff)
                retryAt = now().addingTimeInterval(delay)
                notBefore = retryAt
            }
            logger.error("Sync fehlgeschlagen (\(self.consecutiveFailures). Mal): \(apiError.localizedDescription, privacy: .public); nächster Versuch \(retryAt.formatted(date: .omitted, time: .standard), privacy: .public)")
            continuation.yield(.failed(apiError, retryAt: retryAt))
        }
    }

    private func idle(for duration: Duration) async {
        guard pendingTriggers.isEmpty else { return }
        let task = Task { [sleep] in try await sleep(duration) }
        sleepTask = task
        _ = try? await task.value
        sleepTask = nil
    }

    /// Mehrere Auslöser werden zum umfassendsten zusammengefasst.
    static func strongest(of triggers: [RefreshTrigger]) -> RefreshTrigger? {
        let order: [RefreshTrigger] = [.launch, .manual, .wake, .panelOpened, .timer]
        return order.first(where: triggers.contains)
    }
}

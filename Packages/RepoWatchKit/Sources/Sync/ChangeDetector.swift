import Domain
import Foundation
import ModuleKit

/// Vergleicht zwei Stände und liefert die Änderungen (Konzept 9.3).
public enum ChangeDetector {
    /// Nebenbei wird die offene Frage aus Phase 0 beobachtet: Zeigen `pushedAt`/`updatedAt`
    /// zuverlässig an, dass sich in einem Repo etwas getan hat?
    public struct SignalObservation: Sendable, Equatable {
        /// Repos mit Modul-Änderungen, bei denen sich auch `pushedAt` oder `updatedAt` geändert hat.
        public var signalled = 0
        /// Repos mit Modul-Änderungen, bei denen beide gleich geblieben sind.
        public var missed = 0
    }

    public static func detect(
        old: SyncState,
        new: SyncState,
        refreshedIDs: Set<String>,
        inventoryRefreshed: Bool,
        modules: [AnyInsightModule],
        now: Date
    ) -> (ChangeSet, SignalObservation) {
        var changes: [Change] = []
        var observation = SignalObservation()
        let oldByID = Dictionary(uniqueKeysWithValues: old.repositories.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.repositories.map { ($0.id, $0) })

        // Ohne vorherigen Stand ist alles „neu“; das wäre beim ersten Start nur Rauschen.
        let isFirstSync = old.inventoryFetchedAt == nil

        if inventoryRefreshed && !isFirstSync {
            for repository in new.repositories where oldByID[repository.id] == nil {
                changes.append(Change(kind: .repositoryAdded, repositoryID: repository.id,
                                      repositoryName: repository.meta.nameWithOwner, url: repository.meta.url))
            }
            for repository in old.repositories where newByID[repository.id] == nil {
                changes.append(Change(kind: .repositoryRemoved, repositoryID: repository.id,
                                      repositoryName: repository.meta.nameWithOwner, url: repository.meta.url))
            }
        }

        for repository in new.repositories {
            guard let previous = oldByID[repository.id] else { continue }

            if let pushed = repository.meta.pushedAt, pushed != previous.meta.pushedAt, !isFirstSync {
                changes.append(Change(kind: .pushed, repositoryID: repository.id,
                                      repositoryName: repository.meta.nameWithOwner, url: repository.meta.url))
            }

            guard refreshedIDs.contains(repository.id) else { continue }
            var moduleChanges: [Change] = []
            for module in modules {
                guard let newPayload = repository.payloads[module.id] else { continue }
                let oldPayload = previous.payloads[module.id]
                if let oldPayload, oldPayload == newPayload { continue }
                moduleChanges += module.changes(from: oldPayload?.value, to: newPayload.value, repository: repository.meta)
            }
            changes += moduleChanges

            if inventoryRefreshed, !moduleChanges.isEmpty, previous.detailsFetchedAt != nil {
                let metaMoved = repository.meta.pushedAt != previous.meta.pushedAt
                    || repository.meta.updatedAt != previous.meta.updatedAt
                if metaMoved { observation.signalled += 1 } else { observation.missed += 1 }
            }
        }

        return (ChangeSet(detectedAt: now, changes: changes), observation)
    }
}

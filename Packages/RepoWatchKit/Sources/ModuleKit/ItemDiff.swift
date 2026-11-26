import Domain
import Foundation

/// Erkennt neue, geänderte und geschlossene Einträge (Issues, PRs) zwischen zwei Ständen.
///
/// Die Module sehen jeweils nur die zuletzt geänderten N Einträge. Daher:
/// - **neu**: Nummer kommt vorher nicht vor und ist größer als jede bisherige (Nummern steigen).
/// - **geschlossen**: fehlt jetzt, obwohl es noch ins Fenster passen würde (Liste nicht voll, oder
///   sein `updatedAt` ist nicht älter als der älteste neue Eintrag). Sonst wurde es nur verdrängt.
public enum ItemDiff {
    public struct Item: Sendable, Hashable {
        public let number: Int
        public let title: String
        public let url: URL
        public let updatedAt: Date

        public init(number: Int, title: String, url: URL, updatedAt: Date) {
            self.number = number
            self.title = title
            self.url = url
            self.updatedAt = updatedAt
        }
    }

    public static func changes(
        old: [Item],
        new: [Item],
        newHasMore: Bool,
        module: ModuleID,
        repository: RepoMeta
    ) -> [Change] {
        let oldByNumber = Dictionary(old.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        let newNumbers = Set(new.map(\.number))
        let highestOld = old.map(\.number).max() ?? 0
        let oldestNew = new.map(\.updatedAt).min()

        func change(_ kind: Change.Kind, _ item: Item) -> Change {
            Change(kind: kind, repositoryID: repository.id, repositoryName: repository.nameWithOwner,
                   moduleID: module, itemID: String(item.number), title: item.title, url: item.url)
        }

        var changes: [Change] = []
        for item in new {
            if let previous = oldByNumber[item.number] {
                if previous.updatedAt != item.updatedAt { changes.append(change(.itemUpdated, item)) }
            } else if item.number > highestOld {
                changes.append(change(.itemOpened, item))
            }
        }
        for item in old where !newNumbers.contains(item.number) {
            let stillInWindow = !newHasMore || oldestNew.map { item.updatedAt >= $0 } ?? true
            if stillInWindow { changes.append(change(.itemClosed, item)) }
        }
        return changes
    }
}

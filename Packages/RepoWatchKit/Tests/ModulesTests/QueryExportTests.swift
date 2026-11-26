import ActionsModule
import ActivityModule
import Foundation
import IssuesModule
import ModuleKit
import PullRequestsModule
import Testing

/// Schreibt die echte Detail-Abfrage der vier Module in eine Datei, um sie gegen GitHub zu prüfen:
/// `REPOWATCH_EXPORT_QUERY=/pfad/query.graphql swift test --filter QueryExport`
@Suite("Abfrage exportieren", .enabled(if: ProcessInfo.processInfo.environment["REPOWATCH_EXPORT_QUERY"] != nil))
struct QueryExportTests {
    @Test func export() throws {
        let path = try #require(ProcessInfo.processInfo.environment["REPOWATCH_EXPORT_QUERY"])
        let registry = try ModuleRegistry([
            AnyInsightModule(IssuesModule()), AnyInsightModule(PullRequestsModule()),
            AnyInsightModule(ActivityModule()), AnyInsightModule(ActionsModule()),
        ])
        try QueryBuilder.detailQuery(for: registry.enabledModules).write(toFile: path, atomically: true, encoding: .utf8)
    }
}

import ActionsModule
import ActivityModule
import Domain
import IssuesModule
import ModuleKit
import PullRequestsModule

extension ModuleRegistry {
    /// Die vier Module von v1 (Konzept 1). Neue Funktionen kommen hier als weiteres Modul dazu.
    public static func standard(authorRules: AuthorRules = .default) throws -> ModuleRegistry {
        try ModuleRegistry([
            AnyInsightModule(IssuesModule()),
            AnyInsightModule(PullRequestsModule(rules: authorRules)),
            AnyInsightModule(ActivityModule()),
            AnyInsightModule(ActionsModule(rules: authorRules)),
        ])
    }
}

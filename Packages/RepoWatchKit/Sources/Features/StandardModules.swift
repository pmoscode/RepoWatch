import ActionsModule
import ActivityModule
import Domain
import IssuesModule
import ModuleKit
import ModuleUIKit
import PullRequestsModule

/// Die vier Module von v1 (Konzept 1). Neue Funktionen kommen hier als weiteres Modul dazu:
/// einmal für die Daten (`InsightModule`), einmal für die Darstellung (`ModuleUI`).
public struct StandardModules: Sendable {
    public let authorRules: SharedValue<AuthorRules>
    let actions: ActionsModule

    public init(authorRules: SharedValue<AuthorRules>) {
        self.authorRules = authorRules
        actions = ActionsModule(rules: authorRules)
    }

    public func registry() throws -> ModuleRegistry {
        try ModuleRegistry([
            AnyInsightModule(IssuesModule()),
            AnyInsightModule(PullRequestsModule(rules: authorRules)),
            AnyInsightModule(ActivityModule()),
            AnyInsightModule(actions),
        ])
    }

    @MainActor
    public func userInterfaces() -> [any ModuleUI] {
        [IssuesUI(), PullRequestsUI(), ActivityUI(), ActionsUI(module: actions)]
    }
}

extension ModuleRegistry {
    public static func standard(authorRules: SharedValue<AuthorRules> = SharedValue(.default)) throws -> ModuleRegistry {
        try StandardModules(authorRules: authorRules).registry()
    }
}

// swift-tools-version: 6.2
import PackageDescription

// Jedes Target entspricht einer Schicht aus docs/01-konzept.md (Abschnitt 9.1).
// Abhängigkeiten zeigen nur nach unten; der Compiler erzwingt das.
let package = Package(
    name: "RepoWatchKit",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: [
        // Ein Produkt für die App; sie sieht nur Features + was sie zum Verdrahten braucht.
        .library(name: "RepoWatchKit", targets: ["Features"]),
    ],
    targets: [
        // Unterste Schicht: reine Modelle, keine Frameworks außer Foundation.
        .target(name: "Domain"),

        .target(name: "GitHubAPI", dependencies: ["Domain"]),
        .target(name: "Auth", dependencies: ["Domain", "GitHubAPI"]),
        .target(name: "Persistence", dependencies: ["Domain"]),

        .target(name: "ModuleKit", dependencies: ["Domain", "GitHubAPI"]),
        .target(name: "Sync", dependencies: ["Domain", "GitHubAPI", "Auth", "Persistence", "ModuleKit"]),

        .target(name: "DesignSystem", dependencies: ["Domain"]),
        // Darstellung der Module (Konzept 9.2, Punkt 4): eigenes Target, damit ModuleKit SwiftUI-frei bleibt.
        .target(name: "ModuleUIKit", dependencies: ["Domain", "GitHubAPI", "ModuleKit", "Persistence", "DesignSystem"]),

        // Module (Konzept, Abschnitt 9.2)
        .target(name: "IssuesModule", dependencies: ["Domain", "ModuleKit", "GitHubAPI", "DesignSystem", "ModuleUIKit"]),
        .target(name: "PullRequestsModule", dependencies: ["Domain", "ModuleKit", "GitHubAPI", "DesignSystem", "ModuleUIKit"]),
        .target(name: "ActivityModule", dependencies: ["Domain", "ModuleKit", "GitHubAPI", "DesignSystem", "ModuleUIKit"]),
        .target(name: "ActionsModule", dependencies: ["Domain", "ModuleKit", "GitHubAPI", "DesignSystem", "ModuleUIKit"]),

        .target(
            name: "Features",
            dependencies: [
                "Domain", "GitHubAPI", "Auth", "Sync", "ModuleKit", "ModuleUIKit", "Persistence", "DesignSystem",
                "IssuesModule", "PullRequestsModule", "ActivityModule", "ActionsModule",
            ]
        ),

        // Gemeinsame Test-Hilfen (URLProtocol-Mock, Sleep-Aufzeichnung); nur für Test-Targets.
        .target(name: "TestSupport", dependencies: ["Domain", "ModuleKit"], path: "Tests/TestSupport"),

        .testTarget(
            name: "GitHubAPITests",
            dependencies: ["GitHubAPI", "Domain", "TestSupport"]
        ),
        .testTarget(
            name: "AuthTests",
            dependencies: ["Auth", "GitHubAPI", "TestSupport"]
        ),
        .testTarget(
            name: "ModuleKitTests",
            dependencies: ["ModuleKit", "Domain", "TestSupport"]
        ),
        .testTarget(
            name: "ModulesTests",
            dependencies: [
                "IssuesModule", "PullRequestsModule", "ActivityModule", "ActionsModule",
                "ModuleKit", "Domain", "GitHubAPI", "TestSupport",
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", "Domain", "TestSupport"]
        ),
        .testTarget(
            name: "SyncTests",
            dependencies: ["Sync", "GitHubAPI", "Domain", "ModuleKit", "Persistence", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

import Domain
import ModuleUIKit
import SwiftUI

/// Einstellungsfenster (Konzept 3.3). Schalter wirken sofort; Listen werden mit „Übernehmen“ gespeichert,
/// damit nicht jeder Tastendruck einen Sync auslöst.
public struct SettingsView: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            AccountSettings(model: model)
                .tabItem { Label("Konto", systemImage: "person.crop.circle") }
            RepositorySettings(model: model)
                .tabItem { Label("Repositories", systemImage: "books.vertical") }
            PullRequestSettings(model: model)
                .tabItem { Label("Pull Requests", systemImage: "arrow.triangle.pull") }
            ActionsSettings(model: model)
                .tabItem { Label("Actions", systemImage: "gearshape.2") }
            RefreshSettings(model: model)
                .tabItem { Label("Aktualisierung", systemImage: "arrow.clockwise") }
            ModuleSettings(model: model)
                .tabItem { Label("Module", systemImage: "square.stack.3d.up") }
            GeneralSettings(model: model)
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 440)
    }
}

/// Bindung an eine Einstellung, die sofort gespeichert wird.
@MainActor
private func setting<Value>(_ model: AppModel, _ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
    Binding(
        get: { model.settings[keyPath: keyPath] },
        set: { value in model.updateSettings { $0[keyPath: keyPath] = value } }
    )
}

/// Mehrzeiliges Feld „ein Eintrag pro Zeile“ mit „Übernehmen“.
private struct LinesField: View {
    let title: LocalizedStringKey
    let prompt: String
    let lines: [String]
    let apply: ([String]) -> Void

    @State private var text = ""

    private var parsed: [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextField(title, text: $text, prompt: Text(prompt), axis: .vertical)
                .labelsHidden()
                .lineLimit(3...6)
                .font(.body.monospaced())
            HStack {
                Spacer()
                Button("Übernehmen") { apply(parsed) }
                    .disabled(parsed == lines)
            }
        }
        .onAppear { text = lines.joined(separator: "\n") }
        .onChange(of: lines) { _, newValue in text = newValue.joined(separator: "\n") }
    }
}

// MARK: - Reiter

private struct AccountSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            switch model.auth {
            case .signedIn(let login, let kind):
                LabeledContent("Angemeldet als", value: login)
                LabeledContent("Zugang", value: kind.displayName)
                if let rateLimit = model.syncState?.rateLimit {
                    LabeledContent("GraphQL-Kontingent") {
                        Text("\(rateLimit.remaining.formatted()) von \(rateLimit.limit.formatted()), neu ab \(rateLimit.resetAt.formatted(date: .omitted, time: .shortened))")
                    }
                }
                Button("Abmelden", role: .destructive) { model.signOut() }
                Text("Abmelden löscht das Token aus dem Schlüsselbund und den lokalen Cache.")
                    .font(.caption).foregroundStyle(.secondary)
            default:
                Text("Nicht angemeldet. Die Anmeldung erfolgt im Menüleisten-Panel.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RepositorySettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Anzeigen") {
                Toggle("Archivierte Repositories", isOn: setting(model, \.includeArchived))
                Toggle("Forks", isOn: setting(model, \.includeForks))
            }
            Section("Ausschließen") {
                LinesField(title: "Owner (Nutzer oder Organisation)", prompt: "alte-organisation",
                           lines: model.settings.excludedOwners) { lines in
                    model.updateSettings { $0.excludedOwners = lines }
                }
                LinesField(title: "Muster auf owner/name (Glob, * und ?)", prompt: "pmoscode/test-*",
                           lines: model.settings.excludedPatterns) { lines in
                    model.updateSettings { $0.excludedPatterns = lines }
                }
            }
            Section("Favoriten") {
                if model.settings.favorites.isEmpty {
                    Text("Favoriten legst du im Panel per Rechtsklick oder Stern in der Detailansicht an.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.settings.favorites, id: \.self) { favorite in
                    HStack {
                        Text(favorite)
                        Spacer()
                        Button {
                            model.toggleFavorite(favorite)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Entfernen")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PullRequestSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Text("Wer einen PR erstellt hat, entscheidet eine Regelkette: bekannte Logins, dann Branch-Präfix, dann Bot-Kennung, dann du, sonst Mensch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Renovate") {
                LinesField(title: "Logins", prompt: "renovate",
                           lines: model.settings.authorRules.renovateLogins.sorted()) { lines in
                    model.updateSettings { $0.authorRules.renovateLogins = Set(lines) }
                }
                LinesField(title: "Branch-Präfixe", prompt: "renovate/",
                           lines: model.settings.authorRules.renovateBranchPrefixes) { lines in
                    model.updateSettings { $0.authorRules.renovateBranchPrefixes = lines }
                }
            }
            Section("Dependabot") {
                LinesField(title: "Logins", prompt: "dependabot",
                           lines: model.settings.authorRules.dependabotLogins.sorted()) { lines in
                    model.updateSettings { $0.authorRules.dependabotLogins = Set(lines) }
                }
                LinesField(title: "Branch-Präfixe", prompt: "dependabot/",
                           lines: model.settings.authorRules.dependabotBranchPrefixes) { lines in
                    model.updateSettings { $0.authorRules.dependabotBranchPrefixes = lines }
                }
            }
            Section {
                Button("Standard wiederherstellen") {
                    model.updateSettings { $0.authorRules = .default }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ActionsSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Menüleiste") {
                Toggle("Roter Punkt bei Alarm", isOn: setting(model, \.alarmDotEnabled))
                Text("Alarm heißt: Standard-Branch rot oder roter Workflow in einem PR von dir oder einem anderen Menschen. Bot-PRs lösen keinen Alarm aus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Actions-Reiter") {
                Toggle("Fehlschläge auf allen Branches zeigen", isOn: setting(model, \.actionsShowAllBranches))
                Toggle("Runs aus Bot-PRs ausblenden", isOn: setting(model, \.actionsHideBotRuns))
                LinesField(title: "Auslöser ausblenden", prompt: "schedule",
                           lines: model.settings.actionsHiddenEvents) { lines in
                    model.updateSettings { $0.actionsHiddenEvents = lines }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RefreshSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Stepper(value: setting(model, \.activeIntervalMinutes), in: 1...60) {
                    LabeledContent("Aktive Repos alle", value: "\(model.settings.activeIntervalMinutes) Min.")
                }
                Stepper(value: setting(model, \.dormantIntervalMinutes), in: 5...240, step: 5) {
                    LabeledContent("Ruhende Repos alle", value: "\(model.settings.dormantIntervalMinutes) Min.")
                }
            } footer: {
                Text("Aktiv: Favoriten und Repos mit Push oder Änderung in den letzten 7 Tagen. Repos mit laufendem Workflow werden jede Minute aktualisiert, der Bestand alle 30 Minuten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModuleSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(model.moduleUIs.indices, id: \.self) { index in
                    let module = model.moduleUIs[index]
                    Toggle(isOn: Binding(
                        get: { model.settings.isEnabled(module.moduleID) },
                        set: { enabled in
                            model.updateSettings { settings in
                                settings.disabledModules.removeAll { $0 == module.moduleID.rawValue }
                                if !enabled { settings.disabledModules.append(module.moduleID.rawValue) }
                            }
                        }
                    )) {
                        Label(module.title, systemImage: module.systemImage)
                    }
                }
            } footer: {
                Text("Abgeschaltete Module werden nicht mehr bei GitHub abgefragt und verschwinden aus dem Panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Picker("Menüleiste zeigt", selection: setting(model, \.menuBarMode)) {
                Text("Nur das Symbol").tag(AppSettings.MenuBarMode.none)
                Text("Punkt bei Neuem").tag(AppSettings.MenuBarMode.newItemsDot)
                Text("Offene PRs von Menschen").tag(AppSettings.MenuBarMode.personPullRequests)
                Text("Summe offener Issues und PRs").tag(AppSettings.MenuBarMode.openItems)
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
    }
}

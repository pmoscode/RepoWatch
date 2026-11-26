import DesignSystem
import Domain
import ModuleUIKit
import SwiftUI

/// Detailansicht eines Repos: Kopf plus ein Abschnitt je Modul (Konzept 3.2).
struct RepositoryDetailView: View {
    let repository: RepoSnapshot
    let model: AppModel
    let onBack: () -> Void

    var body: some View {
        let context = model.ui
        let isFavorite = model.settings.isFavorite(repository.meta.nameWithOwner)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Label("Zurück", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Zurück (⌘←)")
                Spacer()
                Button {
                    model.toggleFavorite(repository.meta.nameWithOwner)
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? Color.yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten")
                .accessibilityLabel(isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten")
                Button {
                    context.open(repository.meta.url)
                } label: {
                    Label("Auf GitHub", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(repository.meta.nameWithOwner)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            if repository.meta.isPrivate { TagText("Privat") }
                            if repository.meta.isFork { TagText("Fork") }
                            if repository.meta.isArchived { TagText("Archiviert") }
                            if let pushedAt = repository.meta.pushedAt {
                                Text("Letzter Push")
                                RelativeTimeText(pushedAt)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let error = repository.lastDetailError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    ForEach(model.enabledModuleUIs.indices, id: \.self) { index in
                        let module = model.enabledModuleUIs[index]
                        if let section = module.detailSection(for: repository, context: context) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(module.title, systemImage: module.systemImage)
                                    .font(.headline)
                                section
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .onAppear { model.markSeen(repository.id) }
    }
}

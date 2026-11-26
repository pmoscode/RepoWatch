import Auth
import SwiftUI

/// Anmeldung im Panel (Konzept 5): Device Flow als Standard, Personal Access Token als Alternative.
struct SignInView: View {
    let model: AppModel

    @State private var personalAccessToken = ""
    @State private var showsTokenEntry = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            Image(systemName: "binoculars.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Bei GitHub anmelden")
                    .font(.title2.weight(.semibold))
                Text("RepoWatch liest Issues, Pull Requests, Aktivität und Actions deiner Repositories. Das Token bleibt im Schlüsselbund dieses Macs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch model.auth {
            case .awaitingDeviceConfirmation(let authorization):
                DeviceCodeView(authorization: authorization, model: model)
            case .validating, .checking:
                ProgressView("Token wird geprüft …")
                    .controlSize(.small)
            case .signedOut(let message):
                signInOptions(message: message)
            case .signedIn:
                EmptyView()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .animation(.snappy, value: model.auth)
        .animation(.snappy, value: showsTokenEntry)
    }

    @ViewBuilder
    private func signInOptions(message: String?) -> some View {
        VStack(spacing: 12) {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.signInWithDevice()
            } label: {
                Label("Mit GitHub anmelden", systemImage: "person.badge.key")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!model.isDeviceFlowAvailable)
            .keyboardShortcut(.defaultAction)

            if !model.isDeviceFlowAvailable {
                Text("Für die Anmeldung im Browser fehlt noch die Client-ID der OAuth-App (`GITHUB_OAUTH_CLIENT_ID`).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if showsTokenEntry {
                tokenEntry
            } else {
                Button("Stattdessen Personal Access Token verwenden") {
                    showsTokenEntry = true
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Personal Access Token", text: $personalAccessToken)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitToken)
            HStack {
                Link("Token erstellen …", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    .font(.caption)
                Spacer()
                Button("Prüfen und speichern", action: submitToken)
                    .disabled(personalAccessToken.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Fine-grained, nur lesend: Metadata, Contents, Issues, Pull requests, Actions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func submitToken() {
        model.signIn(personalAccessToken: personalAccessToken)
        personalAccessToken = ""
    }
}

private struct DeviceCodeView: View {
    let authorization: DeviceAuthorization
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Text("Gib diesen Code auf GitHub ein:")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(authorization.userCode)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .accessibilityLabel(Text("Code \(authorization.userCode)"))

            Button {
                model.copyCodeAndOpenVerificationPage()
            } label: {
                Label("Code kopieren und GitHub öffnen", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Warte auf Bestätigung …")
                Text("·")
                Text("gültig bis \(authorization.expiresAt.formatted(date: .omitted, time: .shortened))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Abbrechen", role: .cancel) {
                model.cancelSignIn()
            }
            .buttonStyle(.borderless)
        }
    }
}

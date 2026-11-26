import Domain
import SwiftUI

// MARK: - Status

/// Einheitliche Status-Darstellung für CI, Workflows und Runs.
public enum StatusTone: Sendable, Hashable {
    case success, failure, running, pending, cancelled, neutral

    public init(_ ci: CIState?) {
        switch ci {
        case .success: self = .success
        case .failure: self = .failure
        case .pending: self = .pending
        case nil: self = .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath.circle.fill"
        case .pending: "clock.fill"
        case .cancelled: "slash.circle"
        case .neutral: "minus.circle"
        }
    }

    public var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .running: .blue
        case .pending: .orange
        case .cancelled, .neutral: .secondary
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .success: "Erfolgreich"
        case .failure: "Fehlgeschlagen"
        case .running: "Läuft"
        case .pending: "Ausstehend"
        case .cancelled: "Abgebrochen"
        case .neutral: "Kein Status"
        }
    }
}

public struct StatusIcon: View {
    private let tone: StatusTone

    public init(_ tone: StatusTone) {
        self.tone = tone
    }

    public var body: some View {
        Image(systemName: tone.systemImage)
            .foregroundStyle(tone.color)
            .symbolEffect(.rotate, isActive: tone == .running)
            .help(Text(tone.label))
            .accessibilityLabel(Text(tone.label))
    }
}

// MARK: - Labels

/// GitHub-Label mit seiner Farbe (Konzept 3.2).
public struct LabelChip: View {
    private let name: String
    private let color: Color

    public init(name: String, hexColor: String) {
        self.name = name
        color = Color(hex: hexColor) ?? .secondary
    }

    public var body: some View {
        Text(name)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.22), in: .capsule)
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 0.5))
    }
}

extension Color {
    /// `"d73a4a"` oder `"#d73a4a"`.
    public init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Autor-Art

/// Symbol für die Autor-Art eines PRs oder Runs (Konzept 6).
public struct AuthorKindIcon: View {
    private let kind: AuthorKind

    public init(_ kind: AuthorKind) {
        self.kind = kind
    }

    public static func systemImage(for category: AuthorKind.Category) -> String {
        switch category {
        case .human: "person.fill"
        case .me: "person.crop.circle.fill"
        case .renovate: "shippingbox"
        case .dependabot: "shippingbox.fill"
        case .otherBot: "cpu"
        }
    }

    public static func title(for category: AuthorKind.Category) -> String {
        switch category {
        case .human: String(localized: "Von Menschen")
        case .me: String(localized: "Von mir")
        case .renovate: "Renovate"
        case .dependabot: "Dependabot"
        case .otherBot: String(localized: "Andere Bots")
        }
    }

    private var help: String {
        switch kind {
        case .renovate: "Renovate"
        case .dependabot: "Dependabot"
        case .bot(let name): String(localized: "Bot: \(name)")
        case .me: String(localized: "Von mir")
        case .human(let login): login
        }
    }

    public var body: some View {
        Image(systemName: Self.systemImage(for: kind.category))
            .foregroundStyle(kind.isPerson ? Color.accentColor : .secondary)
            .help(help)
            .accessibilityLabel(Text(help))
    }
}

// MARK: - Aktivität

/// Drei Punkte für die Aktivitätsstufe 0 … 3 (Konzept 7).
public struct ActivityIndicator: View {
    private let level: Int

    public init(level: Int) {
        self.level = max(0, min(3, level))
    }

    private var label: LocalizedStringKey {
        switch level {
        case 0: "Aktivität: ruhend"
        case 1: "Aktivität: niedrig"
        case 2: "Aktivität: mittel"
        default: "Aktivität: hoch"
        }
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index < level ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 5, height: 5)
            }
        }
        .help(Text(label))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}

/// Kleine Verlaufslinie, z. B. Commits pro Woche.
public struct Sparkline: View {
    private let values: [Int]

    public init(values: [Int]) {
        self.values = values
    }

    public var body: some View {
        GeometryReader { geometry in
            let maximum = max(values.max() ?? 1, 1)
            let step = values.count > 1 ? geometry.size.width / CGFloat(values.count - 1) : 0
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: CGFloat(index) * step,
                    y: geometry.size.height * (1 - CGFloat(value) / CGFloat(maximum))
                )
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geometry.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: geometry.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Verlauf"))
        .accessibilityValue(Text(values.map(String.init).joined(separator: ", ")))
    }
}

// MARK: - Sonstiges

/// Punkt für „neu seit dem letzten Öffnen“ (Konzept 3.2).
public struct NewDot: View {
    public init() {}

    public var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .help(Text("Neu seit dem letzten Öffnen"))
            .accessibilityLabel(Text("Neu"))
    }
}

/// Kleines Etikett, z. B. „Entwurf“ oder „Fork“.
public struct TagText: View {
    private let text: Text

    public init(_ text: LocalizedStringKey) {
        self.text = Text(text)
    }

    /// Ohne Übersetzung, z. B. Branch-Namen.
    public init(verbatim text: String) {
        self.text = Text(verbatim: text)
    }

    public var body: some View {
        text
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
    }
}

/// Überschrift eines Abschnitts mit optionaler Anzahl.
public struct SectionTitle: View {
    private let title: String
    private let count: Int?

    public init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let count {
                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Leerer Zustand innerhalb eines Reiters.
public struct EmptyStateView: View {
    private let title: LocalizedStringKey
    private let systemImage: String
    private let message: LocalizedStringKey?

    public init(_ title: LocalizedStringKey, systemImage: String, message: LocalizedStringKey? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Zeitspanne kompakt, z. B. „3 Min. 20 Sek.“.
public func formattedDuration(_ interval: TimeInterval) -> String {
    Duration.seconds(interval).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
}

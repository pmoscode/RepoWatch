import SwiftUI

/// Kleiner Zähler mit SF Symbol, z. B. „◎ 4“ für offene Issues.
public struct CountBadge: View {
    private let systemImage: String
    private let count: Int
    private let label: LocalizedStringKey

    public init(_ label: LocalizedStringKey, systemImage: String, count: Int) {
        self.label = label
        self.systemImage = systemImage
        self.count = count
    }

    public var body: some View {
        Label {
            Text(count, format: .number)
                .monospacedDigit()
        } icon: {
            Image(systemName: systemImage)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(count == 0 ? .tertiary : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(count, format: .number))
    }
}

/// Relative Zeitangabe („vor 2 Std.“), die sich selbst aktualisiert.
public struct RelativeTimeText: View {
    private let date: Date

    public init(_ date: Date) {
        self.date = date
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .id(context.date)
        }
    }
}

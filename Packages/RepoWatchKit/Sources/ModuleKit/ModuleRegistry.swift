import Domain
import Foundation

public enum ModuleRegistryError: Error, Sendable, Equatable, LocalizedError {
    case duplicateModule(ModuleID)
    /// Ein Feld der obersten Ebene trägt nicht das Präfix des Moduls (`m_<id>_`).
    case unprefixedField(module: ModuleID, field: String)
    case duplicateField(String)
    case malformedFragment(module: ModuleID, reason: String)

    public var errorDescription: String? {
        switch self {
        case .duplicateModule(let id): "Modul \(id) ist doppelt registriert."
        case .unprefixedField(let module, let field): "Feld „\(field)“ in Modul \(module) braucht das Präfix \(module.fieldPrefix)."
        case .duplicateField(let field): "Feld „\(field)“ ist in mehreren Modulen definiert."
        case .malformedFragment(let module, let reason): "Fragment von Modul \(module) ist fehlerhaft: \(reason)"
        }
    }
}

/// Alle bekannten Module in fester Reihenfolge, plus welche davon aktiv sind (Konzept 9.2).
///
/// Prüft beim Registrieren, dass die Fragmente nicht kollidieren (Risiko „Modul-Fragmente
/// kollidieren“ im Plan), damit eine fehlerhafte Abfrage nie erst zur Laufzeit auffällt.
public struct ModuleRegistry: Sendable {
    public private(set) var modules: [AnyInsightModule] = []
    private var disabled: Set<ModuleID> = []

    public init() {}

    public init(_ modules: [AnyInsightModule]) throws {
        for module in modules {
            try register(module)
        }
    }

    public mutating func register<Module: InsightModule>(_ module: Module) throws {
        try register(AnyInsightModule(module))
    }

    public mutating func register(_ module: AnyInsightModule) throws {
        guard !modules.contains(where: { $0.id == module.id }) else {
            throw ModuleRegistryError.duplicateModule(module.id)
        }
        let fields = try FragmentInspector.topLevelAliases(of: module.fragment.selection, module: module.id)
        let existing = Set(try modules.flatMap { try FragmentInspector.topLevelAliases(of: $0.fragment.selection, module: $0.id) })
        if let clash = fields.first(where: existing.contains) {
            throw ModuleRegistryError.duplicateField(clash)
        }
        modules.append(module)
        modules.sort { ($0.metadata.defaultOrder, $0.id.rawValue) < ($1.metadata.defaultOrder, $1.id.rawValue) }
    }

    /// Module an/aus (Einstellungen, Konzept 3.3).
    public mutating func setEnabled(_ enabled: Bool, for id: ModuleID) {
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
    }

    public var enabledModules: [AnyInsightModule] {
        modules.filter { !disabled.contains($0.id) }
    }

    /// Für das Dekodieren gespeicherter Snapshots.
    public var payloadTypes: [ModuleID: any ModulePayload.Type] {
        Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0.payloadType) })
    }
}

/// Liest die Felder der obersten Ebene eines Fragments, ohne einen vollständigen GraphQL-Parser.
enum FragmentInspector {
    static func topLevelAliases(of selection: String, module: ModuleID) throws -> [String] {
        var aliases: [String] = []
        var depth = 0
        var parenthesisDepth = 0
        var index = selection.startIndex
        var pendingIdentifier: String?

        func flushPending() throws {
            if let identifier = pendingIdentifier {
                throw ModuleRegistryError.unprefixedField(module: module, field: identifier)
            }
        }

        while index < selection.endIndex {
            let character = selection[index]
            switch character {
            case "{":
                if depth == 0, parenthesisDepth == 0 { try flushPending() }
                depth += 1
            case "}":
                depth -= 1
                guard depth >= 0 else {
                    throw ModuleRegistryError.malformedFragment(module: module, reason: "zu viele „}“")
                }
            case "(":
                if depth == 0, parenthesisDepth == 0 { try flushPending() }
                parenthesisDepth += 1
            case ")":
                parenthesisDepth -= 1
            case "#":
                // Kommentar bis Zeilenende überspringen.
                while index < selection.endIndex, selection[index] != "\n" {
                    index = selection.index(after: index)
                }
                continue
            case ":" where depth == 0 && parenthesisDepth == 0:
                guard let alias = pendingIdentifier else {
                    throw ModuleRegistryError.malformedFragment(module: module, reason: "„:“ ohne Alias")
                }
                guard alias.hasPrefix(module.fieldPrefix) else {
                    throw ModuleRegistryError.unprefixedField(module: module, field: alias)
                }
                aliases.append(alias)
                pendingIdentifier = nil
                // Den eigentlichen Feldnamen nach dem Alias überspringen.
                index = selection.index(after: index)
                while index < selection.endIndex, selection[index].isWhitespace {
                    index = selection.index(after: index)
                }
                while index < selection.endIndex, selection[index].isLetter || selection[index].isNumber || selection[index] == "_" {
                    index = selection.index(after: index)
                }
                continue
            default:
                if depth == 0, parenthesisDepth == 0, character.isLetter || character == "_" {
                    try flushPending()
                    var end = index
                    while end < selection.endIndex, selection[end].isLetter || selection[end].isNumber || selection[end] == "_" {
                        end = selection.index(after: end)
                    }
                    pendingIdentifier = String(selection[index..<end])
                    index = end
                    continue
                } else if depth == 0, parenthesisDepth == 0, character == "." {
                    throw ModuleRegistryError.malformedFragment(module: module, reason: "Fragmente der obersten Ebene sind nicht erlaubt")
                }
            }
            index = selection.index(after: index)
        }
        try flushPending()
        guard depth == 0, parenthesisDepth == 0 else {
            throw ModuleRegistryError.malformedFragment(module: module, reason: "Klammern nicht geschlossen")
        }
        if aliases.isEmpty {
            throw ModuleRegistryError.malformedFragment(module: module, reason: "keine Felder")
        }
        return aliases
    }
}

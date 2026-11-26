import Domain
import Foundation
import GitHubAPI

/// Setzt die Fragmente aller aktiven Module zu **einer** Detail-Abfrage zusammen (Konzept 9.2).
public enum QueryBuilder {
    public static let operationName = "RepositoryDetails"

    public static func detailQuery(for modules: [AnyInsightModule]) -> String {
        let variables = Set(modules.flatMap(\.fragment.variables)).sorted()
        let declarations = (["$ids: [ID!]!"] + variables.map { "$\($0.rawValue): \($0.graphQLType)" })
            .joined(separator: ", ")
        let selections = modules
            .map { module in
                "      # \(module.id)\n" + indent(module.fragment.selection, by: 6)
            }
            .joined(separator: "\n")
        return """
        query \(operationName)(\(declarations)) {
          nodes(ids: $ids) {
            ... on Repository {
              id
        \(selections)
            }
          }
          rateLimit { cost remaining limit resetAt }
        }
        """
    }

    public static func variables(for modules: [AnyInsightModule], ids: [String], now: Date) -> [String: GraphQLVariable] {
        var result: [String: GraphQLVariable] = ["ids": .strings(ids)]
        for variable in Set(modules.flatMap(\.fragment.variables)) {
            result[variable.rawValue] = variable.value(now: now)
        }
        return result
    }

    /// Rückt einen Block ein und behält dabei die relative Einrückung seiner Zeilen.
    private static func indent(_ text: String, by spaces: Int) -> String {
        let padding = String(repeating: " ", count: spaces)
        let lines = text.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
        let common = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " }).count }
            .min() ?? 0
        return lines
            .map { line in
                line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : padding + line.dropFirst(common)
            }
            .joined(separator: "\n")
    }
}

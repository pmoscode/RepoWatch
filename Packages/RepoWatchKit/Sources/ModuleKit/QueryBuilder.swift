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

    private static func indent(_ text: String, by spaces: Int) -> String {
        let padding = String(repeating: " ", count: spaces)
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let trimmed = line.drop(while: { $0 == " " })
                return trimmed.isEmpty ? "" : padding + trimmed
            }
            .joined(separator: "\n")
    }
}

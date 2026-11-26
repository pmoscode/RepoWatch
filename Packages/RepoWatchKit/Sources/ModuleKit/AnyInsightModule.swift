import Domain
import Foundation

/// Typgelöschtes Modul, damit Registry und Sync-Kern Module verschiedener Payload-Typen verwalten können.
public struct AnyInsightModule: Sendable, Identifiable {
    public let id: ModuleID
    public let metadata: ModuleMetadata
    public let fragment: GraphQLFragment
    public let payloadType: any ModulePayload.Type

    private let decodeClosure: @Sendable (RepositoryNode, ModuleContext) throws -> any ModulePayload
    private let summarizeClosure: @Sendable (any ModulePayload, ModuleContext) -> ModuleSummary?
    private let supplementaryClosure: @Sendable (RepoMeta, any ModulePayload) -> [SupplementaryRequest]
    private let mergeClosure: @Sendable (any ModulePayload, [SupplementaryResponse], (any ModulePayload)?) throws -> any ModulePayload
    private let changesClosure: @Sendable ((any ModulePayload)?, any ModulePayload, RepoMeta) -> [Change]

    public init<Module: InsightModule>(_ module: Module) {
        id = Module.id
        metadata = module.metadata
        fragment = module.fragment
        payloadType = Module.Payload.self
        decodeClosure = { try module.decode($0, context: $1) }
        summarizeClosure = { payload, context in
            (payload as? Module.Payload).map { module.summarize($0, context: context) }
        }
        supplementaryClosure = { repository, payload in
            (payload as? Module.Payload).map { module.supplementaryRequests(for: repository, payload: $0) } ?? []
        }
        mergeClosure = { payload, responses, previous in
            guard let typed = payload as? Module.Payload else { return payload }
            return try module.merge(typed, with: responses, previous: previous as? Module.Payload)
        }
        changesClosure = { old, new, repository in
            guard let typedNew = new as? Module.Payload else { return [] }
            return module.changes(from: old as? Module.Payload, to: typedNew, repository: repository)
        }
    }

    public func decode(_ node: RepositoryNode, context: ModuleContext) throws -> any ModulePayload {
        try decodeClosure(node, context)
    }

    public func summarize(_ payload: any ModulePayload, context: ModuleContext) -> ModuleSummary? {
        summarizeClosure(payload, context)
    }

    public func supplementaryRequests(for repository: RepoMeta, payload: any ModulePayload) -> [SupplementaryRequest] {
        supplementaryClosure(repository, payload)
    }

    public func merge(
        _ payload: any ModulePayload,
        with responses: [SupplementaryResponse],
        previous: (any ModulePayload)?
    ) throws -> any ModulePayload {
        try mergeClosure(payload, responses, previous)
    }

    public func changes(from old: (any ModulePayload)?, to new: any ModulePayload, repository: RepoMeta) -> [Change] {
        changesClosure(old, new, repository)
    }
}

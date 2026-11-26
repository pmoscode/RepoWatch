import Domain
import Foundation
import Testing
import TestSupport
@testable import Persistence

@Suite("Snapshot-Speicher")
struct SnapshotStoreTests {
    private func temporaryStore() -> JSONFileSnapshotStore {
        JSONFileSnapshotStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "repowatch-tests-\(UUID().uuidString)")
            .appending(path: "snapshot.json"))
    }

    private let state = SyncState(
        viewerLogin: "viewer",
        inventoryFetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
        lastSyncAt: Date(timeIntervalSince1970: 1_800_000_100),
        repositories: [RepoSnapshot(
            meta: .fixture(id: "R1", name: "o/r"),
            payloads: [CountModule.id: AnyPayload(CountPayload(openIssues: 2))],
            summaries: [CountModule.id: ModuleSummary(counts: ["open": 2])],
            detailsFetchedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )]
    )

    @Test("Datei: speichern, laden, löschen")
    func fileRoundTrip() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        #expect(try store.load(payloadTypes: [:]) == nil)
        try store.save(state)
        #expect(try store.load(payloadTypes: [CountModule.id: CountPayload.self]) == state)
        try store.clear()
        #expect(try store.load(payloadTypes: [:]) == nil)
    }

    @Test("Unbekannte Version wird abgelehnt")
    func rejectsFutureVersion() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 99, "savedAt": 0, "state": {}}"#.utf8).write(to: store.fileURL)
        #expect(throws: SnapshotStoreError.unsupportedVersion(99)) {
            _ = try store.load(payloadTypes: [:])
        }
    }
}

@Suite("Gesehen-Status")
struct SeenStateTests {
    @Test("Neu ist, was nach dem letzten Öffnen bzw. Ansehen passiert ist")
    func isNew() {
        let opened = Date(timeIntervalSince1970: 1_000)
        var seen = SeenState(panelOpenedAt: opened)
        #expect(seen.isNew(opened.addingTimeInterval(1), repositoryID: "R1"))
        #expect(!seen.isNew(opened.addingTimeInterval(-1), repositoryID: "R1"))
        seen.repositorySeenAt["R1"] = opened.addingTimeInterval(100)
        #expect(!seen.isNew(opened.addingTimeInterval(50), repositoryID: "R1"))
        #expect(!SeenState().isNew(opened, repositoryID: "R1"))
    }

    @Test("Datei-Speicher: Rundweg")
    func fileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "repowatch-seen-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONFileSeenStateStore(fileURL: url)
        #expect(try store.load() == SeenState())
        let state = SeenState(panelOpenedAt: Date(timeIntervalSince1970: 1_000), repositorySeenAt: ["R1": Date(timeIntervalSince1970: 2_000)])
        try store.save(state)
        #expect(try store.load() == state)
    }
}

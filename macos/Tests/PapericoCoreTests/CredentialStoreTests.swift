import XCTest
import Security
@testable import PapericoCore

final class CredentialStoreTests: XCTestCase {
    private func envelope(_ values: [String: String]) throws -> Data {
        try JSONEncoder().encode(CredentialStore.Envelope(values: values))
    }

    func testSharedUnifiedReadAuthorizesOnceAndCachesAllCredentials() async throws {
        let backend = MemoryKeychain()
        backend.items[KeychainStore.unifiedAccount] = try envelope([
            KeychainStore.Account.llmApiKey.rawValue: "test-llm",
            KeychainStore.Account.mineruToken.rawValue: "test-mineru",
            KeychainStore.Account.mcpToken.rawValue: "test-mcp"
        ])
        backend.locked.insert(KeychainStore.unifiedAccount)
        let store = CredentialStore(backend: backend.api)
        let initial = await store.readAll()
        XCTAssertTrue(initial.needsAuthorization)
        XCTAssertEqual(backend.interactiveReads, 0)
        // Calls from independent settings/MCP consumers are serialized and reuse the result.
        let snapshots = await withTaskGroup(of: CredentialStore.Snapshot.self) { group in
            for _ in 0..<6 { group.addTask { await store.readAll(allowInteraction: true) } }
            var results: [CredentialStore.Snapshot] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(backend.interactiveReads, 1)
        XCTAssertTrue(snapshots.allSatisfy { !$0.needsAuthorization && $0[.mcpToken].value == "test-mcp" })
        let later = await store.readAll()
        XCTAssertEqual(later[.llmApiKey].value, "test-llm")
        XCTAssertEqual(later[.mineruToken].value, "test-mineru")
        XCTAssertEqual(backend.reads.count, 2)
    }

    func testLegacyMigrationIsSilentAndPreservesAllOriginalItems() async throws {
        let backend = MemoryKeychain()
        backend.items = ["llm.api-key": Data("old-llm".utf8), "mineru.token": Data("old-mineru".utf8), "mcp.access-token": Data("old-mcp".utf8)]
        let store = CredentialStore(backend: backend.api)
        let snapshot = await store.readAll()
        XCTAssertFalse(snapshot.needsAuthorization)
        XCTAssertEqual(backend.interactiveReads, 0)
        XCTAssertEqual(backend.writeInteractions, [false])
        XCTAssertEqual(backend.items["llm.api-key"], Data("old-llm".utf8))
        let migrated = try JSONDecoder().decode(CredentialStore.Envelope.self, from: XCTUnwrap(backend.items[KeychainStore.unifiedAccount]))
        XCTAssertEqual(migrated.values.count, 3)
        // Next process reads one consolidated item, rather than each legacy item.
        backend.reads = []
        let nextLaunch = CredentialStore(backend: backend.api)
        let next = await nextLaunch.readAll()
        XCTAssertEqual(next[.mcpToken].value, "old-mcp")
        XCTAssertEqual(backend.reads, [KeychainStore.unifiedAccount])
    }

    func testCancelledLegacyAuthorizationDoesNotCascadeOrEraseReadableCredentials() async throws {
        let backend = MemoryKeychain()
        backend.items = ["llm.api-key": Data("readable".utf8), "mineru.token": Data("locked-mineru".utf8), "mcp.access-token": Data("locked-mcp".utf8)]
        backend.locked = ["mineru.token", "mcp.access-token"]
        backend.cancelAuthorization = true
        let store = CredentialStore(backend: backend.api)
        _ = await store.readAll()
        let cancelled = await store.readAll(allowInteraction: true)
        XCTAssertEqual(backend.interactiveReads, 1)
        XCTAssertEqual(cancelled[.llmApiKey].value, "readable")
        XCTAssertTrue(cancelled[.mineruToken].needsAuthorization)
        XCTAssertNil(backend.items[KeychainStore.unifiedAccount])
        _ = await store.readAll()
        XCTAssertEqual(backend.interactiveReads, 1)
        backend.cancelAuthorization = false
        let retried = await store.readAll(allowInteraction: true)
        XCTAssertFalse(retried.needsAuthorization)
        XCTAssertEqual(retried[.mcpToken].value, "locked-mcp")
    }

    func testFailedMigrationRetainsCredentialsAndFailedSaveDoesNotChangeCache() async throws {
        let backend = MemoryKeychain()
        backend.items["llm.api-key"] = Data("original".utf8)
        backend.failWrites = true
        let store = CredentialStore(backend: backend.api)
        let initial = await store.readAll()
        XCTAssertEqual(initial[.llmApiKey].value, "original")
        do { try await store.write("replacement", to: .llmApiKey); XCTFail("Save must fail") }
        catch { }
        let afterFailure = await store.readAll()
        XCTAssertEqual(afterFailure[.llmApiKey].value, "original")
        XCTAssertNil(backend.items[KeychainStore.unifiedAccount])
    }

    func testSavingOneCredentialPreservesOthersAndMissingKeysRemainMissing() async throws {
        let backend = MemoryKeychain()
        backend.items[KeychainStore.unifiedAccount] = try envelope(["llm.api-key": "original", "mineru.token": "parser"])
        let store = CredentialStore(backend: backend.api)
        try await store.write("replacement", to: .llmApiKey)
        var saved = await store.readAll()
        XCTAssertEqual(saved[.llmApiKey].value, "replacement")
        XCTAssertEqual(saved[.mineruToken].value, "parser")
        XCTAssertEqual(saved[.mcpToken].status, errSecItemNotFound)
        try await store.write("", to: .llmApiKey)
        saved = await store.readAll()
        XCTAssertEqual(saved[.llmApiKey].status, errSecItemNotFound)
        XCTAssertEqual(saved[.mineruToken].value, "parser")
    }

    func testDamagedUnifiedRecordNeverFallsBackOrOverwritesWithLegacyData() async {
        let backend = MemoryKeychain()
        let damaged = Data("invalid-json".utf8)
        backend.items = [KeychainStore.unifiedAccount: damaged, "llm.api-key": Data("stale".utf8)]
        let store = CredentialStore(backend: backend.api)
        let result = await store.readAll()
        XCTAssertTrue(result.needsAuthorization)
        XCTAssertFalse(result.error.isEmpty)
        XCTAssertEqual(backend.reads, [KeychainStore.unifiedAccount])
        do { try await store.write("new", to: .llmApiKey); XCTFail("Damaged data must not be overwritten") }
        catch { }
        XCTAssertEqual(backend.items[KeychainStore.unifiedAccount], damaged)
        XCTAssertTrue(backend.writeInteractions.isEmpty)
    }

    func testMissingCredentialsDoNotRequireAuthorizationOrCreateAnEmptyRecord() async {
        let backend = MemoryKeychain()
        let store = CredentialStore(backend: backend.api)
        let result = await store.readAll()
        XCTAssertFalse(result.needsAuthorization)
        XCTAssertTrue(KeychainStore.Account.allCases.allSatisfy { result[$0].status == errSecItemNotFound })
        XCTAssertTrue(backend.writeInteractions.isEmpty)
    }
}

/// Accesses are serialized by the tested actor; assertions run after awaited calls complete.
private final class MemoryKeychain: @unchecked Sendable {
    var items: [String: Data] = [:]
    var locked: Set<String> = []
    var reads: [String] = []
    var interactiveReads = 0
    var writeInteractions: [Bool] = []
    var cancelAuthorization = false
    var failWrites = false
    var api: KeychainStore.Backend {
        .init(read: { [self] account, allowInteraction in
            reads.append(account)
            if allowInteraction { interactiveReads += 1 }
            guard let data = items[account] else { return .init(data: nil, status: errSecItemNotFound) }
            if locked.contains(account) && (!allowInteraction || cancelAuthorization) {
                return .init(data: nil, status: allowInteraction ? errSecUserCanceled : errSecInteractionNotAllowed)
            }
            return .init(data: data, status: errSecSuccess)
        }, write: { [self] account, data, allowInteraction in
            writeInteractions.append(allowInteraction)
            if failWrites { throw PipelineError("Test storage failure", .storageFailed) }
            items[account] = data
        })
    }
}

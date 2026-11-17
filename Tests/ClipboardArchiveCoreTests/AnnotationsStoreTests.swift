import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 4 annotations sidecar store (expansion contract 5). Every byte is
/// synthetic test data under a unique temp root; nothing touches live
/// archives (contract 10).
@Suite("Annotations Store")
struct AnnotationsStoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-annotations-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func posixPermissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Absent file

    @Test
    func testAbsentFileReadsAreEmptyAndCreateNothing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardAnnotationsStore(archiveRoot: root)

        #expect(store.annotation(for: "sha256:none") == nil)
        #expect(store.pinnedContentHashes().isEmpty)
        #expect(store.snippets().isEmpty)
        #expect(store.allTags().isEmpty)
        #expect(store.collections().isEmpty)
        #expect(!store.isReadOnly())

        // Reads never create the annotations directory or file (no forced
        // organization; a fresh root stays byte-free).
        #expect(!FileManager.default.fileExists(atPath: store.annotationsDirectoryURL.path))

        // A mutation that changes nothing also writes nothing.
        try store.removeContentReference(contentHash: "sha256:none")
        #expect(!FileManager.default.fileExists(atPath: store.annotationsDirectoryURL.path))
    }

    // MARK: - Pin round-trip + permissions

    @Test
    func testPinRoundTripPersistsWithPrivatePermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardAnnotationsStore(archiveRoot: root)

        try store.setPinned(true, forContentHash: "sha256:pinme")

        #expect(try posixPermissions(of: store.annotationsDirectoryURL) == 0o700)
        #expect(try posixPermissions(of: store.annotationsFileURL) == 0o600)

        // A second store instance (fresh cache path exercise) sees the pin.
        let secondStore = ClipboardAnnotationsStore(archiveRoot: root)
        #expect(secondStore.pinnedContentHashes() == ["sha256:pinme"])
        let record = try #require(secondStore.annotation(for: "sha256:pinme"))
        #expect(record.pinned)
        #expect(record.pinnedAt != nil)

        // Unpinning empties the record, which the default-record GC drops.
        try store.setPinned(false, forContentHash: "sha256:pinme")
        #expect(store.annotation(for: "sha256:pinme") == nil)
        #expect(store.pinnedContentHashes().isEmpty)
    }

    // MARK: - Slice 5 placeholder round-trip

    @Test
    func testPlaceholderFieldsRoundTripUntouched() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try FileManager.default.createDirectory(
            at: store.annotationsDirectoryURL,
            withIntermediateDirectories: true
        )
        let seeded = """
        {
          "annotationsVersion": 1,
          "updatedAt": "2026-07-01T00:00:00Z",
          "annotations": {
            "sha256:placeholder": {
              "pinned": true,
              "pinnedAt": "2026-07-01T00:00:00Z",
              "tags": [],
              "snippet": false,
              "sensitivityOverride": "restricted",
              "expiresAt": "2026-12-31T00:00:00Z"
            }
          },
          "collections": []
        }
        """
        try Data(seeded.utf8).write(to: store.annotationsFileURL)

        let loaded = try #require(store.annotation(for: "sha256:placeholder"))
        #expect(loaded.sensitivityOverride == "restricted")
        #expect(loaded.expiresAt != nil)

        // Mutating a DIFFERENT hash must not lose the placeholder fields.
        try store.setTags(["work"], forContentHash: "sha256:other")
        let rewritten = try String(contentsOf: store.annotationsFileURL)
        #expect(rewritten.contains("\"sensitivityOverride\" : \"restricted\""))
        #expect(rewritten.contains("expiresAt"))
        let reloaded = try #require(store.annotation(for: "sha256:placeholder"))
        #expect(reloaded.sensitivityOverride == "restricted")
        #expect(reloaded.pinned)
    }

    // MARK: - Corrupt file

    @Test
    func testCorruptFileReadsEmptyThenFirstMutationSetsItAside() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try FileManager.default.createDirectory(
            at: store.annotationsDirectoryURL,
            withIntermediateDirectories: true
        )
        let corruptBytes = Data("{ not json at all ///".utf8)
        try corruptBytes.write(to: store.annotationsFileURL)

        // Reads see an empty document and never touch the file.
        #expect(store.pinnedContentHashes().isEmpty)
        #expect(store.annotation(for: "sha256:x") == nil)
        #expect(try Data(contentsOf: store.annotationsFileURL) == corruptBytes)

        // FIRST mutation renames the corrupt file aside, preserving its
        // exact bytes, then writes a fresh valid document.
        try store.setPinned(true, forContentHash: "sha256:x")
        let asideFiles = try FileManager.default
            .contentsOfDirectory(at: store.annotationsDirectoryURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("annotations.json.corrupt-") }
        #expect(asideFiles.count == 1)
        let asideURL = try #require(asideFiles.first)
        #expect(try Data(contentsOf: asideURL) == corruptBytes)
        #expect(store.pinnedContentHashes() == ["sha256:x"])
    }

    // MARK: - Future format version (read-only mode)

    @Test
    func testNewerFormatVersionIsReadOnlyAndByteIdentical() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try FileManager.default.createDirectory(
            at: store.annotationsDirectoryURL,
            withIntermediateDirectories: true
        )
        let futureBytes = Data("""
        {
          "annotationsVersion": 3,
          "updatedAt": "2027-06-01T00:00:00Z",
          "futureTopLevelField": { "unknown": true },
          "annotations": {
            "sha256:future-pin": {
              "pinned": true,
              "pinnedAt": "2027-06-01T00:00:00Z",
              "tags": ["future"],
              "snippet": true,
              "snippetTitle": "From the future",
              "futureRecordField": 9
            }
          },
          "collections": [
            { "id": "col_future", "name": "Future", "createdAt": "2027-06-01T00:00:00Z",
              "contentHashes": ["sha256:future-pin"], "futureCollectionField": 1 }
          ]
        }
        """.utf8)
        try futureBytes.write(to: store.annotationsFileURL)

        // Known fields still load: pins keep protecting retention.
        #expect(store.isReadOnly())
        #expect(store.pinnedContentHashes() == ["sha256:future-pin"])
        #expect(store.snippets().count == 1)
        #expect(store.collections().first?.contentHashes == ["sha256:future-pin"])

        // Every mutation throws newerFormat and the file stays untouched.
        #expect(throws: ClipboardAnnotationsError.newerFormat(3)) {
            try store.setPinned(false, forContentHash: "sha256:future-pin")
        }
        #expect(throws: ClipboardAnnotationsError.newerFormat(3)) {
            try store.setTags(["x"], forContentHash: "sha256:new")
        }
        #expect(throws: ClipboardAnnotationsError.newerFormat(3)) {
            try store.createCollection(named: "Nope")
        }
        #expect(throws: ClipboardAnnotationsError.newerFormat(3)) {
            try store.removeContentReference(contentHash: "sha256:future-pin")
        }
        #expect(try Data(contentsOf: store.annotationsFileURL) == futureBytes)
    }

    // MARK: - Symlink rejection

    @Test
    func testSymlinkedAnnotationsFileIsNeverFollowed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try FileManager.default.createDirectory(
            at: store.annotationsDirectoryURL,
            withIntermediateDirectories: true
        )
        let targetURL = root.appendingPathComponent("outside-target.json")
        let targetBytes = Data(#"{"annotationsVersion":1,"annotations":{"sha256:linked":{"pinned":true}},"collections":[]}"#.utf8)
        try targetBytes.write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: store.annotationsFileURL,
            withDestinationURL: targetURL
        )

        // The symlink is treated as corrupt: reads are empty (the pin in
        // the target must NOT load through the link).
        #expect(store.pinnedContentHashes().isEmpty)

        // A mutation moves the link aside without following it; the target
        // file is untouched.
        try store.setPinned(true, forContentHash: "sha256:direct")
        #expect(try Data(contentsOf: targetURL) == targetBytes)
        #expect(store.pinnedContentHashes() == ["sha256:direct"])
    }

    // MARK: - Snippet ⇒ pinned invariant

    @Test
    func testSnippetImpliesPinnedAndUnpinClearsSnippet() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardAnnotationsStore(archiveRoot: root)

        try store.setSnippet(true, title: "  Standup notes  ", forContentHash: "sha256:snip")
        let record = try #require(store.annotation(for: "sha256:snip"))
        #expect(record.snippet)
        #expect(record.pinned)
        #expect(record.snippetTitle == "Standup notes")
        #expect(store.pinnedContentHashes() == ["sha256:snip"])
        #expect(store.snippets().map(\.contentHash) == ["sha256:snip"])

        // Clearing the snippet keeps the pin.
        try store.setSnippet(false, title: nil, forContentHash: "sha256:snip")
        let unmarked = try #require(store.annotation(for: "sha256:snip"))
        #expect(!unmarked.snippet)
        #expect(unmarked.snippetTitle == nil)
        #expect(unmarked.pinned)

        // Unpinning a snippet clears the snippet too (invariant).
        try store.setSnippet(true, title: "Again", forContentHash: "sha256:snip")
        try store.setPinned(false, forContentHash: "sha256:snip")
        #expect(store.annotation(for: "sha256:snip") == nil)
        #expect(store.snippets().isEmpty)
    }

    // MARK: - Tag normalization

    @Test
    func testTagNormalizationTrimsDropsAndDedupesCaseInsensitively() throws {
        #expect(
            ClipboardAnnotationsStore.normalizedTags([" Alpha ", "alpha", "", "  ", "beta\n", "Beta", "ALPHA"])
                == ["Alpha", "beta"]
        )

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try store.setTags([" Work ", "work", "", "Deep Focus"], forContentHash: "sha256:tagme")
        #expect(store.annotation(for: "sha256:tagme")?.tags == ["Work", "Deep Focus"])
        #expect(store.allTags() == ["Deep Focus", "Work"])

        // Clearing tags empties the record; GC drops it from the file.
        try store.setTags([], forContentHash: "sha256:tagme")
        #expect(store.annotation(for: "sha256:tagme") == nil)
        let raw = try String(contentsOf: store.annotationsFileURL)
        #expect(!raw.contains("sha256:tagme"))
    }

    // MARK: - Collections

    @Test
    func testCollectionCRUDOrderMoveAndMembership() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardAnnotationsStore(archiveRoot: root)

        let created = try store.createCollection(named: "Launch Prep")
        #expect(created.id.hasPrefix("col_"))
        try store.setMembership(contentHash: "sha256:a", inCollection: created.id, isMember: true)
        try store.setMembership(contentHash: "sha256:b", inCollection: created.id, isMember: true)
        try store.setMembership(contentHash: "sha256:c", inCollection: created.id, isMember: true)
        // Duplicate add is a no-op, not a duplicate entry.
        try store.setMembership(contentHash: "sha256:a", inCollection: created.id, isMember: true)
        #expect(store.collections().first?.contentHashes == ["sha256:a", "sha256:b", "sha256:c"])

        // Ordered move: contentHashes order IS the collection order.
        try store.moveItem(inCollection: created.id, fromIndex: 2, toIndex: 0)
        #expect(store.collections().first?.contentHashes == ["sha256:c", "sha256:a", "sha256:b"])

        // Out-of-range moves change nothing.
        try store.moveItem(inCollection: created.id, fromIndex: 9, toIndex: 0)
        #expect(store.collections().first?.contentHashes == ["sha256:c", "sha256:a", "sha256:b"])

        try store.setMembership(contentHash: "sha256:a", inCollection: created.id, isMember: false)
        #expect(store.collections().first?.contentHashes == ["sha256:c", "sha256:b"])

        try store.renameCollection(id: created.id, to: "Shipped")
        #expect(store.collections().first?.name == "Shipped")

        try store.deleteCollection(id: created.id)
        #expect(store.collections().isEmpty)
    }

    @Test
    func testRemoveContentReferenceDropsRecordAndStripsCollections() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardAnnotationsStore(archiveRoot: root)

        try store.setPinned(true, forContentHash: "sha256:gone")
        try store.setTags(["keep"], forContentHash: "sha256:stays")
        let first = try store.createCollection(named: "One")
        let second = try store.createCollection(named: "Two")
        try store.setMembership(contentHash: "sha256:gone", inCollection: first.id, isMember: true)
        try store.setMembership(contentHash: "sha256:stays", inCollection: first.id, isMember: true)
        try store.setMembership(contentHash: "sha256:gone", inCollection: second.id, isMember: true)

        try store.removeContentReference(contentHash: "sha256:gone")

        #expect(store.annotation(for: "sha256:gone") == nil)
        #expect(store.annotation(for: "sha256:stays")?.tags == ["keep"])
        #expect(store.collections().map(\.contentHashes) == [["sha256:stays"], []])
    }

    // MARK: - Cache invalidation

    @Test
    func testCacheServesFreshDataAfterExternalRewrite() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardAnnotationsStore(archiveRoot: root)

        try store.setPinned(true, forContentHash: "sha256:first")
        #expect(store.pinnedContentHashes() == ["sha256:first"])
        // Read twice so the cached parse is definitely in play.
        #expect(store.pinnedContentHashes() == ["sha256:first"])

        // Simulate another writer replacing the file directly (different
        // byte count guarantees a signature mismatch).
        let external = """
        {
          "annotationsVersion": 1,
          "updatedAt": "2026-07-30T12:00:00Z",
          "annotations": {
            "sha256:second-external-writer": { "pinned": true, "pinnedAt": "2026-07-30T12:00:00Z" }
          },
          "collections": []
        }
        """
        try Data(external.utf8).write(to: store.annotationsFileURL)

        #expect(store.pinnedContentHashes() == ["sha256:second-external-writer"])
    }
}

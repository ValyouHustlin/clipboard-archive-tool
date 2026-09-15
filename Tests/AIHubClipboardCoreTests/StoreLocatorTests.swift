import Foundation
import Testing
@testable import ClipboardArchiveCore

/// The app and the CLI must agree on WHICH archive and WHICH index they are
/// talking about. One resolver decides that for both, per path and
/// independently: explicit flag → environment variable → pointer file →
/// legacy default. The pointer file is what lets a terminal with no
/// environment follow the running app; the guards here are what stop an
/// environment-less launch from redirecting every later command.
@Suite("Store locator")
struct StoreLocatorTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-store-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func environment(applicationSupport: URL) -> [String: String] {
        [ClipboardDefaults.applicationSupportEnvironmentKey: applicationSupport.path]
    }

    private func writePointer(
        in applicationSupport: URL,
        archiveRoot: String?,
        archiveOrigin: String?,
        indexPath: String?,
        indexOrigin: String?
    ) throws {
        var object: [String: Any] = [
            "schema": 1,
            "writtenBy": "ClipboardArchive 0.3.0 (7)",
            "updatedAt": "2026-09-15T12:00:00.000Z"
        ]
        object["archiveRoot"] = archiveRoot
        object["archiveOrigin"] = archiveOrigin
        object["indexPath"] = indexPath
        object["indexOrigin"] = indexOrigin
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: applicationSupport.appendingPathComponent("stores.json"))
    }

    // MARK: - Precedence, per path, independently

    @Test("Legacy defaults when nothing else says otherwise")
    func defaultsWhenNothingElse() throws {
        let support = try temporaryDirectory()
        let resolution = ClipboardStoreLocator.resolve(environment: environment(applicationSupport: support))

        #expect(resolution.archiveOrigin == .default)
        #expect(resolution.indexOrigin == .default)
        #expect(resolution.pointerStatus == .absent)
        #expect(resolution.archiveRoot.path == support
            .appendingPathComponent("Archive/clipboard-history").path)
        #expect(resolution.indexPath.path == support
            .appendingPathComponent("Indexes/clipboard-search.sqlite").path)
        #expect(resolution.settingsURL.path == support.appendingPathComponent("settings.json").path)
        #expect(resolution.lockURL.path == support.appendingPathComponent("ClipboardArchive.lock").path)
        #expect(resolution.pointerURL.path == support.appendingPathComponent("stores.json").path)
    }

    @Test("Environment beats the legacy default for each path independently")
    func environmentBeatsDefault() throws {
        let support = try temporaryDirectory()
        let archive = try temporaryDirectory()
        var env = environment(applicationSupport: support)
        env[ClipboardDefaults.archiveEnvironmentKey] = archive.path

        let resolution = ClipboardStoreLocator.resolve(environment: env)
        #expect(resolution.archiveOrigin == .env)
        #expect(resolution.archiveRoot.path == archive.path)
        // The index said nothing, so it must NOT be dragged along.
        #expect(resolution.indexOrigin == .default)
        #expect(resolution.indexPath.path == support
            .appendingPathComponent("Indexes/clipboard-search.sqlite").path)
    }

    @Test("Explicit overrides beat the environment for each path independently")
    func flagBeatsEnvironment() throws {
        let support = try temporaryDirectory()
        let envArchive = try temporaryDirectory()
        let flagArchive = try temporaryDirectory()
        let envIndex = try temporaryDirectory().appendingPathComponent("env.sqlite")
        var env = environment(applicationSupport: support)
        env[ClipboardDefaults.archiveEnvironmentKey] = envArchive.path
        env[ClipboardDefaults.indexEnvironmentKey] = envIndex.path

        let resolution = ClipboardStoreLocator.resolve(
            environment: env,
            overrides: ClipboardStoreOverrides(archiveRoot: flagArchive)
        )
        #expect(resolution.archiveOrigin == .flag)
        #expect(resolution.archiveRoot.path == flagArchive.path)
        #expect(resolution.indexOrigin == .env)
        #expect(resolution.indexPath.path == envIndex.path)
    }

    @Test("A published pointer beats the legacy default and is reported as used")
    func pointerBeatsDefault() throws {
        let support = try temporaryDirectory()
        let archive = try temporaryDirectory()
        let indexDirectory = try temporaryDirectory()
        let index = indexDirectory.appendingPathComponent("clipboard-search.sqlite")
        try writePointer(
            in: support,
            archiveRoot: archive.path,
            archiveOrigin: "env",
            indexPath: index.path,
            indexOrigin: "env"
        )

        let resolution = ClipboardStoreLocator.resolve(environment: environment(applicationSupport: support))
        #expect(resolution.archiveOrigin == .pointer)
        #expect(resolution.archiveRoot.path == archive.path)
        #expect(resolution.indexOrigin == .pointer)
        #expect(resolution.indexPath.path == index.path)
        #expect(resolution.pointerStatus == .used)
    }

    @Test("Environment beats a published pointer")
    func environmentBeatsPointer() throws {
        let support = try temporaryDirectory()
        let pointerArchive = try temporaryDirectory()
        let envArchive = try temporaryDirectory()
        let indexDirectory = try temporaryDirectory()
        let index = indexDirectory.appendingPathComponent("clipboard-search.sqlite")
        try writePointer(
            in: support,
            archiveRoot: pointerArchive.path,
            archiveOrigin: "env",
            indexPath: index.path,
            indexOrigin: "env"
        )
        var env = environment(applicationSupport: support)
        env[ClipboardDefaults.archiveEnvironmentKey] = envArchive.path

        let resolution = ClipboardStoreLocator.resolve(environment: env)
        #expect(resolution.archiveOrigin == .env)
        #expect(resolution.archiveRoot.path == envArchive.path)
        // The index entry is still followed — precedence is per path.
        #expect(resolution.indexOrigin == .pointer)
        #expect(resolution.indexPath.path == index.path)
    }

    // MARK: - Pointer guards

    @Test("A pointer entry whose origin is not env or flag is ignored")
    func pointerWithDefaultOriginIsIgnored() throws {
        let support = try temporaryDirectory()
        let archive = try temporaryDirectory()
        let indexDirectory = try temporaryDirectory()
        try writePointer(
            in: support,
            archiveRoot: archive.path,
            archiveOrigin: "default",
            indexPath: indexDirectory.appendingPathComponent("clipboard-search.sqlite").path,
            indexOrigin: "env"
        )

        let resolution = ClipboardStoreLocator.resolve(environment: environment(applicationSupport: support))
        #expect(resolution.archiveOrigin == .default)
        #expect(resolution.archiveRoot.path == support
            .appendingPathComponent("Archive/clipboard-history").path)
        #expect(resolution.indexOrigin == .pointer)
        #expect(resolution.pointerStatus == .ignoredDefaultOrigin)
    }

    @Test("A pointer entry whose path does not exist is ignored")
    func pointerWithMissingPathIsIgnored() throws {
        let support = try temporaryDirectory()
        let missingArchive = try temporaryDirectory().appendingPathComponent("gone", isDirectory: true)
        let missingIndexParent = try temporaryDirectory().appendingPathComponent("gone", isDirectory: true)
        try writePointer(
            in: support,
            archiveRoot: missingArchive.path,
            archiveOrigin: "env",
            indexPath: missingIndexParent.appendingPathComponent("clipboard-search.sqlite").path,
            indexOrigin: "env"
        )

        let resolution = ClipboardStoreLocator.resolve(environment: environment(applicationSupport: support))
        #expect(resolution.archiveOrigin == .default)
        #expect(resolution.indexOrigin == .default)
        #expect(resolution.pointerStatus == .ignoredMissingPath)
    }

    @Test("An index pointer is followed when its parent directory exists")
    func pointerIndexFollowsExistingParent() throws {
        let support = try temporaryDirectory()
        let indexDirectory = try temporaryDirectory()
        let index = indexDirectory.appendingPathComponent("not-created-yet.sqlite")
        try writePointer(
            in: support,
            archiveRoot: nil,
            archiveOrigin: nil,
            indexPath: index.path,
            indexOrigin: "flag"
        )

        let resolution = ClipboardStoreLocator.resolve(environment: environment(applicationSupport: support))
        #expect(resolution.indexOrigin == .pointer)
        #expect(resolution.indexPath.path == index.path)
    }

    @Test("A corrupt pointer reads as unreadable and the legacy defaults are used")
    func corruptPointerFallsThrough() throws {
        let support = try temporaryDirectory()
        try Data("{ not json".utf8).write(to: support.appendingPathComponent("stores.json"))

        let resolution = ClipboardStoreLocator.resolve(environment: environment(applicationSupport: support))
        #expect(resolution.pointerStatus == .unreadable)
        #expect(resolution.archiveOrigin == .default)
        #expect(resolution.indexOrigin == .default)
        #expect(resolution.archiveRoot.path == support
            .appendingPathComponent("Archive/clipboard-history").path)
    }

    // MARK: - Publishing

    @Test("Publishing writes an 0600 pointer naming only env and flag paths")
    func publishWritesGuardedPointer() throws {
        let support = try temporaryDirectory()
        let archive = try temporaryDirectory()
        let indexDirectory = try temporaryDirectory()
        let index = indexDirectory.appendingPathComponent("clipboard-search.sqlite")
        var env = environment(applicationSupport: support)
        env[ClipboardDefaults.archiveEnvironmentKey] = archive.path
        env[ClipboardDefaults.indexEnvironmentKey] = index.path

        let resolution = ClipboardStoreLocator.resolve(environment: env)
        #expect(try ClipboardStoreLocator.publishPointer(for: resolution, writtenBy: "ClipboardArchive 0.3.0 (7)"))

        let pointerURL = support.appendingPathComponent("stores.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: pointerURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)

        let object = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: pointerURL)
        ) as? [String: Any]
        #expect(object?["schema"] as? Int == 1)
        #expect(object?["archiveRoot"] as? String == archive.path)
        #expect(object?["archiveOrigin"] as? String == "env")
        #expect(object?["indexPath"] as? String == index.path)
        #expect(object?["indexOrigin"] as? String == "env")
        #expect(object?["writtenBy"] as? String == "ClipboardArchive 0.3.0 (7)")
        #expect((object?["updatedAt"] as? String)?.isEmpty == false)

        // A fresh reader, with no environment at all, now follows it.
        let followed = ClipboardStoreLocator.resolve(environment: environment(applicationSupport: support))
        #expect(followed.archiveRoot.path == archive.path)
        #expect(followed.indexPath.path == index.path)
    }

    @Test("A default-origin resolution never publishes and never overwrites")
    func publishSkipsDefaultOriginResolution() throws {
        let support = try temporaryDirectory()
        let archive = try temporaryDirectory()
        let indexDirectory = try temporaryDirectory()
        try writePointer(
            in: support,
            archiveRoot: archive.path,
            archiveOrigin: "env",
            indexPath: indexDirectory.appendingPathComponent("clipboard-search.sqlite").path,
            indexOrigin: "env"
        )
        let pointerURL = support.appendingPathComponent("stores.json")
        let before = try Data(contentsOf: pointerURL)

        // An environment-less launch resolves through the pointer, so its
        // origins are `pointer`, not env or flag: nothing may be written.
        let resolution = ClipboardStoreLocator.resolve(environment: environment(applicationSupport: support))
        #expect(try ClipboardStoreLocator.publishPointer(
            for: resolution,
            writtenBy: "ClipboardArchive 0.3.0 (7)"
        ) == false)
        #expect(try Data(contentsOf: pointerURL) == before)

        // And so does a launch that resolved to the legacy defaults.
        let bare = try temporaryDirectory()
        let bareResolution = ClipboardStoreLocator.resolve(environment: environment(applicationSupport: bare))
        #expect(bareResolution.archiveOrigin == .default)
        #expect(try ClipboardStoreLocator.publishPointer(
            for: bareResolution,
            writtenBy: "ClipboardArchive 0.3.0 (7)"
        ) == false)
        #expect(FileManager.default.fileExists(atPath: bare.appendingPathComponent("stores.json").path) == false)
    }

    @Test("Publishing one path keeps the other path's existing entry")
    func publishPreservesUnpublishableEntry() throws {
        let support = try temporaryDirectory()
        let oldArchive = try temporaryDirectory()
        let indexDirectory = try temporaryDirectory()
        let oldIndex = indexDirectory.appendingPathComponent("old.sqlite")
        try writePointer(
            in: support,
            archiveRoot: oldArchive.path,
            archiveOrigin: "env",
            indexPath: oldIndex.path,
            indexOrigin: "env"
        )

        let newIndex = indexDirectory.appendingPathComponent("new.sqlite")
        var env = environment(applicationSupport: support)
        env[ClipboardDefaults.indexEnvironmentKey] = newIndex.path
        // The archive resolves through the existing pointer, so its entry
        // must survive rather than being replaced by the legacy default.
        let resolution = ClipboardStoreLocator.resolve(environment: env)
        #expect(resolution.archiveOrigin == .pointer)
        #expect(try ClipboardStoreLocator.publishPointer(for: resolution, writtenBy: "ClipboardArchive 0.3.0 (7)"))

        let object = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: support.appendingPathComponent("stores.json"))
        ) as? [String: Any]
        #expect(object?["archiveRoot"] as? String == oldArchive.path)
        #expect(object?["archiveOrigin"] as? String == "env")
        #expect(object?["indexPath"] as? String == newIndex.path)
        #expect(object?["indexOrigin"] as? String == "env")
    }

    @Test("Publishing replaces the pointer atomically, leaving no temporary files")
    func publishIsAtomic() throws {
        let support = try temporaryDirectory()
        let archive = try temporaryDirectory()
        var env = environment(applicationSupport: support)
        env[ClipboardDefaults.archiveEnvironmentKey] = archive.path

        for _ in 0..<3 {
            let resolution = ClipboardStoreLocator.resolve(environment: env)
            #expect(try ClipboardStoreLocator.publishPointer(
                for: resolution,
                writtenBy: "ClipboardArchive 0.3.0 (7)"
            ))
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: support.path)
        #expect(contents == ["stores.json"])
    }

    @Test("An explicit index override beats both the environment and a pointer")
    func flagBeatsPointerAndEnvironmentForTheIndex() throws {
        let support = try temporaryDirectory()
        let archive = try temporaryDirectory()
        let indexDirectory = try temporaryDirectory()
        try writePointer(
            in: support,
            archiveRoot: archive.path,
            archiveOrigin: "env",
            indexPath: indexDirectory.appendingPathComponent("pointer.sqlite").path,
            indexOrigin: "env"
        )
        var env = environment(applicationSupport: support)
        env[ClipboardDefaults.indexEnvironmentKey] = indexDirectory
            .appendingPathComponent("env.sqlite").path
        let flagIndex = indexDirectory.appendingPathComponent("flag.sqlite")

        let resolution = ClipboardStoreLocator.resolve(
            environment: env,
            overrides: ClipboardStoreOverrides(indexPath: flagIndex)
        )
        #expect(resolution.indexOrigin == .flag)
        #expect(resolution.indexPath.path == flagIndex.path)
        #expect(resolution.archiveOrigin == .pointer)
    }

    @Test("A pointer from a newer schema is not guessed at")
    func futureSchemaPointerIsUnreadable() throws {
        let support = try temporaryDirectory()
        let archive = try temporaryDirectory()
        let object: [String: Any] = [
            "schema": 2,
            "archiveRoot": archive.path,
            "archiveOrigin": "env",
            "writtenBy": "ClipboardArchive 9.9.9 (99)",
            "updatedAt": "2026-09-15T12:00:00.000Z"
        ]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: support.appendingPathComponent("stores.json"))

        let resolution = ClipboardStoreLocator.resolve(environment: environment(applicationSupport: support))
        #expect(resolution.pointerStatus == .unreadable)
        #expect(resolution.archiveOrigin == .default)
    }

    @Test("Publishing tightens the containing directory to 0700")
    func publishTightensDirectory() throws {
        let support = try temporaryDirectory()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: support.path
        )
        let archive = try temporaryDirectory()
        var env = environment(applicationSupport: support)
        env[ClipboardDefaults.archiveEnvironmentKey] = archive.path

        let resolution = ClipboardStoreLocator.resolve(environment: env)
        #expect(try ClipboardStoreLocator.publishPointer(for: resolution, writtenBy: "ClipboardArchive 0.3.0 (7)"))

        let attributes = try FileManager.default.attributesOfItem(atPath: support.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
    }

    @Test("A publish that cannot be completed leaves the previous pointer intact")
    func failedPublishLeavesPreviousPointer() throws {
        let support = try temporaryDirectory()
        let archive = try temporaryDirectory()
        let otherArchive = try temporaryDirectory()
        try writePointer(
            in: support,
            archiveRoot: archive.path,
            archiveOrigin: "env",
            indexPath: nil,
            indexOrigin: nil
        )
        let pointerURL = support.appendingPathComponent("stores.json")
        let before = try Data(contentsOf: pointerURL)

        // The live pointer cannot be replaced, so the rename at the end of
        // the write must fail. What matters is what survives that failure.
        #expect(chflags(pointerURL.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(pointerURL.path, 0) }

        var env = environment(applicationSupport: support)
        env[ClipboardDefaults.archiveEnvironmentKey] = otherArchive.path
        let resolution = ClipboardStoreLocator.resolve(environment: env)
        #expect(throws: ClipboardStoreLocatorError.self) {
            _ = try ClipboardStoreLocator.publishPointer(
                for: resolution,
                writtenBy: "ClipboardArchive 0.3.0 (7)"
            )
        }
        #expect(try Data(contentsOf: pointerURL) == before)
        // And no half-written temporary file is left behind either.
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.path) == ["stores.json"])
    }

    // MARK: - Alternate index

    @Test("No alternate index is reported when the resolved index is the default one")
    func alternateIndexAbsentForDefaultResolution() throws {
        let support = try temporaryDirectory()
        let resolution = ClipboardStoreLocator.resolve(environment: environment(applicationSupport: support))
        #expect(ClipboardStoreLocator.alternateIndexReport(for: resolution) == nil)
    }

    @Test("An unused index at the default path is reported without being modified")
    func alternateIndexIsReportedReadOnly() throws {
        let support = try temporaryDirectory()
        let archive = try temporaryDirectory()
        let legacyDirectory = support.appendingPathComponent("Indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacy = legacyDirectory.appendingPathComponent("clipboard-search.sqlite")

        // A real index at the legacy path, built the way the app builds one.
        let seeded = ClipboardDerivedIndex(archiveRoot: archive, indexURL: legacy)
        let writer = ClipboardArchiveWriter(archiveRoot: archive)
        for offset in 0..<3 {
            _ = try writer.archiveAllowedCapture(
                ClipboardCapture(
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(offset)),
                    content: "alternate index fixture \(offset)",
                    sourceApp: ClipboardSourceApp(name: "Synthetic"),
                    pasteboardTypes: ["public.utf8-plain-text"]
                )
            )
        }
        #expect(try seeded.rebuild() == 3)

        // Resolve somewhere else entirely, so the legacy file is unused.
        let elsewhere = try temporaryDirectory()
        var env = environment(applicationSupport: support)
        env[ClipboardDefaults.archiveEnvironmentKey] = archive.path
        env[ClipboardDefaults.indexEnvironmentKey] = elsewhere
            .appendingPathComponent("clipboard-search.sqlite").path
        let resolution = ClipboardStoreLocator.resolve(environment: env)

        let sizeBefore = try FileManager.default.attributesOfItem(atPath: legacy.path)[.size] as? Int64
        let modifiedBefore = try FileManager.default
            .attributesOfItem(atPath: legacy.path)[.modificationDate] as? Date
        let siblingsBefore = try FileManager.default
            .contentsOfDirectory(atPath: legacyDirectory.path).sorted()

        let report = try #require(ClipboardStoreLocator.alternateIndexReport(for: resolution))
        #expect(report.path == legacy.path)
        #expect(report.rowCount == 3)
        #expect(report.userVersion == ClipboardDerivedIndex.currentIndexSchemaVersion)
        #expect(report.bytes == sizeBefore)

        // Read-only means read-only: no rollback journal, no write-ahead
        // log, no shared-memory file, and the database itself untouched.
        let siblingsAfter = try FileManager.default
            .contentsOfDirectory(atPath: legacyDirectory.path).sorted()
        #expect(siblingsAfter == siblingsBefore)
        #expect(siblingsAfter.contains { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") || $0.hasSuffix("-journal") } == false)
        let modifiedAfter = try FileManager.default
            .attributesOfItem(atPath: legacy.path)[.modificationDate] as? Date
        #expect(modifiedAfter == modifiedBefore)
    }

    // MARK: - Environment forwarding

    @Test("An injected application-support root reaches the default archive and index paths")
    func injectedApplicationSupportRootReachesDefaults() throws {
        let support = try temporaryDirectory()
        let env = environment(applicationSupport: support)

        #expect(ClipboardDefaults.archiveRoot(environment: env).path == support
            .appendingPathComponent("Archive/clipboard-history").path)
        #expect(ClipboardDefaults.indexURL(environment: env).path == support
            .appendingPathComponent("Indexes/clipboard-search.sqlite").path)
    }
}

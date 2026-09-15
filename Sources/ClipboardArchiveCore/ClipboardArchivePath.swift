import Foundation

public enum ClipboardArchivePathError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyRelativePath
    case absolutePath(String)
    case pathTraversal(String)
    case outsideArchiveRoot(String)

    public var description: String {
        switch self {
        case .emptyRelativePath:
            return "archive body path is empty"
        case let .absolutePath(path):
            return "archive body path must be relative: \(path)"
        case let .pathTraversal(path):
            return "archive body path contains traversal: \(path)"
        case let .outsideArchiveRoot(path):
            return "archive body path resolves outside archive root: \(path)"
        }
    }
}

public enum ClipboardArchivePath {
    /// The one canonical spelling of an archive root, used for every
    /// containment test and for directory enumeration.
    ///
    /// `standardizedFileURL` alone does not resolve symlinks, while
    /// directory enumeration reports real paths. A root reached through a
    /// symlink therefore failed every prefix test and read as an empty
    /// archive. Resolving first and standardizing second gives one
    /// spelling that both sides agree on, and also settles the
    /// `/private/tmp` vs `/tmp` spelling of the same directory.
    ///
    /// Resolution is anchored on the deepest component that exists, because
    /// both symlink resolution and `/private` stripping are defined only
    /// for real files; a directory that has not been created yet keeps its
    /// tail and inherits the canonical spelling of its parent.
    public static func resolvedRoot(_ archiveRoot: URL) -> URL {
        let fileManager = FileManager.default
        var missingComponents: [String] = []
        var current = archiveRoot.standardizedFileURL
        while !fileManager.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else {
                return archiveRoot.resolvingSymlinksInPath().standardizedFileURL
            }
            missingComponents.append(current.lastPathComponent)
            current = parent
        }
        var resolved = current.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved
    }

    public static func containedURL(relativePath: String, archiveRoot: URL) throws -> URL {
        guard !relativePath.isEmpty else {
            throw ClipboardArchivePathError.emptyRelativePath
        }

        let path = relativePath as NSString
        guard !path.isAbsolutePath else {
            throw ClipboardArchivePathError.absolutePath(relativePath)
        }

        let components = path.pathComponents
        guard !components.contains(".."), !components.contains(".") else {
            throw ClipboardArchivePathError.pathTraversal(relativePath)
        }

        let normalizedRoot = archiveRoot.standardizedFileURL
        let candidate = normalizedRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard isContained(candidate, by: normalizedRoot) else {
            throw ClipboardArchivePathError.outsideArchiveRoot(relativePath)
        }

        let resolvedRoot = Self.resolvedRoot(normalizedRoot)
        var resolvedCandidate = resolvedRoot
        for component in components {
            resolvedCandidate.appendPathComponent(component)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedCandidate.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                resolvedCandidate = resolvedCandidate.resolvingSymlinksInPath()
            }
            guard isContained(Self.resolvedRoot(resolvedCandidate), by: resolvedRoot) else {
                throw ClipboardArchivePathError.outsideArchiveRoot(relativePath)
            }
        }

        return candidate
    }

    private static func isContained(_ candidate: URL, by root: URL) -> Bool {
        let rootPath = root.path
        return candidate.path.hasPrefix(rootPath + "/")
    }
}

enum ClipboardPrivateFileSystem {
    static func createDirectory(_ directory: URL, archiveRoot: URL) throws {
        // Both sides go through the one canonical spelling so a symlinked
        // root — or the /private/tmp form of a /tmp path — compares equal
        // instead of reading as an escape.
        let root = ClipboardArchivePath.resolvedRoot(archiveRoot)
        let target = ClipboardArchivePath.resolvedRoot(directory)
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw ClipboardArchivePathError.outsideArchiveRoot(target.path)
        }

        if target.path != root.path {
            let relativePath = String(target.path.dropFirst(root.path.count + 1))
            _ = try ClipboardArchivePath.containedURL(
                relativePath: relativePath,
                archiveRoot: root
            )
        }

        var directoriesCreated: [URL] = []
        var current = target
        while current.path == root.path || current.path.hasPrefix(root.path + "/") {
            if FileManager.default.fileExists(atPath: current.path) {
                break
            }
            directoriesCreated.append(current)
            if current.path == root.path {
                break
            }
            current = current.deletingLastPathComponent()
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for createdDirectory in directoriesCreated {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: createdDirectory.path
            )
        }
    }

    static func secureFile(_ file: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: file.path
        )
    }
}

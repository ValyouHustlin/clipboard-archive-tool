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

        let resolvedRoot = normalizedRoot.resolvingSymlinksInPath()
        var resolvedCandidate = resolvedRoot
        for component in components {
            resolvedCandidate.appendPathComponent(component)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedCandidate.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                resolvedCandidate = resolvedCandidate.resolvingSymlinksInPath()
            }
            guard isContained(resolvedCandidate.standardizedFileURL, by: resolvedRoot) else {
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
        let root = archiveRoot.standardizedFileURL
        let target = directory.standardizedFileURL
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

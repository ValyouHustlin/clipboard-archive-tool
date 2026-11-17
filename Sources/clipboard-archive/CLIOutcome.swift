import ClipboardArchiveCore
import Foundation

/// A failure that already knows what the process should exit with.
struct CLIOutcomeError: Error, CustomStringConvertible {
    var exit: ClipboardCLIExit
    var message: String

    var description: String {
        message
    }
}

enum CLIOutcome {
    /// Prints a failure the way the caller asked to be spoken to: a JSON
    /// object on standard error under `--json`, a plain line otherwise.
    /// Either way the text is the same sentence and the exit code is the
    /// same number.
    static func report(_ exit: ClipboardCLIExit, _ message: String, json: Bool) {
        guard json, let code = exit.errorCode else {
            FileHandle.standardError.write(Data("clipboard-archive error: \(message)\n".utf8))
            return
        }
        let object: [String: Any] = ["error": ["code": code, "message": message]]
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{\"error\":{\"code\":\"runtime\",\"message\":\"unprintable\"}}".utf8)
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
    }

    /// Prints an encodable result with a `schema` number added, so every
    /// verb's JSON says which shape it is without each one having to carry
    /// the field in its own type.
    static func printJSON<Value: Encodable>(_ value: Value, schema: Int, extra: [String: Any] = [:]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var object = try JSONSerialization.jsonObject(with: try encoder.encode(value)) as? [String: Any] else {
            throw CLIOutcomeError(exit: .runtime, message: "could not render the result as JSON")
        }
        object["schema"] = schema
        for (key, addition) in extra {
            object[key] = addition
        }
        printJSON(object)
    }

    static func printJSON(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    /// Refuses to run a verb against stores that are not there.
    ///
    /// Every one of these verbs reads the archive, and "0 clips" from a
    /// path that does not exist is the wrong answer to give a script — it
    /// is indistinguishable from an empty archive.
    static func requireArchive(_ options: CLIOptions) throws {
        guard FileManager.default.fileExists(atPath: options.archiveRoot.path) else {
            throw CLIOutcomeError(
                exit: .store,
                message: "no archive at \(options.archiveRoot.path)"
            )
        }
    }

    /// Refuses `--dry-run` on a verb that has no dry run. The flag used to
    /// be accepted and ignored there, so a command the caller believed was
    /// a rehearsal deleted or wrote for real.
    static func rejectDryRun(_ options: CLIOptions) throws {
        guard !options.dryRun else {
            throw CLIOutcomeError(
                exit: .usage,
                message: "\(options.command) has no dry run; --dry-run works with prune, bulk and backup restore"
            )
        }
    }

    static func requireIndex(_ options: CLIOptions) throws {
        guard FileManager.default.fileExists(atPath: options.indexPath.path) else {
            throw CLIOutcomeError(
                exit: .store,
                message: "no search index at \(options.indexPath.path)"
            )
        }
    }
}

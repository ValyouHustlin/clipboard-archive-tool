import Foundation

/// What a `clipboard-archive` invocation reports back to whatever ran it.
///
/// A scheduled job or another agent reads the exit code, not the prose, so
/// each number means one thing and keeps meaning it. The distinction worth
/// the codes is between "I could not run" (2), "your stores are not there"
/// (3), "I ran and found problems" (4) and "I did the work but something
/// about it is not right" (5) — all of which used to be exit 1, and an
/// unknown verb used to be exit 0.
public enum ClipboardCLIExit: Int, Sendable, CaseIterable {
    /// The command did what it was asked and found nothing wrong.
    case success = 0
    /// The command failed while running: an unreadable file, a failed
    /// write, a thrown error that is not one of the cases below.
    case runtime = 1
    /// The command line was wrong: an unknown verb, an unknown flag, a
    /// missing value, a missing required argument. Nothing was run.
    case usage = 2
    /// The stores this verb needs are not there or cannot be read.
    case store = 3
    /// The command ran and found problems in the archive or the index.
    /// `verify` and `doctor` report this; it is a finding, not a failure.
    case integrity = 4
    /// The work completed, with something worth saying: an index update
    /// that did not land, a heartbeat that has gone quiet.
    case warnings = 5

    /// The machine-readable name that goes in a `--json` error object.
    /// The two non-error outcomes have none.
    public var errorCode: String? {
        switch self {
        case .success, .warnings:
            return nil
        case .runtime:
            return "runtime"
        case .usage:
            return "usage"
        case .store:
            return "store"
        case .integrity:
            return "integrity"
        }
    }

    public var summary: String {
        switch self {
        case .success:
            return "success"
        case .runtime:
            return "runtime failure"
        case .usage:
            return "usage error"
        case .store:
            return "store missing or unreadable"
        case .integrity:
            return "problems found"
        case .warnings:
            return "completed with warnings"
        }
    }
}

/// One flag, as the help and the generated reference print it.
public struct ClipboardCLIOption: Sendable, Equatable {
    public var flag: String
    public var summary: String

    public init(_ flag: String, _ summary: String) {
        self.flag = flag
        self.summary = summary
    }
}

/// One verb's metadata. The table below is the single description of this
/// CLI: `help`, `help <verb>` and `docs/CLI.md` are all rendered from it,
/// so a verb cannot be documented in one place and forgotten in another.
public struct ClipboardCLIVerb: Sendable, Equatable {
    public var name: String
    public var summary: String
    public var usage: String
    public var options: [ClipboardCLIOption]
    public var supportsJSON: Bool
    /// Longer prose for the generated reference, where there is room.
    public var discussion: String?

    public init(
        name: String,
        summary: String,
        usage: String,
        options: [ClipboardCLIOption] = [],
        supportsJSON: Bool = true,
        discussion: String? = nil
    ) {
        self.name = name
        self.summary = summary
        self.usage = usage
        self.options = options
        self.supportsJSON = supportsJSON
        self.discussion = discussion
    }
}

public enum ClipboardCLIVerbs {
    public static let storeOptions = [
        ClipboardCLIOption(
            "--archive-root PATH",
            "Archive location. Resolved in order: this flag, CLIPBOARD_ARCHIVE_ARCHIVE_ROOT, the pointer the running app published, the per-user default."
        ),
        ClipboardCLIOption(
            "--index-path PATH",
            "Search index location, resolved the same four ways. Run `stores` to see which one won."
        )
    ]

    private static let filterOptions = [
        ClipboardCLIOption("--since DATE", "Lower bound, ISO 8601 or YYYY-MM-DD."),
        ClipboardCLIOption("--until DATE", "Upper bound, ISO 8601 or YYYY-MM-DD."),
        ClipboardCLIOption("--app NAME", "Only clips copied from this application."),
        ClipboardCLIOption("--bundle-id ID", "Only clips copied from this bundle identifier."),
        ClipboardCLIOption("--type TYPE", "Only clips of this content type (text, url, code, image, file-list)."),
        ClipboardCLIOption("--limit N", "Stop after this many results.")
    ]

    public static let all: [ClipboardCLIVerb] = [
        ClipboardCLIVerb(
            name: "help",
            summary: "Describe the commands, or one command in detail.",
            usage: "clipboard-archive help [VERB] [--markdown]",
            options: [
                ClipboardCLIOption("--markdown", "Print the full reference as Markdown (this is what docs/CLI.md holds).")
            ],
            supportsJSON: false
        ),
        ClipboardCLIVerb(
            name: "version",
            summary: "Print the application and CLI version, the index schema and the archive format.",
            usage: "clipboard-archive version [--json]"
        ),
        ClipboardCLIVerb(
            name: "stores",
            summary: "Report which archive, index, settings, lock and pointer file this command resolved, and where each came from.",
            usage: "clipboard-archive stores [--json]"
        ),
        ClipboardCLIVerb(
            name: "status",
            summary: "Answer whether capture is alive right now, in one fast read.",
            usage: "clipboard-archive status [--json]",
            discussion: """
            Reads the lock file's holder to decide whether the app is running \
            — never launchctl, which reports the launcher's exit and not the \
            app's life. Exits 5 when something is worth saying (a heartbeat \
            that has gone quiet, a launch agent pointing at a path that is \
            not there, a plist that pins stores other than the resolved ones) \
            and 3 when the stores are missing.
            """
        ),
        ClipboardCLIVerb(
            name: "health",
            summary: "Report archive and index counts, sizes and dates.",
            usage: "clipboard-archive health [--json]"
        ),
        ClipboardCLIVerb(
            name: "verify",
            summary: "Check the archive and the index against each other and report every problem found.",
            usage: "clipboard-archive verify [--json]",
            discussion: """
            The slow, complete counterpart to `status`: every health metric, \
            an integrity check of the index database, and a membership \
            comparison between the events the archive holds and the rows the \
            index holds, in both directions. Exits 4 when anything is wrong.
            """
        ),
        ClipboardCLIVerb(
            name: "doctor",
            summary: "Run the store, status and verify checks and explain the result in plain English.",
            usage: "clipboard-archive doctor [--json]",
            discussion: "Exits with the worst of its parts' exit codes."
        ),
        ClipboardCLIVerb(
            name: "search",
            summary: "Search the archive through the search index, with the matcher the history window uses.",
            usage: "clipboard-archive search QUERY [--scan] [--json] [filters]",
            options: filterOptions + [
                ClipboardCLIOption("--scan", "Read the raw day files instead of the index: slower, but it works with no index at all.")
            ]
        ),
        ClipboardCLIVerb(
            name: "index-search",
            summary: "Deprecated alias for `search`.",
            usage: "clipboard-archive index-search QUERY [--limit N]"
        ),
        ClipboardCLIVerb(
            name: "export",
            summary: "Write matching clips, with their content, to a file you name.",
            usage: "clipboard-archive export --out PATH [--format ndjson|json] [--force] [filters]",
            options: filterOptions + [
                ClipboardCLIOption("--out PATH", "Required. The file to write. Standard output is refused: this content is not for a terminal or a pipe."),
                ClipboardCLIOption("--format FORMAT", "ndjson (default) or json."),
                ClipboardCLIOption("--force", "Overwrite an existing file.")
            ],
            discussion: """
            The file holds real clipboard content, so it is written with \
            owner-only permissions and never to standard output, and the \
            command prints counts rather than what it wrote. Clips labelled \
            restricted, clips marked restricted by hand, and clips that have \
            been deleted or suppressed are left out.
            """
        ),
        ClipboardCLIVerb(
            name: "stats",
            summary: "Summarise the usage and operational logs by day.",
            usage: "clipboard-archive stats [--since DATE] [--json]",
            options: [ClipboardCLIOption("--since DATE", "Only rows at or after this date.")]
        ),
        ClipboardCLIVerb(
            name: "logs",
            summary: "Print the operational log: launches, heartbeats, capture failures, rebuilds, prunes.",
            usage: "clipboard-archive logs [--tail N] [--errors] [--since DATE] [--json]",
            options: [
                ClipboardCLIOption("--tail N", "How many rows to print. Default: 50."),
                ClipboardCLIOption("--errors", "Only rows recorded at error level."),
                ClipboardCLIOption("--since DATE", "Only rows at or after this date.")
            ]
        ),
        ClipboardCLIVerb(
            name: "monitor",
            summary: "Poll the pasteboard and archive accepted text changes until stopped.",
            usage: "clipboard-archive monitor [--interval SECONDS] [--duration SECONDS] [--verbose]",
            options: [
                ClipboardCLIOption("--interval SECONDS", "Polling interval. Default: 1."),
                ClipboardCLIOption("--duration SECONDS", "Stop after this many seconds."),
                ClipboardCLIOption("--inline-limit-bytes BYTES", "Content larger than this goes to a body file. Default: 65536."),
                ClipboardCLIOption("--verbose", "Print ignored non-text changes.")
            ],
            supportsJSON: false,
            discussion: "Exits 5 if the archive stored a clip that the index did not take."
        ),
        ClipboardCLIVerb(
            name: "repair-index",
            summary: "Rebuild the derived search index from the archive.",
            usage: "clipboard-archive repair-index",
            supportsJSON: false
        ),
        ClipboardCLIVerb(
            name: "redact",
            summary: "Remove the stored content of one clip, keeping its record.",
            usage: "clipboard-archive redact ID",
            supportsJSON: false
        ),
        ClipboardCLIVerb(
            name: "prune",
            summary: "Remove stored content older than a cutoff.",
            usage: "clipboard-archive prune --until DATE [--dry-run] [--include-pinned] [--json]",
            options: [
                ClipboardCLIOption("--until DATE", "The cutoff. Content captured before it is removed."),
                ClipboardCLIOption("--dry-run", "Report the impact without changing anything."),
                ClipboardCLIOption("--include-pinned", "Prune pinned clips too. They are exempt by default.")
            ]
        ),
        ClipboardCLIVerb(
            name: "bulk",
            summary: "Delete clips by date, application, type or sensitivity.",
            usage: "clipboard-archive bulk [criteria] [--dry-run] [--json]",
            options: [
                ClipboardCLIOption("--since DATE", "Criterion: captured at or after."),
                ClipboardCLIOption("--until DATE", "Criterion: captured before."),
                ClipboardCLIOption("--app NAME", "Criterion: source application name."),
                ClipboardCLIOption("--bundle-id ID", "Criterion: source bundle identifier."),
                ClipboardCLIOption("--type TYPE", "Criterion: content type."),
                ClipboardCLIOption("--sensitivity KIND", "Criterion: any-flagged or manual-restricted."),
                ClipboardCLIOption("--include-pinned", "Delete pinned clips too. They are exempt by default."),
                ClipboardCLIOption("--dry-run", "Preview. Execution is not undoable.")
            ]
        ),
        ClipboardCLIVerb(
            name: "sweep-expired",
            summary: "Delete clips whose sensitivity expiry has passed.",
            usage: "clipboard-archive sweep-expired [--json]"
        ),
        ClipboardCLIVerb(
            name: "backup",
            summary: "Create, inspect or restore an encrypted backup of the archive.",
            usage: "clipboard-archive backup create|inspect|restore FILE [options]",
            options: [
                ClipboardCLIOption("--include-settings", "create: include the settings file."),
                ClipboardCLIOption("--passphrase-stdin", "Read the passphrase from standard input."),
                ClipboardCLIOption("--merge", "restore: import missing items into a non-empty archive. Local deletions always win."),
                ClipboardCLIOption("--apply-settings", "restore: apply the backed-up settings."),
                ClipboardCLIOption("--dry-run", "restore: report the plan without writing.")
            ]
        ),
        ClipboardCLIVerb(
            name: "write-manifest",
            summary: "Write today's daily manifest.",
            usage: "clipboard-archive write-manifest",
            supportsJSON: false
        ),
        ClipboardCLIVerb(
            name: "self-test",
            summary: "Write one sample event to a temporary directory and report where.",
            usage: "clipboard-archive self-test",
            supportsJSON: false
        )
    ]

    public static func verb(named name: String) -> ClipboardCLIVerb? {
        all.first { $0.name == name }
    }

    /// The overview `help` prints: every verb, one line each.
    public static func overview() -> String {
        let width = all.map(\.name.count).max() ?? 0
        var lines = ["Clipboard Archive", "", "Commands:"]
        for verb in all {
            let padding = String(repeating: " ", count: width - verb.name.count)
            lines.append("  \(verb.name)\(padding)  \(verb.summary)")
        }
        lines.append("")
        lines.append("Run `clipboard-archive help VERB` for one command, or")
        lines.append("`clipboard-archive help --markdown` for the full reference.")
        lines.append("")
        lines.append("Exit codes:")
        for exit in ClipboardCLIExit.allCases {
            lines.append("  \(exit.rawValue)  \(exit.summary)")
        }
        lines.append("")
        lines.append("Store options (accepted by every command):")
        for option in storeOptions {
            lines.append("  \(option.flag)")
        }
        return lines.joined(separator: "\n")
    }

    /// What `help VERB` prints.
    public static func detail(for verb: ClipboardCLIVerb) -> String {
        var lines = [verb.name, "", verb.summary, "", "Usage:", "  \(verb.usage)"]
        if let discussion = verb.discussion {
            lines.append("")
            lines.append(discussion)
        }
        let options = verb.options + (verb.supportsJSON
            ? [ClipboardCLIOption("--json", "Print the result as one JSON object carrying a `schema` number.")]
            : [])
        if !options.isEmpty {
            lines.append("")
            lines.append("Options:")
            for option in options {
                lines.append("  \(option.flag)")
                lines.append("      \(option.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The generated reference. `docs/CLI.md` is exactly this text, and a
    /// test regenerates it and compares, so the file cannot drift from the
    /// table without the suite saying so.
    public static func markdownReference() -> String {
        var lines = [
            "# clipboard-archive",
            "",
            "Every command in the Clipboard Archive command-line tool.",
            "",
            "This file is generated: `clipboard-archive help --markdown` prints it, and a",
            "test regenerates it and fails if the committed copy has drifted.",
            "",
            "## Exit codes",
            "",
            "| Code | Meaning |",
            "| --- | --- |"
        ]
        for exit in ClipboardCLIExit.allCases {
            lines.append("| \(exit.rawValue) | \(exit.summary) |")
        }
        lines.append(contentsOf: [
            "",
            "Under `--json`, a failure prints `{\"error\":{\"code\":…,\"message\":…}}` to",
            "standard error, where the code is `usage`, `runtime`, `store` or `integrity`.",
            "",
            "## Store options",
            "",
            "Every command accepts these:",
            ""
        ])
        for option in storeOptions {
            lines.append("- `\(option.flag)` — \(option.summary)")
        }
        lines.append("")
        lines.append("## Commands")
        for verb in all {
            lines.append("")
            lines.append("### \(verb.name)")
            lines.append("")
            lines.append(verb.summary)
            lines.append("")
            lines.append("```")
            lines.append(verb.usage)
            lines.append("```")
            if let discussion = verb.discussion {
                lines.append("")
                lines.append(discussion.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let options = verb.options + (verb.supportsJSON
                ? [ClipboardCLIOption("--json", "Print the result as one JSON object carrying a `schema` number.")]
                : [])
            if !options.isEmpty {
                lines.append("")
                for option in options {
                    lines.append("- `\(option.flag)` — \(option.summary)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

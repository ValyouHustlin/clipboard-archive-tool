import Foundation

/// What a launch agent would start, read from its `Program` and
/// `ProgramArguments` keys.
///
/// An `open`-style agent starts every app operand it is given, so the
/// question `status` has to answer is not "does the first operand exist"
/// but "how many things will this start". On 2026-10-03 the live agent
/// named two copies of the app and the old reader saw only the first.
public struct ClipboardLaunchAgentProgram: Sendable, Equatable {
    /// Every path or app name the agent would start, in argument order.
    public var targets: [String]

    /// The target `status` checks for existence and prints.
    public var primaryPath: String? { targets.first }

    /// `open` options that consume the argument after them.
    private static let openOptionsWithValue: Set<String> = [
        "-a", "-b", "-s", "-i", "-o", "-u", "--arch", "--env", "--stdin", "--stdout", "--stderr",
    ]
    /// Of those, the ones whose value names an app `open` starts.
    private static let openOptionsNamingAnApp: Set<String> = ["-a", "-b"]

    public static func parse(program: String?, arguments: [String]?) -> ClipboardLaunchAgentProgram {
        if let program, !program.isEmpty {
            return ClipboardLaunchAgentProgram(targets: [program])
        }
        guard let arguments, let first = arguments.first else {
            return ClipboardLaunchAgentProgram(targets: [])
        }
        guard (first as NSString).lastPathComponent == "open" else {
            return ClipboardLaunchAgentProgram(targets: [first])
        }

        var targets: [String] = []
        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--args" {
                break
            }
            if openOptionsWithValue.contains(argument) {
                let valueIndex = arguments.index(after: index)
                if openOptionsNamingAnApp.contains(argument), valueIndex < arguments.endIndex {
                    targets.append(arguments[valueIndex])
                }
                index = arguments.index(after: valueIndex)
                continue
            }
            if !argument.hasPrefix("-") {
                targets.append(argument)
            }
            index = arguments.index(after: index)
        }
        return ClipboardLaunchAgentProgram(targets: targets)
    }
}

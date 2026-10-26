import Foundation

public enum Command: Equatable {
    case help, listCases, addSnippet, dryRun, live
}

public struct Options {
    public var command: Command = .help
    public var trigger = HarnessConstants.defaultTrigger
    public var expansion = HarnessConstants.defaultExpansion
    public var only: [String]?
    public var timeoutSeconds: Double = 600
    public var noJS = false
    public var noAI = false
    public var seed: UInt64?
    public var repo: String?

    public struct ParseError: Error, CustomStringConvertible { public let description: String }

    public static let usage = """
    DevType Safari live harness. Drives the INSTALLED /Applications/DevType.app in a real Safari.

    usage: Scripts/safari-harness.sh <command> [options]

    commands
      --dry-run        Everything except posting events: preflight, library check, open the page,
                       focus and read fields over AX, build every key event, collect logs. Posts nothing,
                       uses an in-memory stand-in for the clipboard.
      --live           The real run. Types into Safari with real HID key events. Hands off the keyboard;
                       hold or press Escape to stop.
      --add-snippet    Opens DevType's snippet editor pre-filled with the harness snippet. You click Save.
      --list-cases     Prints the case table.

    options
      --trigger T      Harness snippet trigger (default \(HarnessConstants.defaultTrigger)). Must start with punctuation.
      --expansion E    Harness snippet text (default \(HarnessConstants.defaultExpansion)).
      --only a,b       Run only these case ids.
      --timeout SEC    Whole-run deadline (default 600).
      --no-js          Do not use Safari's Allow JavaScript from Apple Events; read over AX only.
      --no-ai          Skip the AI proofread case.
      --seed N         Seed for typing-rhythm jitter (default: random, printed in the report).
      --repo PATH      Checkout root (default: found from the current directory).
    """

    public static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError(description: "\(flag) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--help", "-h": options.command = .help
            case "--dry-run": options.command = .dryRun
            case "--live": options.command = .live
            case "--add-snippet": options.command = .addSnippet
            case "--list-cases": options.command = .listCases
            case "--trigger": options.trigger = try value(arg)
            case "--expansion": options.expansion = try value(arg)
            case "--only": options.only = try value(arg).split(separator: ",").map { String($0) }
            case "--timeout":
                guard let seconds = Double(try value(arg)), seconds >= 30, seconds <= 3600 else {
                    throw ParseError(description: "--timeout must be between 30 and 3600 seconds")
                }
                options.timeoutSeconds = seconds
            case "--no-js": options.noJS = true
            case "--no-ai": options.noAI = true
            case "--seed":
                guard let seed = UInt64(try value(arg)) else { throw ParseError(description: "--seed must be a non-negative integer") }
                options.seed = seed
            case "--repo": options.repo = try value(arg)
            default: throw ParseError(description: "unknown argument \(arg)")
            }
            index += 1
        }
        if let only = options.only {
            let known = Set(CaseTable.all().map(\.id))
            let unknown = only.filter { !known.contains($0) }
            if !unknown.isEmpty { throw ParseError(description: "unknown case id(s): \(unknown.joined(separator: ", ")); see --list-cases") }
        }
        return options
    }
}

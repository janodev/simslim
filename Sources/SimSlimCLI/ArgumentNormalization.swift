/// Moves root options in front of the selected subcommand.
///
/// Swift Argument Parser scopes parent options before a subcommand. SimSlim's
/// Go CLI historically accepts its global options on either side, so normalize
/// those three options before handing arguments to the parser. Repeated values
/// are deliberately last-wins, matching the original CLI.
func normalizedGlobalArguments(_ originalArguments: [String]) -> [String] {
    if originalArguments == ["-v"] || originalArguments == ["--version"] {
        return ["version"]
    }

    let delimiterIndex = originalArguments.firstIndex(of: "--") ?? originalArguments.endIndex
    var arguments = Array(originalArguments[..<delimiterIndex])
    let positionalSuffix = Array(originalArguments[delimiterIndex...])
    var sawJSON = false
    for index in arguments.indices where arguments[index] == "--json" {
        if sawJSON {
            // The Go CLI marks --json as OnlyOnce. Turning repeats into an
            // unknown option preserves that rejection before command work.
            arguments[index] = "--duplicate-json"
        }
        sawJSON = true
    }

    let optionNames = ["--set", "--boot-timeout", "--spawn-timeout"]
    var retained: [String] = []
    var latest: [String: [String]] = [:]
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        if let name = optionNames.first(where: { argument == $0 }) {
            if index + 1 < arguments.count {
                latest[name] = [name, arguments[index + 1]]
                index += 2
            } else {
                latest[name] = [name]
                index += 1
            }
            continue
        }

        if let name = optionNames.first(where: { argument.hasPrefix($0 + "=") }) {
            latest[name] = [argument]
            index += 1
            continue
        }

        retained.append(argument)
        index += 1
    }

    let normalizedOptions = optionNames.flatMap { latest[$0] ?? [] }
    return normalizedOptions + retained + positionalSuffix
}
